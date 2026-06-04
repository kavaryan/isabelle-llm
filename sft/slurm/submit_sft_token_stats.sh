#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODEL_ID=""
DATASET_ID=""
SUBMIT_ARGS=()
SBATCH_ARGS=()
EXPORT_VARS=()
DEFAULT_MODEL_ID="Qwen/Qwen3-0.6B"
DEFAULT_DATASET_ID=""
submit_script="$SCRIPT_DIR/submit_slurm_job.sh"

usage() {
  cat <<'USAGE'
Usage:
  submit_sft_token_stats.sh [options] [model_id] [dataset_id] [-- sbatch options]

Examples:
  submit_sft_token_stats.sh --smoke-test --monitor
  submit_sft_token_stats.sh --splits train test --gpu-profile l40s
  submit_sft_token_stats.sh Qwen/Qwen3-0.6B ~/sft/sft-data -- --time=00:30:00

Prints token statistics after tokenizer.apply_chat_template for the requested
SFT splits, then exits. No training or vLLM eval is run.

Options:
  --gpu-profile NAME        Use a100, l40s, or b200. Also passes matching --constraint.
  --model-root DIR          Set MODEL_ROOT for deriving MODEL_PATH from model_id.
  --model-path PATH         Set explicit MODEL_PATH.
  --dataset-config NAME     Set dataset config. Use an empty string for no config.
  --splits "A B"            Space-separated splits. Default: "train test".
  --max-seq-length N        Max sequence length used for stats/filtering. Default: 3072.
  --question-field NAME     Dataset question field. Default: question.
  --solution-field NAME     Dataset solution field. Default: solution.
  --answer-field NAME       Dataset answer field. Default: answer.
  --text-field NAME         Use preformatted text field instead of question/solution formatting.
  --smoke-test              Inspect 10 train and 2 test examples.
  --no-filter-over-length   Print stats without filtering/kept-count validation.
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
    --splits) need_value "$@"; add_export SPLITS "$2"; shift 2 ;;
    --max-seq-length) need_value "$@"; add_export MAX_SEQ_LENGTH "$2"; shift 2 ;;
    --question-field) need_value "$@"; add_export QUESTION_FIELD "$2"; shift 2 ;;
    --solution-field) need_value "$@"; add_export SOLUTION_FIELD "$2"; shift 2 ;;
    --answer-field) need_value "$@"; add_export ANSWER_FIELD "$2"; shift 2 ;;
    --text-field) need_value "$@"; add_export TEXT_FIELD "$2"; shift 2 ;;
    --smoke-test)
      add_export SMOKE_TEST 1
      SBATCH_ARGS+=("--time=00:10:00")
      shift
      ;;
    --no-filter-over-length) add_export FILTER_OVER_LENGTH 0; shift ;;
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

base_exports=("MODEL_ID=$MODEL_ID")
if [[ -n "$DATASET_ID" ]]; then
  base_exports+=("DATASET_ID=$DATASET_ID")
fi
EXPORT_VARS=("${base_exports[@]}" "${EXPORT_VARS[@]}")
export_arg="ALL"
for export_var in "${EXPORT_VARS[@]}"; do
  export_arg+=",$export_var"
done
SBATCH_ARGS=("--export=$export_arg" "${SBATCH_ARGS[@]}")

exec "$submit_script" --source-dir "$SOURCE_ROOT" "${SUBMIT_ARGS[@]}" slurm/sft_token_stats.sbatch -- "${SBATCH_ARGS[@]}"
