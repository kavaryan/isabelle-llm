#!/bin/bash -l
#SBATCH --job-name=sft_token_stats
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=24G
#SBATCH --time=00:20:00
#SBATCH --output=/scratch/users/%u/%x-%j.out
#SBATCH --error=/scratch/users/%u/%x-%j.err

set -euo pipefail

SUBMIT_ROOT="${SLURM_SUBMIT_DIR:-$(pwd)}"
if [[ -d "$SUBMIT_ROOT/slurm" ]]; then
  SCRIPT_DIR="$SUBMIT_ROOT/slurm"
  SFT_ROOT="$SUBMIT_ROOT"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-0.6B}"
MODEL_ROOT="${MODEL_ROOT:-$HOME/ai4math/models}"
if [[ -z "${MODEL_PATH:-}" ]]; then
  LOCAL_MODEL_PATH="$MODEL_ROOT/${MODEL_ID#*/}"
  if [[ -d "$LOCAL_MODEL_PATH" ]]; then
    MODEL_PATH="$LOCAL_MODEL_PATH"
  else
    MODEL_PATH="$MODEL_ID"
  fi
fi

DATASET_ID="${DATASET_ID:-$SFT_ROOT/sft-data}"
DATASET_CONFIG="${DATASET_CONFIG:-}"
SPLITS="${SPLITS:-train test}"
MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-3072}"
QUESTION_FIELD="${QUESTION_FIELD:-question}"
SOLUTION_FIELD="${SOLUTION_FIELD:-solution}"
ANSWER_FIELD="${ANSWER_FIELD:-answer}"
TEXT_FIELD="${TEXT_FIELD:-}"
SMOKE_TEST="${SMOKE_TEST:-0}"
FILTER_OVER_LENGTH="${FILTER_OVER_LENGTH:-1}"
GPU_PROFILE="${GPU_PROFILE:-l40s}"
SCRATCH_ROOT="${SCRATCH:-/scratch/users/$USER}"
VENV_DIR="${VENV_DIR:-$SCRATCH_ROOT/.venvs/trl-finetune-$GPU_PROFILE}"

echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Node: ${SLURMD_NODENAME:-$(hostname)}"
echo "Model ID: $MODEL_ID"
echo "Model path: $MODEL_PATH"
echo "Dataset: $DATASET_ID config=${DATASET_CONFIG:-none}"
echo "Splits: $SPLITS"
echo "Max seq length: $MAX_SEQ_LENGTH"
echo "Smoke test: $SMOKE_TEST"
echo "Started: $(date -Is)"

if ! command -v python3 >/dev/null 2>&1; then
  module load python || true
fi
module load cuda/12.2.1-gcc-13.2.0 2>/dev/null || module load cuda 2>/dev/null || true

if [[ -x "$VENV_DIR/bin/python" ]]; then
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
else
  echo "error: expected Python environment at $VENV_DIR; run a finetune job once or set VENV_DIR" >&2
  exit 2
fi

stats_args=(
  --model "$MODEL_PATH"
  --dataset "$DATASET_ID"
  --max-seq-length "$MAX_SEQ_LENGTH"
  --question-field "$QUESTION_FIELD"
  --solution-field "$SOLUTION_FIELD"
  --answer-field "$ANSWER_FIELD"
)

if [[ -n "$DATASET_CONFIG" ]]; then
  stats_args+=(--dataset-config "$DATASET_CONFIG")
fi
if [[ -n "$TEXT_FIELD" ]]; then
  stats_args+=(--text-field "$TEXT_FIELD")
fi
if [[ "$SMOKE_TEST" == "1" ]]; then
  stats_args+=(--smoke-test)
fi
if [[ "$FILTER_OVER_LENGTH" == "0" ]]; then
  stats_args+=(--no-filter-over-length)
fi

# shellcheck disable=SC2206
split_array=($SPLITS)
stats_args+=(--splits "${split_array[@]}")

python "$SCRIPT_DIR/sft_chat_stats.py" "${stats_args[@]}"

echo "Completed: $(date -Is)"
