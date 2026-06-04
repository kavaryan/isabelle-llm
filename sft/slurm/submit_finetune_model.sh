#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODEL_ID=""
DATASET_ID=""
MAX_TRAIN_SAMPLES=""
SUBMIT_ARGS=()
SBATCH_ARGS=()
EXPORT_VARS=()
DEFAULT_MODEL_ID="Qwen/Qwen3-0.6B"
DEFAULT_DATASET_ID=""
DEFAULT_MAX_TRAIN_SAMPLES="-1"

usage() {
  cat <<'USAGE'
Usage:
  submit_finetune_model.sh [options] [model_id] [dataset_id] [max_train_samples] [-- sbatch options]

Examples:
  submit_finetune_model.sh
  submit_finetune_model.sh Qwen/Qwen3-0.6B ~/ai4math/copilots-isabelle/isabelle-llm/sft/sft-data -1
  submit_finetune_model.sh --epochs 1 --gpu-profile l40s
  submit_finetune_model.sh --smoke-test --monitor
  submit_finetune_model.sh --model-path '~/ai4math/models/Qwen3-0.6B'
  submit_finetune_model.sh --skip-eval-after-train
  submit_finetune_model.sh -- --time=04:00:00

Defaults fine-tune Qwen 0.6B for 1 epoch on the script-relative Isabelle SFT
train split, then evaluate the merged checkpoint on the Isabelle SFT test split
and log the summary/table to W&B when wandb.conf.sh provides WANDB_API_KEY.

Options:
  --gpu-profile NAME        Use a100, l40s, or b200. Also passes matching --constraint.
  --model-root DIR          Set MODEL_ROOT for deriving MODEL_PATH from model_id.
  --model-path PATH         Set explicit MODEL_PATH.
  --dataset-config NAME     Set dataset config. Use an empty string for no config.
  --split NAME              Set dataset split. Default: train.
  --question-field NAME     Dataset question field. Default: question.
  --solution-field NAME     Dataset solution field. Default: solution.
  --answer-field NAME       Dataset answer field. Default: answer.
  --text-field NAME         Use preformatted text field instead of question/solution formatting.
  --max-train-samples N     Number of examples to train on. Use -1 for all.
  --eval-dataset ID         Evaluation dataset. Default: same as training dataset.
  --eval-split NAME         Evaluation split. Default: test.
  --eval-num-problems N     Number of eval examples. Use -1 for all. Default: -1.
  --smoke-test              Generate 10 train / 2 test examples and request 45 min.
  --skip-eval-after-train   Skip post-training vLLM evaluation.
  --output-root DIR         Root directory for finetune outputs.
  --train-output-dir DIR    Explicit trainer output directory.
  --merged-model-dir DIR    Explicit merged checkpoint directory.
  --epochs N                Number of training epochs.
  --learning-rate LR        Learning rate.
  --max-seq-length N        Max training sequence length.
  --batch-size N            Per-device train batch size.
  --grad-accum N            Gradient accumulation steps.
  --full-finetune           Train all weights instead of LoRA.
  --wandb-run-name NAME     Set W&B run name.
  --no-wandb                Disable W&B for this run.
  --skip-vllm-smoke         Skip vLLM checkpoint load/generate smoke test.
  --monitor                 Submit through submit_and_monitor.sh.
  -h, --help                Show this help.

Any submit options before positional arguments are passed to submit_slurm_job.sh.
Arguments after -- are passed directly to sbatch.
USAGE
}

add_export() {
  EXPORT_VARS+=("$1=$2")
}

