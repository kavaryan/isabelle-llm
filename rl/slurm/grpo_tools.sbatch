#!/bin/bash -l
#SBATCH --job-name=grpo_tools
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --output=/scratch/users/%u/%x-%j.out
#SBATCH --error=/scratch/users/%u/%x-%j.err

set -euo pipefail

SUBMIT_ROOT="${SLURM_SUBMIT_DIR:-$(pwd)}"
if [[ -d "$SUBMIT_ROOT/rl/slurm" ]]; then
  REPO_ROOT="$SUBMIT_ROOT"
  RL_ROOT="$REPO_ROOT/rl"
  SCRIPT_DIR="$RL_ROOT/slurm"
elif [[ -d "$SUBMIT_ROOT/slurm" ]]; then
  SCRIPT_DIR="$SUBMIT_ROOT/slurm"
  RL_ROOT="$SUBMIT_ROOT"
  REPO_ROOT="$(cd "$RL_ROOT/.." && pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  REPO_ROOT="$(cd "$RL_ROOT/.." && pwd)"
fi
SCRATCH_ROOT="${SCRATCH:-/scratch/users/$USER}"
MODEL_ID="${MODEL_ID:-Qwen/Qwen3-0.6B}"
GPU_PROFILE="${GPU_PROFILE:-l40s}"
VENV_DIR="${VENV_DIR:-$SCRATCH_ROOT/.venvs/trl-grpo-tools-$GPU_PROFILE}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/ai4math/grpo-tools}"
RUN_TIMESTAMP="${RUN_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
RUN_NAME="${RUN_NAME:-Qwen3-0.6B_grpo-tools_${RUN_TIMESTAMP}_${SLURM_JOB_ID:-manual}}"
TRAIN_OUTPUT_DIR="${TRAIN_OUTPUT_DIR:-$OUTPUT_ROOT/$RUN_NAME/adapter}"
MERGED_MODEL_DIR="${MERGED_MODEL_DIR:-$OUTPUT_ROOT/$RUN_NAME/merged}"
HOTEL_DB_PATH="${HOTEL_DB_PATH:-$OUTPUT_ROOT/$RUN_NAME/hotels.sqlite3}"
REBUILD_ENV="${REBUILD_ENV:-0}"

case "$GPU_PROFILE" in
  a100|l40s)
    TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu118}"
    TORCH_VERSION="${TORCH_VERSION:-2.6.0+cu118}"
    ;;
  b200)
    TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
    TORCH_VERSION="${TORCH_VERSION:-2.8.0+cu128}"
    ;;
  *)
    echo "error: unknown GPU_PROFILE '$GPU_PROFILE'" >&2
    exit 2
    ;;
esac

export HF_HOME="${HF_HOME:-$SCRATCH_ROOT/.cache/huggingface}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$SCRATCH_ROOT/.cache/pip}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
mkdir -p "$OUTPUT_ROOT" "$HF_HOME" "$PIP_CACHE_DIR" "$(dirname "$VENV_DIR")"

WANDB_CONF="${WANDB_CONF:-$REPO_ROOT/sft/slurm/wandb.conf.sh}"
if [[ -f "$WANDB_CONF" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$WANDB_CONF"
  set +a
fi
if [[ "${DISABLE_WANDB:-0}" == "1" ]]; then
  export REPORT_TO="none"
  export WANDB_MODE="disabled"
else
  export REPORT_TO="${REPORT_TO:-wandb}"
  export WANDB_PROJECT="${WANDB_PROJECT:-ai4math}"
  export WANDB_RUN_NAME="${WANDB_RUN_NAME:-$RUN_NAME}"
  export WANDB_RUN_ID="${WANDB_RUN_ID:-$RUN_NAME}"
  export WANDB_RESUME="${WANDB_RESUME:-allow}"
  export WANDB_MODE="${WANDB_MODE:-online}"
  if [[ -z "${WANDB_API_KEY:-}" ]]; then
    echo "error: WANDB_API_KEY is not set; configure $WANDB_CONF or use DISABLE_WANDB=1" >&2
    exit 2
  fi
fi

CUDA_MODULE="${CUDA_MODULE:-cuda/12.2.1-gcc-13.2.0}"
if [[ -n "$CUDA_MODULE" ]]; then
  module load "$CUDA_MODULE"
fi

ENV_READY_FILE="$VENV_DIR/.ready_${TORCH_VERSION}_trl1"
if [[ "$REBUILD_ENV" == "1" || ! -x "$VENV_DIR/bin/python" || ! -f "$ENV_READY_FILE" ]]; then
  rm -rf "$VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip
  python -m pip install --index-url "$TORCH_INDEX_URL" "torch==$TORCH_VERSION"
  python -m pip install --upgrade \
    "transformers>=5.2,<6" \
    "trl>=1,<2" \
    "peft>=0.18" \
    "accelerate>=1.10" \
    "datasets>=4,<5" \
    "wandb>=0.17" \
    sentencepiece protobuf safetensors
  touch "$ENV_READY_FILE"
else
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
fi

echo "Job ID: ${SLURM_JOB_ID:-manual}"
echo "Node: ${SLURMD_NODENAME:-$(hostname)}"
echo "Model: $MODEL_ID"
echo "Database: $HOTEL_DB_PATH"
echo "W&B: project=${WANDB_PROJECT:-disabled} run=${WANDB_RUN_NAME:-disabled}"
echo "Output: $TRAIN_OUTPUT_DIR"
nvidia-smi

python "$SCRIPT_DIR/grpo-tools.py" \
  --model "$MODEL_ID" \
  --db "$HOTEL_DB_PATH" \
  --output-dir "$TRAIN_OUTPUT_DIR" \
  --merged-output-dir "$MERGED_MODEL_DIR" \
  --max-steps "${MAX_STEPS:--1}" \
  --epochs "${NUM_EPOCHS:-16}" \
  --learning-rate "${LEARNING_RATE:-1e-4}" \
  --batch-size "${PER_DEVICE_TRAIN_BATCH_SIZE:-2}" \
  --gradient-accumulation-steps "${GRADIENT_ACCUMULATION_STEPS:-2}" \
  --num-generations "${NUM_GENERATIONS:-4}" \
  --report-to "$REPORT_TO" \
  --run-name "${WANDB_RUN_NAME:-$RUN_NAME}"
