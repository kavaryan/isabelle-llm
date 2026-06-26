#!/bin/bash -l
#SBATCH --job-name=grpo_isabelle
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=08:00:00
#SBATCH --output=/scratch/users/%u/%x-%j.out
#SBATCH --error=/scratch/users/%u/%x-%j.err

set -euo pipefail

SUBMIT_ROOT="${SLURM_SUBMIT_DIR:-$(pwd)}"
if [[ -d "$SUBMIT_ROOT/slurm" ]]; then
  SCRIPT_DIR="$SUBMIT_ROOT/slurm"
  RL_ROOT="$SUBMIT_ROOT"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
REPO_ROOT="$(cd "$RL_ROOT/../.." && pwd)"
SFT_SLURM_DIR="$REPO_ROOT/sft/slurm"

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

DATASET_ID="${DATASET_ID:-$REPO_ROOT/sft/sft-data}"
DATASET_CONFIG="${DATASET_CONFIG:-}"
DATASET_SPLIT="${DATASET_SPLIT:-train}"
MAX_TRAIN_SAMPLES="${MAX_TRAIN_SAMPLES:--1}"

SCRATCH_ROOT="${SCRATCH:-/scratch/users/$USER}"
GPU_PROFILE="${GPU_PROFILE:-l40s}"
case "$GPU_PROFILE" in
  a100|l40s)
    TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu118}"
    TORCH_VERSION="${TORCH_VERSION:-2.6.0+cu118}"
    TORCHAUDIO_VERSION="${TORCHAUDIO_VERSION:-2.6.0+cu118}"
    TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.21.0+cu118}"
    TRL_VERSION="${TRL_VERSION:-0.19.1}"
    TRANSFORMERS_VERSION="${TRANSFORMERS_VERSION:-4.51.3}"
    ;;
  b200)
    TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
    TORCH_VERSION="${TORCH_VERSION:-2.8.0+cu128}"
    TORCHAUDIO_VERSION="${TORCHAUDIO_VERSION:-2.8.0+cu128}"
    TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.23.0+cu128}"
    TRL_VERSION="${TRL_VERSION:-0.19.1}"
    TRANSFORMERS_VERSION="${TRANSFORMERS_VERSION:-4.56.2}"
    ;;
  *)
    echo "error: unknown GPU_PROFILE '$GPU_PROFILE' (expected a100, l40s, or b200)" >&2
    exit 2
    ;;
esac

