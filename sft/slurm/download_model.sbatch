#!/bin/bash -l
#SBATCH --job-name=download_model
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=6G
#SBATCH --time=03:00:00
#SBATCH --output=/scratch/users/%u/%x-%j.out
#SBATCH --error=/scratch/users/%u/%x-%j.err

set -euo pipefail

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-0.6B}"
MODEL_ROOT="${MODEL_ROOT:-$HOME/ai4math/models}"
SCRATCH_ROOT="${SCRATCH:-/scratch/users/$USER}"
VENV_DIR="${VENV_DIR:-$SCRATCH_ROOT/.venvs/hf-download}"
REBUILD_ENV="${REBUILD_ENV:-0}"
ENV_READY_FILE="$VENV_DIR/.cpu_test_deps_ready"

export MODEL_ID MODEL_ROOT
export HF_HOME="${HF_HOME:-$SCRATCH_ROOT/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$SCRATCH_ROOT/.cache/pip}"

echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Node: ${SLURMD_NODENAME:-$(hostname)}"
echo "Model: $MODEL_ID"
echo "Destination root: $MODEL_ROOT"
if [[ -n "${MODEL_DIR:-}" ]]; then
  echo "Single-model destination override: $MODEL_DIR"
fi
echo "HF_HOME: $HF_HOME"
echo "Started: $(date -Is)"

mkdir -p "$MODEL_ROOT" "$HF_HOME" "$PIP_CACHE_DIR" "$(dirname "$VENV_DIR")"

if ! command -v python3 >/dev/null 2>&1; then
  module load python || true
fi

if [[ "$REBUILD_ENV" == "1" || ! -x "$VENV_DIR/bin/python" || ! -f "$ENV_READY_FILE" ]]; then
  echo "Building Python environment: $VENV_DIR"
  rm -rf "$VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  python -m pip install --upgrade pip
  python -m pip install --upgrade "huggingface_hub[cli]>=0.23"
  touch "$ENV_READY_FILE"
else
  echo "Using existing Python environment: $VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
fi

python - <<'PY'
import os
from pathlib import Path
from huggingface_hub import snapshot_download

model_id = os.environ["MODEL_ID"]
model_root = Path(os.environ["MODEL_ROOT"]).expanduser()
model_dir_override = os.environ.get("MODEL_DIR")

if model_dir_override:
    model_dir = Path(model_dir_override).expanduser()
else:
    local_name = model_id.split("/", 1)[1] if "/" in model_id else model_id
    model_dir = model_root / local_name

model_dir.mkdir(parents=True, exist_ok=True)
print(f"Downloading {model_id} to {model_dir}", flush=True)
snapshot_download(
    repo_id=model_id,
    local_dir=str(model_dir),
    local_dir_use_symlinks=False,
    resume_download=True,
)
print(f"Downloaded {model_id} to {model_dir}", flush=True)
PY

echo "Downloaded model directory:"
if [[ -n "${MODEL_DIR:-}" ]]; then
  model_path="$MODEL_DIR"
else
  local_name="${MODEL_ID#*/}"
  model_path="$MODEL_ROOT/$local_name"
fi

du -sh "$model_path"
find "$model_path" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort

echo "Completed: $(date -Is)"
