#!/bin/bash -l
#SBATCH --job-name=finetune_trl
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=48G
#SBATCH --time=02:00:00
#SBATCH --output=/scratch/users/%u/%x-%j.out
#SBATCH --error=/scratch/users/%u/%x-%j.err

set -euo pipefail

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

DATASET_ID="${DATASET_ID:-GAIR/LIMO}"
DATASET_CONFIG="${DATASET_CONFIG:-}"
DATASET_SPLIT="${DATASET_SPLIT:-train}"
MAX_TRAIN_SAMPLES="${MAX_TRAIN_SAMPLES:-2}"
QUESTION_FIELD="${QUESTION_FIELD:-question}"
SOLUTION_FIELD="${SOLUTION_FIELD:-solution}"
ANSWER_FIELD="${ANSWER_FIELD:-answer}"
TEXT_FIELD="${TEXT_FIELD:-}"

SCRATCH_ROOT="${SCRATCH:-/scratch/users/$USER}"
GPU_PROFILE="${GPU_PROFILE:-l40s}"
case "$GPU_PROFILE" in
  a100|l40s)
    TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu118}"
    TORCH_VERSION="${TORCH_VERSION:-2.6.0+cu118}"
    TORCHAUDIO_VERSION="${TORCHAUDIO_VERSION:-2.6.0+cu118}"
    TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.21.0+cu118}"
    VLLM_VERSION="${VLLM_VERSION:-0.8.5}"
    TRL_VERSION="${TRL_VERSION:-0.19.1}"
    TRANSFORMERS_VERSION="${TRANSFORMERS_VERSION:-4.51.3}"
    VLLM_INSTALL_WITH_DEPS="${VLLM_INSTALL_WITH_DEPS:-0}"
    ;;
  b200)
    TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
    TORCH_VERSION="${TORCH_VERSION:-2.8.0+cu128}"
    TORCHAUDIO_VERSION="${TORCHAUDIO_VERSION:-2.8.0+cu128}"
    TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.23.0+cu128}"
    VLLM_VERSION="${VLLM_VERSION:-0.11.0}"
    TRL_VERSION="${TRL_VERSION:-0.19.1}"
    TRANSFORMERS_VERSION="${TRANSFORMERS_VERSION:-4.56.2}"
    VLLM_INSTALL_WITH_DEPS="${VLLM_INSTALL_WITH_DEPS:-1}"
    ;;
  *)
    echo "error: unknown GPU_PROFILE '$GPU_PROFILE' (expected a100, l40s, or b200)" >&2
    exit 2
    ;;
esac

VENV_DIR="${VENV_DIR:-$SCRATCH_ROOT/.venvs/trl-finetune-$GPU_PROFILE}"
REBUILD_ENV="${REBUILD_ENV:-0}"
ENV_READY_FILE="$VENV_DIR/.cpu_test_deps_ready_${GPU_PROFILE}_${TORCH_VERSION}_${VLLM_VERSION}"
RUN_NAME="${RUN_NAME:-$(printf '%s_%s' "${MODEL_ID#*/}" "${DATASET_ID#*/}" | tr '/: ' '___' | tr -cd '[:alnum:]_.-')_first${MAX_TRAIN_SAMPLES}_${SLURM_JOB_ID:-manual}}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/ai4math/finetunes}"
TRAIN_OUTPUT_DIR="${TRAIN_OUTPUT_DIR:-$OUTPUT_ROOT/$RUN_NAME/adapter_or_full}"
MERGED_MODEL_DIR="${MERGED_MODEL_DIR:-$OUTPUT_ROOT/$RUN_NAME/merged}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/ai4math/results}"

MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-2048}"
NUM_EPOCHS="${NUM_EPOCHS:-1}"
LEARNING_RATE="${LEARNING_RATE:-2e-4}"
PER_DEVICE_TRAIN_BATCH_SIZE="${PER_DEVICE_TRAIN_BATCH_SIZE:-1}"
GRADIENT_ACCUMULATION_STEPS="${GRADIENT_ACCUMULATION_STEPS:-1}"
LORA_R="${LORA_R:-16}"
LORA_ALPHA="${LORA_ALPHA:-32}"
LORA_DROPOUT="${LORA_DROPOUT:-0.05}"
FULL_FINETUNE="${FULL_FINETUNE:-0}"
USE_BF16="${USE_BF16:-1}"
USE_FP16="${USE_FP16:-0}"
SKIP_VLLM_SMOKE="${SKIP_VLLM_SMOKE:-0}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-2048}"

export HF_HOME="${HF_HOME:-$SCRATCH_ROOT/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$SCRATCH_ROOT/.cache/pip}"

echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Node: ${SLURMD_NODENAME:-$(hostname)}"
echo "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-unset}"
echo "GPU profile: $GPU_PROFILE"
echo "Model ID: $MODEL_ID"
echo "Model path: $MODEL_PATH"
echo "Dataset: $DATASET_ID config=${DATASET_CONFIG:-none} split=$DATASET_SPLIT first $MAX_TRAIN_SAMPLES"
echo "Train output: $TRAIN_OUTPUT_DIR"
echo "Merged checkpoint: $MERGED_MODEL_DIR"
echo "Started: $(date -Is)"

mkdir -p "$OUTPUT_ROOT" "$RESULTS_DIR" "$HF_HOME" "$PIP_CACHE_DIR" "$(dirname "$VENV_DIR")"
SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
export MERGED_MODEL_DIR VLLM_MAX_MODEL_LEN

WANDB_CONF="${WANDB_CONF:-$SCRIPT_DIR/wandb.conf.sh}"
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
  echo "W&B reporting: disabled"