VENV_DIR="${VENV_DIR:-$SCRATCH_ROOT/.venvs/trl-grpo-$GPU_PROFILE}"
REBUILD_ENV="${REBUILD_ENV:-0}"
ENV_READY_FILE="$VENV_DIR/.grpo_deps_ready_${GPU_PROFILE}_${TORCH_VERSION}_${TRL_VERSION}"
DATASET_LABEL="$(basename "$DATASET_ID")"
RUN_TIMESTAMP="${RUN_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
RUN_NAME="${RUN_NAME:-$(printf '%s_grpo_%s_%s' "${MODEL_ID#*/}" "$DATASET_LABEL" "$RUN_TIMESTAMP" | tr '/: ' '___' | tr -cd '[:alnum:]_.-')_first${MAX_TRAIN_SAMPLES}_${SLURM_JOB_ID:-manual}}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/ai4math/grpo}"
TRAIN_OUTPUT_DIR="${TRAIN_OUTPUT_DIR:-$OUTPUT_ROOT/$RUN_NAME/adapter_or_full}"
MERGED_MODEL_DIR="${MERGED_MODEL_DIR:-$OUTPUT_ROOT/$RUN_NAME/merged}"

MAX_PROMPT_LENGTH="${MAX_PROMPT_LENGTH:-3072}"
MAX_COMPLETION_LENGTH="${MAX_COMPLETION_LENGTH:-128}"
MAX_STEPS="${MAX_STEPS:-100}"
NUM_EPOCHS="${NUM_EPOCHS:-1}"
LEARNING_RATE="${LEARNING_RATE:-1e-6}"
PER_DEVICE_TRAIN_BATCH_SIZE="${PER_DEVICE_TRAIN_BATCH_SIZE:-1}"
GRADIENT_ACCUMULATION_STEPS="${GRADIENT_ACCUMULATION_STEPS:-1}"
NUM_GENERATIONS="${NUM_GENERATIONS:-4}"
TEMPERATURE="${TEMPERATURE:-0.7}"
TOP_P="${TOP_P:-0.95}"
BETA="${BETA:-0.04}"
SCALE_REWARDS="${SCALE_REWARDS:-true}"
REWARD_WORKERS="${REWARD_WORKERS:-1}"
LORA_R="${LORA_R:-16}"
LORA_ALPHA="${LORA_ALPHA:-32}"
LORA_DROPOUT="${LORA_DROPOUT:-0.05}"
FULL_FINETUNE="${FULL_FINETUNE:-0}"
USE_BF16="${USE_BF16:-1}"
USE_FP16="${USE_FP16:-0}"

export HF_HOME="${HF_HOME:-$SCRATCH_ROOT/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$SCRATCH_ROOT/.cache/pip}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export ISABELLE="${ISABELLE:-$SCRATCH_ROOT/ai4math/isabelle/Isabelle2025-2/bin/isabelle}"
export ISABELLE_HOME_USER="${ISABELLE_HOME_USER:-$SCRATCH_ROOT/ai4math/isabelle-home-user/Isabelle2025-2}"
export ISABELLE_EXTRACTOR_JSON_DIR="${ISABELLE_EXTRACTOR_JSON_DIR:-$REPO_ROOT/extractor/proof_extractor_out/json}"
export ISABELLE_REWARD_CHECKER="${ISABELLE_REWARD_CHECKER:-$SCRIPT_DIR/check_isabelle_reward.py}"
export ISABELLE_REWARD_LOGIC="${ISABELLE_REWARD_LOGIC:-HOL}"
export ISABELLE_REWARD_EXTRA_DIRS="${ISABELLE_REWARD_EXTRA_DIRS:-$SCRATCH_ROOT/ai4math/afp/afp-2025-2/thys}"
export ISABELLE_THEORY_SESSION_MAP="${ISABELLE_THEORY_SESSION_MAP:-$SCRIPT_DIR/theory_sessions.json}"

echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Node: ${SLURMD_NODENAME:-$(hostname)}"
echo "GPU profile: $GPU_PROFILE"
echo "Model path: $MODEL_PATH"
echo "Dataset: $DATASET_ID split=$DATASET_SPLIT first $MAX_TRAIN_SAMPLES"
echo "GRPO: steps=$MAX_STEPS generations=$NUM_GENERATIONS max_prompt=$MAX_PROMPT_LENGTH max_completion=$MAX_COMPLETION_LENGTH"
echo "Reward checker: $ISABELLE_REWARD_CHECKER"
echo "Isabelle: $ISABELLE"
echo "Isabelle home user: $ISABELLE_HOME_USER"
echo "Extractor JSON: $ISABELLE_EXTRACTOR_JSON_DIR"
echo "Theory session map: $ISABELLE_THEORY_SESSION_MAP"
echo "Train output: $TRAIN_OUTPUT_DIR"
echo "Merged checkpoint: $MERGED_MODEL_DIR"
echo "Started: $(date -Is)"

mkdir -p "$OUTPUT_ROOT" "$HF_HOME" "$PIP_CACHE_DIR" "$(dirname "$VENV_DIR")" "$ISABELLE_HOME_USER"

WANDB_CONF="${WANDB_CONF:-$SFT_SLURM_DIR/wandb.conf.sh}"
if [[ -f "$WANDB_CONF" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$WANDB_CONF"
  set +a
fi
REPORT_TO="${REPORT_TO:-none}"
if [[ "${DISABLE_WANDB:-0}" == "1" ]]; then
  REPORT_TO="none"
  export WANDB_MODE="disabled"
elif [[ -n "${WANDB_API_KEY:-}" ]]; then
  REPORT_TO="${REPORT_TO:-wandb}"
  if [[ "$REPORT_TO" == "none" ]]; then
    REPORT_TO="wandb"
  fi
  export WANDB_PROJECT="${WANDB_PROJECT:-ai4math}"
  export WANDB_RUN_NAME="${WANDB_RUN_NAME:-$RUN_NAME}"
  export WANDB_RUN_ID="${WANDB_RUN_ID:-$RUN_NAME}"
  export WANDB_RESUME="${WANDB_RESUME:-allow}"
  export WANDB_MODE="${WANDB_MODE:-online}"
fi

PYTHON_MODULE="${PYTHON_MODULE:-}"
CUDA_MODULE="${CUDA_MODULE:-cuda/12.2.1-gcc-13.2.0}"
if [[ -n "$PYTHON_MODULE" ]]; then
  module load "$PYTHON_MODULE"
fi
if [[ -n "$CUDA_MODULE" ]]; then
  module load "$CUDA_MODULE"
fi
if [[ -n "${CUDA_HOME:-}" && -d "$CUDA_HOME/lib64" ]]; then
  export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
fi

if [[ "$REBUILD_ENV" == "1" || ! -x "$VENV_DIR/bin/python" || ! -f "$ENV_READY_FILE" ]]; then
  echo "Building Python environment: $VENV_DIR"
  rm -rf "$VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip
  python -m pip install --upgrade \
    --index-url "$TORCH_INDEX_URL" \
    "torch==$TORCH_VERSION" \
    "torchaudio==$TORCHAUDIO_VERSION" \
    "torchvision==$TORCHVISION_VERSION"
  python -m pip install --upgrade \
    "transformers==$TRANSFORMERS_VERSION" \
    "trl==$TRL_VERSION" \
    "peft>=0.13.0" \
    "accelerate>=0.34.0" \
    "datasets>=2.19" \
    "wandb>=0.17" \
    "sentencepiece" \
    "protobuf" \
    "numpy<2" \
    "safetensors" \
    "huggingface-hub>=0.30.0"
  touch "$ENV_READY_FILE"
else
  echo "Using existing Python environment: $VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
fi

python - <<'PY'
import torch
import transformers
import trl
print(f"torch={torch.__version__} cuda={torch.version.cuda} transformers={transformers.__version__} trl={trl.__version__}", flush=True)
PY
nvidia-smi

"$VENV_DIR/bin/python" "$ISABELLE_REWARD_CHECKER" --help >/dev/null

export PYTHONPATH="$SCRIPT_DIR:$SFT_SLURM_DIR${PYTHONPATH:+:$PYTHONPATH}"

train_args=(
  --model "$MODEL_PATH"
  --dataset "$DATASET_ID"
  --split "$DATASET_SPLIT"
  --output-dir "$TRAIN_OUTPUT_DIR"
  --merged-output-dir "$MERGED_MODEL_DIR"
  --max-train-samples "$MAX_TRAIN_SAMPLES"
  --max-prompt-length "$MAX_PROMPT_LENGTH"
  --max-completion-length "$MAX_COMPLETION_LENGTH"
  --max-steps "$MAX_STEPS"
  --epochs "$NUM_EPOCHS"
  --learning-rate "$LEARNING_RATE"
  --per-device-train-batch-size "$PER_DEVICE_TRAIN_BATCH_SIZE"
  --gradient-accumulation-steps "$GRADIENT_ACCUMULATION_STEPS"
  --num-generations "$NUM_GENERATIONS"
  --temperature "$TEMPERATURE"
  --top-p "$TOP_P"
  --beta "$BETA"
  --scale-rewards "$SCALE_REWARDS"
  --reward-workers "$REWARD_WORKERS"
  --lora-r "$LORA_R"
  --lora-alpha "$LORA_ALPHA"
  --lora-dropout "$LORA_DROPOUT"
  --report-to "$REPORT_TO"
  --run-name "${WANDB_RUN_NAME:-$RUN_NAME}"
)
if [[ -n "$DATASET_CONFIG" ]]; then
  train_args+=(--dataset-config "$DATASET_CONFIG")
fi
if [[ "$FULL_FINETUNE" == "1" ]]; then
  train_args+=(--full-finetune)
fi
if [[ "$USE_BF16" == "1" ]]; then
  train_args+=(--bf16)
fi
if [[ "$USE_FP16" == "1" ]]; then
  train_args+=(--fp16)
fi

python "$SCRIPT_DIR/train_model_grpo.py" "${train_args[@]}"
echo "Completed: $(date -Is)"
