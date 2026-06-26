#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
  submit_grpo_model.sh [options] [model_id] [dataset_id] [max_train_samples] [-- sbatch options]

Examples:
  submit_grpo_model.sh --smoke-test --monitor
  submit_grpo_model.sh --gpu-profile l40s --max-steps 200 --num-generations 4

Options:
  --reward-checker PATH     Python checker. Default: rl/slurm/check_isabelle_reward.py.
  --extractor-json-dir DIR  Extractor JSON directory. Default: extractor/proof_extractor_out/json.
  --isabelle PATH           Isabelle executable used by the checker.
  --isabelle-home-user DIR  Scratch Isabelle user directory for heaps and settings.
  --theory-session-map PATH JSON map from theory names to parent sessions.
  --reward-logic NAME       Parent session for temporary reward checks. Default: HOL.
  --reward-extra-dirs DIRS  Colon-separated Isabelle -d directories for reward builds.
  --reward-timeout SEC     Per-trajectory checker timeout. Default: 60.
  --reward-workers N       Parallel checker subprocesses per trainer process. Default: 1.
  --gpu-profile NAME       Use a100, l40s, or b200. Also passes matching --constraint.
  --model-root DIR         Set MODEL_ROOT for deriving MODEL_PATH from model_id.
  --model-path PATH        Set explicit MODEL_PATH.
  --dataset-config NAME    Set dataset config. Use an empty string for no config.
  --split NAME             Training split. Default: train.
  --max-train-samples N    Number of training examples. Use -1 for all.
  --max-prompt-length N    Maximum prompt tokens. Default: 3072.
  --max-completion-length N Maximum generated proof tokens. Default: 128.
  --max-steps N            GRPO optimizer steps. Default: 100.
  --num-generations N      Completions sampled per prompt. Default: 4.
  --temperature X          Sampling temperature. Default: 0.7.
  --top-p X                Sampling nucleus. Default: 0.95.
  --beta X                 KL coefficient. Default: 0.04.
  --scale-rewards MODE     true, false, or batch. Default: true.
  --learning-rate LR       Learning rate. Default: 1e-6.
  --batch-size N           Per-device train batch size. Default: 1.
  --grad-accum N           Gradient accumulation steps. Default: 1.
  --full-finetune          Train all weights instead of LoRA.
  --output-root DIR        Root directory for GRPO outputs.
  --train-output-dir DIR   Explicit trainer output directory.
  --merged-model-dir DIR   Explicit merged checkpoint directory.
  --wandb-run-name NAME    Set W&B run name.
  --no-wandb               Disable W&B for this run.
  --smoke-test             Use 8 train examples, 4 steps, 2 generations, 45 min walltime.
  --monitor                Submit through submit_and_monitor.sh.
  -h, --help               Show this help.

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
    --reward-checker) need_value "$@"; add_export ISABELLE_REWARD_CHECKER "$2"; shift 2 ;;
    --extractor-json-dir) need_value "$@"; add_export ISABELLE_EXTRACTOR_JSON_DIR "$2"; shift 2 ;;
    --isabelle) need_value "$@"; add_export ISABELLE "$2"; shift 2 ;;
    --isabelle-home-user) need_value "$@"; add_export ISABELLE_HOME_USER "$2"; shift 2 ;;
    --theory-session-map) need_value "$@"; add_export ISABELLE_THEORY_SESSION_MAP "$2"; shift 2 ;;
    --reward-logic) need_value "$@"; add_export ISABELLE_REWARD_LOGIC "$2"; shift 2 ;;
    --reward-extra-dirs) need_value "$@"; add_export ISABELLE_REWARD_EXTRA_DIRS "$2"; shift 2 ;;
    --reward-timeout) need_value "$@"; add_export ISABELLE_REWARD_TIMEOUT "$2"; shift 2 ;;
    --reward-workers) need_value "$@"; add_export REWARD_WORKERS "$2"; shift 2 ;;
    --model-root) need_value "$@"; add_export MODEL_ROOT "$2"; shift 2 ;;
    --model-path) need_value "$@"; add_export MODEL_PATH "$2"; shift 2 ;;
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
    --dataset-config) need_value "$@"; add_export DATASET_CONFIG "$2"; shift 2 ;;
    --split) need_value "$@"; add_export DATASET_SPLIT "$2"; shift 2 ;;
    --max-train-samples) need_value "$@"; MAX_TRAIN_SAMPLES="$2"; shift 2 ;;
    --max-prompt-length) need_value "$@"; add_export MAX_PROMPT_LENGTH "$2"; shift 2 ;;
    --max-completion-length) need_value "$@"; add_export MAX_COMPLETION_LENGTH "$2"; shift 2 ;;
    --max-steps) need_value "$@"; add_export MAX_STEPS "$2"; shift 2 ;;
    --num-generations) need_value "$@"; add_export NUM_GENERATIONS "$2"; shift 2 ;;
    --temperature) need_value "$@"; add_export TEMPERATURE "$2"; shift 2 ;;
    --top-p) need_value "$@"; add_export TOP_P "$2"; shift 2 ;;
    --beta) need_value "$@"; add_export BETA "$2"; shift 2 ;;
    --scale-rewards) need_value "$@"; add_export SCALE_REWARDS "$2"; shift 2 ;;
    --learning-rate) need_value "$@"; add_export LEARNING_RATE "$2"; shift 2 ;;
    --batch-size) need_value "$@"; add_export PER_DEVICE_TRAIN_BATCH_SIZE "$2"; shift 2 ;;
    --grad-accum) need_value "$@"; add_export GRADIENT_ACCUMULATION_STEPS "$2"; shift 2 ;;
    --full-finetune) add_export FULL_FINETUNE 1; shift ;;
    --output-root) need_value "$@"; add_export OUTPUT_ROOT "$2"; shift 2 ;;
    --train-output-dir) need_value "$@"; add_export TRAIN_OUTPUT_DIR "$2"; shift 2 ;;
    --merged-model-dir) need_value "$@"; add_export MERGED_MODEL_DIR "$2"; shift 2 ;;
    --wandb-run-name) need_value "$@"; add_export WANDB_RUN_NAME "$2"; shift 2 ;;
    --no-wandb) add_export DISABLE_WANDB 1; shift ;;
    --smoke-test)
      MAX_TRAIN_SAMPLES="${MAX_TRAIN_SAMPLES:-8}"
      add_export MAX_STEPS 4
      add_export NUM_GENERATIONS 2
      SBATCH_ARGS+=("--time=00:45:00")
      shift
      ;;
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

exec "$submit_script" --source-dir "$SOURCE_ROOT" "${SUBMIT_ARGS[@]}" rl/slurm/grpo_model_trl.sbatch -- "${SBATCH_ARGS[@]}"
