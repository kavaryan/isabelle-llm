#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_ID=""
DATASET_ID=""
NUM_PROBLEMS=""
SUBMIT_ARGS=()
SBATCH_ARGS=()
EXPORT_VARS=()
DEFAULT_MODEL_ID="Qwen/Qwen3-0.6B"
DEFAULT_DATASET_ID="openai/gsm8k"
DEFAULT_NUM_PROBLEMS="2"

usage() {
  cat <<'USAGE'
Usage:
  submit_eval_model.sh [options] [model_id] [dataset_id] [num_problems] [-- sbatch options]

Examples:
  submit_eval_model.sh
  submit_eval_model.sh Qwen/Qwen3-0.6B openai/gsm8k 2
  submit_eval_model.sh Qwen/Qwen3-4B-Instruct-2507 openai/gsm8k 10
  submit_eval_model.sh --dataset-config main --split test Qwen/Qwen3-0.6B openai/gsm8k 2
  submit_eval_model.sh --model-path '~/ai4math/models/Qwen3-0.6B'
  submit_eval_model.sh -- --time=02:00:00

Options:
  --model-root DIR          Set MODEL_ROOT for deriving MODEL_PATH from model_id.
  --model-path PATH         Set explicit MODEL_PATH for vLLM.
  --served-model-name NAME  Set the vLLM served model name.
  --dataset-config NAME     Set dataset config. Use an empty string for no config.
  --split NAME              Set dataset split. Default: test.
  --question-field NAME     Dataset field containing the question. Default: question.
  --answer-field NAME       Dataset field containing the answer. Default: answer.
  --num-problems N          Number of examples to evaluate.
  --monitor                 Submit through submit_and_monitor.sh.
  -h, --help                Show this help.

Any submit options before positional arguments are passed to submit_slurm_job.sh.
Arguments after -- are passed directly to sbatch.
USAGE
}

submit_script="$SCRIPT_DIR/submit_slurm_job.sh"

while (($#)); do
  case "$1" in
    --model-root)
      if (($# < 2)); then echo "error: --model-root requires a value" >&2; exit 2; fi
      EXPORT_VARS+=("MODEL_ROOT=$2")
      shift 2
      ;;
    --model-path)
      if (($# < 2)); then echo "error: --model-path requires a value" >&2; exit 2; fi
      EXPORT_VARS+=("MODEL_PATH=$2")
      shift 2
      ;;
    --served-model-name)
      if (($# < 2)); then echo "error: --served-model-name requires a value" >&2; exit 2; fi
      EXPORT_VARS+=("SERVED_MODEL_NAME=$2")
      shift 2
      ;;
    --dataset-config)
      if (($# < 2)); then echo "error: --dataset-config requires a value" >&2; exit 2; fi
      EXPORT_VARS+=("DATASET_CONFIG=$2")
      shift 2
      ;;
    --split)
      if (($# < 2)); then echo "error: --split requires a value" >&2; exit 2; fi
      EXPORT_VARS+=("DATASET_SPLIT=$2")
      shift 2
      ;;
    --question-field)
      if (($# < 2)); then echo "error: --question-field requires a value" >&2; exit 2; fi
      EXPORT_VARS+=("DATASET_QUESTION_FIELD=$2")
      shift 2
      ;;
    --answer-field)
      if (($# < 2)); then echo "error: --answer-field requires a value" >&2; exit 2; fi
      EXPORT_VARS+=("DATASET_ANSWER_FIELD=$2")
      shift 2
      ;;
    --num-problems)
      if (($# < 2)); then echo "error: --num-problems requires a value" >&2; exit 2; fi
      NUM_PROBLEMS="$2"
      shift 2
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
      if (($# < 2)); then
        echo "error: $1 requires a value" >&2
        exit 2
      fi
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
      elif [[ -z "$NUM_PROBLEMS" ]]; then
        NUM_PROBLEMS="$1"
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
NUM_PROBLEMS="${NUM_PROBLEMS:-$DEFAULT_NUM_PROBLEMS}"

if ! [[ "$NUM_PROBLEMS" =~ ^[0-9]+$ ]]; then
  echo "error: num_problems must be a non-negative integer" >&2
  exit 2
fi

EXPORT_VARS=("MODEL_ID=$MODEL_ID" "DATASET_ID=$DATASET_ID" "NUM_PROBLEMS=$NUM_PROBLEMS" "${EXPORT_VARS[@]}")
export_arg="ALL"
for export_var in "${EXPORT_VARS[@]}"; do
  export_arg+=",$export_var"
done
SBATCH_ARGS=("--export=$export_arg" "${SBATCH_ARGS[@]}")

exec "$submit_script" "${SUBMIT_ARGS[@]}" eval_model_vllm.sbatch -- "${SBATCH_ARGS[@]}"
