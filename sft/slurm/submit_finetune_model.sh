#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_ID=""
DATASET_ID=""
MAX_TRAIN_SAMPLES=""
SUBMIT_ARGS=()
SBATCH_ARGS=()
EXPORT_VARS=()
DEFAULT_MODEL_ID="Qwen/Qwen3-0.6B"
DEFAULT_DATASET_ID="GAIR/LIMO"
DEFAULT_MAX_TRAIN_SAMPLES="2"

usage() {
  cat <<'USAGE'
Usage:
  submit_finetune_model.sh [options] [model_id] [dataset_id] [max_train_samples] [-- sbatch options]

Examples:
  submit_finetune_model.sh
  submit_finetune_model.sh Qwen/Qwen3-0.6B GAIR/LIMO 2
  submit_finetune_model.sh --epochs 2 --learning-rate 1e-4 Qwen/Qwen3-0.6B GAIR/LIMO 8
  submit_finetune_model.sh --gpu-profile l40s Qwen/Qwen3-0.6B GAIR/LIMO 2
  submit_finetune_model.sh --model-path '~/ai4math/models/Qwen3-0.6B'
  submit_finetune_model.sh --skip-vllm-smoke
  submit_finetune_model.sh -- --time=04:00:00

Defaults fine-tune Qwen 0.6B on the first 2 examples from GAIR/LIMO, the dataset
released for arXiv:2502.03387.

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
  --max-train-samples N     Number of examples to train on.
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

if ! [[ "$MAX_TRAIN_SAMPLES" =~ ^[0-9]+$ ]]; then
  echo "error: max_train_samples must be a non-negative integer" >&2
  exit 2
fi

EXPORT_VARS=("MODEL_ID=$MODEL_ID" "DATASET_ID=$DATASET_ID" "MAX_TRAIN_SAMPLES=$MAX_TRAIN_SAMPLES" "${EXPORT_VARS[@]}")
export_arg="ALL"
for export_var in "${EXPORT_VARS[@]}"; do
  export_arg+=",$export_var"
done
SBATCH_ARGS=("--export=$export_arg" "${SBATCH_ARGS[@]}")

exec "$submit_script" "${SUBMIT_ARGS[@]}" finetune_model_trl.sbatch -- "${SBATCH_ARGS[@]}"