need_value() {
  if (($# < 2)); then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

submit_script="$SCRIPT_DIR/submit_slurm_job.sh"

while (($#)); do
  case "$1" in
    --model-root) need_value "$@"; add_export MODEL_ROOT "$2"; shift 2 ;;
    --gpu-profile)
      need_value "$@"
      case "$2" in
        a100|l40s|b200)
          add_export GPU_PROFILE "$2"
          SBATCH_ARGS+=("--constraint=$2")
          ;;
        *)
          echo "error: --gpu-profile must be one of: a100, l40s, b200" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --model-path) need_value "$@"; add_export MODEL_PATH "$2"; shift 2 ;;
    --dataset-config) need_value "$@"; add_export DATASET_CONFIG "$2"; shift 2 ;;
    --split) need_value "$@"; add_export DATASET_SPLIT "$2"; shift 2 ;;
    --question-field) need_value "$@"; add_export QUESTION_FIELD "$2"; shift 2 ;;
    --solution-field) need_value "$@"; add_export SOLUTION_FIELD "$2"; shift 2 ;;
    --answer-field) need_value "$@"; add_export ANSWER_FIELD "$2"; shift 2 ;;
    --text-field) need_value "$@"; add_export TEXT_FIELD "$2"; shift 2 ;;
    --max-train-samples) need_value "$@"; MAX_TRAIN_SAMPLES="$2"; shift 2 ;;
    --eval-dataset) need_value "$@"; add_export EVAL_DATASET_ID "$2"; shift 2 ;;
    --eval-split) need_value "$@"; add_export EVAL_DATASET_SPLIT "$2"; shift 2 ;;
    --eval-num-problems) need_value "$@"; add_export EVAL_NUM_PROBLEMS "$2"; shift 2 ;;
    --smoke-test)
      add_export SMOKE_TEST 1
      add_export EVAL_NUM_PROBLEMS 2
      SBATCH_ARGS+=("--time=00:45:00")
      shift
      ;;
    --output-root) need_value "$@"; add_export OUTPUT_ROOT "$2"; shift 2 ;;
    --train-output-dir) need_value "$@"; add_export TRAIN_OUTPUT_DIR "$2"; shift 2 ;;
    --merged-model-dir) need_value "$@"; add_export MERGED_MODEL_DIR "$2"; shift 2 ;;
    --epochs) need_value "$@"; add_export NUM_EPOCHS "$2"; shift 2 ;;
    --learning-rate) need_value "$@"; add_export LEARNING_RATE "$2"; shift 2 ;;
    --max-seq-length) need_value "$@"; add_export MAX_SEQ_LENGTH "$2"; shift 2 ;;
    --batch-size) need_value "$@"; add_export PER_DEVICE_TRAIN_BATCH_SIZE "$2"; shift 2 ;;
    --grad-accum) need_value "$@"; add_export GRADIENT_ACCUMULATION_STEPS "$2"; shift 2 ;;
    --full-finetune) add_export FULL_FINETUNE 1; shift ;;
    --wandb-run-name) need_value "$@"; add_export WANDB_RUN_NAME "$2"; shift 2 ;;
    --no-wandb) add_export DISABLE_WANDB 1; shift ;;
    --skip-eval-after-train) add_export RUN_EVAL_AFTER_TRAIN 0; shift ;;
    --skip-vllm-smoke) add_export SKIP_VLLM_SMOKE 1; shift ;;
    --monitor)
      submit_script="$SCRIPT_DIR/submit_and_monitor.sh"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      SBATCH_ARGS+=("$@")
      break
      ;;
    --source-dir|--remote-dir|--host|--identity|--refresh|-r)
      need_value "$@"
      SUBMIT_ARGS+=("$1" "$2")
      shift 2
      ;;
    --no-upload|--dry-run)
      SUBMIT_ARGS+=("$1")
      shift
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$MODEL_ID" ]]; then
        MODEL_ID="$1"
      elif [[ -z "$DATASET_ID" ]]; then
        DATASET_ID="$1"
      elif [[ -z "$MAX_TRAIN_SAMPLES" ]]; then
        MAX_TRAIN_SAMPLES="$1"
      else
        echo "error: too many positional arguments" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

MODEL_ID="${MODEL_ID:-$DEFAULT_MODEL_ID}"
DATASET_ID="${DATASET_ID:-$DEFAULT_DATASET_ID}"
MAX_TRAIN_SAMPLES="${MAX_TRAIN_SAMPLES:-$DEFAULT_MAX_TRAIN_SAMPLES}"

if ! [[ "$MAX_TRAIN_SAMPLES" =~ ^-?[0-9]+$ ]]; then
  echo "error: max_train_samples must be an integer; use -1 for all examples" >&2
  exit 2
fi

base_exports=("MODEL_ID=$MODEL_ID" "MAX_TRAIN_SAMPLES=$MAX_TRAIN_SAMPLES")
if [[ -n "$DATASET_ID" ]]; then
  base_exports+=("DATASET_ID=$DATASET_ID")
fi
EXPORT_VARS=("${base_exports[@]}" "${EXPORT_VARS[@]}")
export_arg="ALL"
for export_var in "${EXPORT_VARS[@]}"; do
  export_arg+=",$export_var"
done
SBATCH_ARGS=("--export=$export_arg" "${SBATCH_ARGS[@]}")

exec "$submit_script" --source-dir "$SOURCE_ROOT" "${SUBMIT_ARGS[@]}" slurm/finetune_model_trl.sbatch -- "${SBATCH_ARGS[@]}"