elif [[ -n "${WANDB_API_KEY:-}" ]]; then
  REPORT_TO="${REPORT_TO:-wandb}"
  if [[ "$REPORT_TO" == "none" ]]; then
    REPORT_TO="wandb"
  fi
  export WANDB_PROJECT="${WANDB_PROJECT:-ai4math}"
  export WANDB_RUN_NAME="${WANDB_RUN_NAME:-$RUN_NAME}"
  export WANDB_MODE="${WANDB_MODE:-online}"
  echo "W&B reporting: project=$WANDB_PROJECT run=$WANDB_RUN_NAME"
else
  echo "W&B reporting: disabled"
fi

if ! command -v python3 >/dev/null 2>&1; then
  module load python || true
fi

module load cuda/12.2.1-gcc-13.2.0 2>/dev/null || module load cuda 2>/dev/null || true
if [[ -n "${CUDA_HOME:-}" && -d "$CUDA_HOME/lib64" ]]; then
  export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
fi
echo "CUDA_HOME: ${CUDA_HOME:-unset}"
echo "LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-unset}"

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

  if [[ "$VLLM_INSTALL_WITH_DEPS" == "1" ]]; then
    python -m pip install --upgrade "vllm==$VLLM_VERSION" --extra-index-url "$TORCH_INDEX_URL"
  else
    python -m pip install --upgrade "vllm==$VLLM_VERSION" --no-deps
    python -m pip install --upgrade \
      "cachetools" "psutil" "requests>=2.31" "tqdm" "blake3" "py-cpuinfo" \
      "tokenizers>=0.21.1" "fastapi[standard]>=0.115.0" "aiohttp" "openai>=1.52.0" \
      "pydantic>=2.9" "prometheus_client>=0.18.0" "pillow" \
      "prometheus-fastapi-instrumentator>=7.0.0" "tiktoken>=0.6.0" \
      "lm-format-enforcer>=0.10.11,<0.11" "llguidance>=0.7.9,<0.8.0" \
      "outlines==0.1.11" "outlines_core==0.1.26" "lark==1.2.2" "xgrammar==0.1.18" \
      "typing_extensions>=4.10" "filelock>=3.16.1" "partial-json-parser" \
      "pyzmq>=25.0.0" "msgspec" "gguf>=0.13.0" "importlib_metadata" \
      "mistral_common[opencv]>=1.5.4" "opencv-python-headless>=4.11.0" "pyyaml" \
      "six>=1.16.0" "setuptools>=74.1.1" "einops" "compressed-tensors==0.9.3" \
      "depyf==0.18.0" "cloudpickle" "watchfiles" "python-json-logger" "scipy" \
      "ninja" "opentelemetry-sdk>=1.26.0,<1.27.0" "opentelemetry-api>=1.26.0,<1.27.0" \
      "opentelemetry-exporter-otlp>=1.26.0,<1.27.0" \
      "opentelemetry-semantic-conventions-ai>=0.4.1,<0.5.0" "numba==0.61.2" \
      "ray[cgraph]>=2.43.0,!=2.44.*" "xformers==0.0.29.post2"
  fi
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

echo "GPU status:"
nvidia-smi

train_args=(
  --model "$MODEL_PATH"
  --dataset "$DATASET_ID"
  --split "$DATASET_SPLIT"
  --output-dir "$TRAIN_OUTPUT_DIR"
  --merged-output-dir "$MERGED_MODEL_DIR"
  --max-train-samples "$MAX_TRAIN_SAMPLES"
  --question-field "$QUESTION_FIELD"
  --solution-field "$SOLUTION_FIELD"
  --answer-field "$ANSWER_FIELD"
  --max-seq-length "$MAX_SEQ_LENGTH"
  --epochs "$NUM_EPOCHS"
  --learning-rate "$LEARNING_RATE"
  --per-device-train-batch-size "$PER_DEVICE_TRAIN_BATCH_SIZE"
  --gradient-accumulation-steps "$GRADIENT_ACCUMULATION_STEPS"
  --lora-r "$LORA_R"
  --lora-alpha "$LORA_ALPHA"
  --lora-dropout "$LORA_DROPOUT"
  --report-to "$REPORT_TO"
  --run-name "${WANDB_RUN_NAME:-$RUN_NAME}"
)

if [[ -n "$DATASET_CONFIG" ]]; then
  train_args+=(--dataset-config "$DATASET_CONFIG")
fi
if [[ -n "$TEXT_FIELD" ]]; then
  train_args+=(--text-field "$TEXT_FIELD")
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

python "$SCRIPT_DIR/train_model_trl.py" "${train_args[@]}"

if [[ "$SKIP_VLLM_SMOKE" != "1" ]]; then
  echo "Testing merged checkpoint with vLLM: $MERGED_MODEL_DIR"
  python - <<'PY'
import os
from vllm import LLM, SamplingParams

model_dir = os.environ["MERGED_MODEL_DIR"]
llm = LLM(
    model=model_dir,
    trust_remote_code=True,
    dtype="auto",
    max_model_len=int(os.environ["VLLM_MAX_MODEL_LEN"]),
    gpu_memory_utilization=0.70,
)
outputs = llm.generate(
    ["Question:\nWhat is 1+1?\n\nAnswer:\n"],
    SamplingParams(max_tokens=16, temperature=0.0),
)
print(outputs[0].outputs[0].text.strip(), flush=True)
print("vLLM smoke test loaded the merged checkpoint successfully", flush=True)
PY
fi

echo "Completed: $(date -Is)"
