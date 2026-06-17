#!/bin/bash -l
#SBATCH --job-name=upload_model
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=03:00:00
#SBATCH --output=/scratch/users/%u/%x-%j.out
#SBATCH --error=/scratch/users/%u/%x-%j.err

set -euo pipefail

: "${MODEL_DIR:?MODEL_DIR must point to the model directory to upload}"
: "${HF_REPO_ID:?HF_REPO_ID must be in namespace/repository format}"

SCRATCH_ROOT="${SCRATCH:-/scratch/users/$USER}"
VENV_DIR="${VENV_DIR:-$SCRATCH_ROOT/.venvs/hf-upload}"
REBUILD_ENV="${REBUILD_ENV:-0}"
ENV_READY_FILE="$VENV_DIR/.deps_ready"
HF_REPO_PRIVATE="${HF_REPO_PRIVATE:-0}"

if [[ -z "${HF_TOKEN:-}" && -s "$HOME/.hf_token" ]]; then
  HF_TOKEN="$(<"$HOME/.hf_token")"
  export HF_TOKEN
elif [[ -z "${HF_TOKEN:-}" && -s "$HOME/.cache/huggingface/token" ]]; then
  HF_TOKEN="$(<"$HOME/.cache/huggingface/token")"
  export HF_TOKEN
fi

export HF_HOME="${HF_HOME:-$SCRATCH_ROOT/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$SCRATCH_ROOT/.cache/pip}"
export MODEL_DIR HF_REPO_ID HF_REPO_PRIVATE

echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Node: ${SLURMD_NODENAME:-$(hostname)}"
echo "Model directory: $MODEL_DIR"
echo "Hugging Face repository: $HF_REPO_ID"
echo "Private repository: $HF_REPO_PRIVATE"
echo "Started: $(date -Is)"

if [[ ! -d "$MODEL_DIR" ]]; then
  echo "error: model directory does not exist: $MODEL_DIR" >&2
  exit 2
fi

if [[ ! -f "$MODEL_DIR/config.json" ]]; then
  echo "error: model directory has no config.json: $MODEL_DIR" >&2
  exit 2
fi

if ! find "$MODEL_DIR" -maxdepth 1 -type f \
    \( -name 'model*.safetensors' -o -name 'pytorch_model*.bin' \) \
    -print -quit | grep -q .; then
  echo "error: model directory has no model weights: $MODEL_DIR" >&2
  exit 2
fi

mkdir -p "$HF_HOME" "$PIP_CACHE_DIR" "$(dirname "$VENV_DIR")"

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
  python -m pip install --upgrade "huggingface_hub>=0.30.0"
  touch "$ENV_READY_FILE"
else
  echo "Using existing Python environment: $VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
fi

python - <<'PY'
import os
from pathlib import Path

from huggingface_hub import HfApi

model_dir = Path(os.environ["MODEL_DIR"]).expanduser().resolve()
repo_id = os.environ["HF_REPO_ID"]
private = os.environ["HF_REPO_PRIVATE"] == "1"

api = HfApi()
user = api.whoami()
print(f"Authenticated as {user['name']}", flush=True)
api.create_repo(repo_id=repo_id, repo_type="model", private=private, exist_ok=True)
url = api.upload_folder(
    repo_id=repo_id,
    repo_type="model",
    folder_path=str(model_dir),
    commit_message=f"Upload model from {model_dir.name}",
)
print(f"UPLOAD_DONE {url}", flush=True)
PY

echo "Completed: $(date -Is)"
