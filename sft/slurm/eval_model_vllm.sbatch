#!/bin/bash -l
#SBATCH --job-name=eval_model_vllm
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=01:00:00
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
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-${MODEL_ID#*/}}"
DATASET_ID="${DATASET_ID:-openai/gsm8k}"
DATASET_CONFIG="${DATASET_CONFIG:-main}"
DATASET_SPLIT="${DATASET_SPLIT:-test}"
DATASET_QUESTION_FIELD="${DATASET_QUESTION_FIELD:-question}"
DATASET_ANSWER_FIELD="${DATASET_ANSWER_FIELD:-answer}"
NUM_PROBLEMS="${NUM_PROBLEMS:-2}"
SCRATCH_ROOT="${SCRATCH:-/scratch/users/$USER}"
VENV_DIR="${VENV_DIR:-$SCRATCH_ROOT/.venvs/vllm-eval}"
REBUILD_ENV="${REBUILD_ENV:-0}"
ENV_READY_FILE="$VENV_DIR/.cpu_test_deps_ready"
VLLM_HOST="${VLLM_HOST:-127.0.0.1}"
VLLM_PORT="${VLLM_PORT:-$((18000 + (${SLURM_JOB_ID:-0} % 10000)))}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/ai4math/results}"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu118}"
TORCH_VERSION="${TORCH_VERSION:-2.6.0+cu118}"
TORCHAUDIO_VERSION="${TORCHAUDIO_VERSION:-2.6.0+cu118}"
TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.21.0+cu118}"
VLLM_VERSION="${VLLM_VERSION:-0.8.5}"

slug() {
  printf '%s' "$1" | tr '/: ' '___' | tr -cd '[:alnum:]_.-'
}

MODEL_SLUG="$(slug "$MODEL_ID")"
DATASET_SLUG="$(slug "$DATASET_ID")"
RESULTS_FILE="${RESULTS_FILE:-$RESULTS_DIR/${MODEL_SLUG}_${DATASET_SLUG}_${DATASET_SPLIT}_first${NUM_PROBLEMS}_${SLURM_JOB_ID:-manual}.jsonl}"

export MODEL_ID MODEL_PATH SERVED_MODEL_NAME
export DATASET_ID DATASET_CONFIG DATASET_SPLIT DATASET_QUESTION_FIELD DATASET_ANSWER_FIELD NUM_PROBLEMS
export VLLM_HOST VLLM_PORT RESULTS_FILE
export HF_HOME="${HF_HOME:-$SCRATCH_ROOT/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$SCRATCH_ROOT/.cache/pip}"

echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Node: ${SLURMD_NODENAME:-$(hostname)}"
echo "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-unset}"
echo "Model ID: $MODEL_ID"
echo "Model path: $MODEL_PATH"
echo "Served model name: $SERVED_MODEL_NAME"
echo "Dataset: $DATASET_ID config=${DATASET_CONFIG:-none} split=$DATASET_SPLIT first $NUM_PROBLEMS"
echo "Question field: $DATASET_QUESTION_FIELD"
echo "Answer field: $DATASET_ANSWER_FIELD"
echo "Results file: $RESULTS_FILE"
echo "Started: $(date -Is)"

mkdir -p "$RESULTS_DIR" "$HF_HOME" "$PIP_CACHE_DIR" "$(dirname "$VENV_DIR")"

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
    "vllm==$VLLM_VERSION" \
    --no-deps

  python -m pip install --upgrade \
    "cachetools" \
    "psutil" \
    "sentencepiece" \
    "numpy<2" \
    "requests>=2.31" \
    "tqdm" \
    "blake3" \
    "py-cpuinfo" \
    "transformers>=4.51.1,<5" \
    "huggingface-hub>=0.30.0" \
    "tokenizers>=0.21.1" \
    "protobuf" \
    "fastapi[standard]>=0.115.0" \
    "aiohttp" \
    "openai>=1.52.0" \
    "pydantic>=2.9" \
    "prometheus_client>=0.18.0" \
    "pillow" \
    "prometheus-fastapi-instrumentator>=7.0.0" \
    "tiktoken>=0.6.0" \
    "lm-format-enforcer>=0.10.11,<0.11" \
    "llguidance>=0.7.9,<0.8.0" \
    "outlines==0.1.11" \
    "outlines_core==0.1.26" \
    "lark==1.2.2" \
    "xgrammar==0.1.18" \
    "typing_extensions>=4.10" \
    "filelock>=3.16.1" \
    "partial-json-parser" \
    "pyzmq>=25.0.0" \
    "msgspec" \
    "gguf>=0.13.0" \
    "importlib_metadata" \
    "mistral_common[opencv]>=1.5.4" \
    "opencv-python-headless>=4.11.0" \
    "pyyaml" \
    "six>=1.16.0" \
    "setuptools>=74.1.1" \
    "einops" \
    "compressed-tensors==0.9.3" \
    "depyf==0.18.0" \
    "cloudpickle" \
    "watchfiles" \
    "python-json-logger" \
    "scipy" \
    "ninja" \
    "opentelemetry-sdk>=1.26.0,<1.27.0" \
    "opentelemetry-api>=1.26.0,<1.27.0" \
    "opentelemetry-exporter-otlp>=1.26.0,<1.27.0" \
    "opentelemetry-semantic-conventions-ai>=0.4.1,<0.5.0" \
    "numba==0.61.2" \
    "ray[cgraph]>=2.43.0,!=2.44.*" \
    "xformers==0.0.29.post2" \
    "datasets>=2.19"
  touch "$ENV_READY_FILE"
else
  echo "Using existing Python environment: $VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
fi

python - <<'PY'
import torch
import vllm
print(f"torch={torch.__version__} cuda={torch.version.cuda} vllm={vllm.__version__}", flush=True)
PY

echo "GPU status:"
nvidia-smi

echo "Starting vLLM server on $VLLM_HOST:$VLLM_PORT"
python -m vllm.entrypoints.openai.api_server \
  --model "$MODEL_PATH" \
  --served-model-name "$SERVED_MODEL_NAME" \
  --host "$VLLM_HOST" \
  --port "$VLLM_PORT" \
  --dtype auto \
  --gpu-memory-utilization 0.70 \
  --max-model-len 4096 \
  >"$RESULTS_DIR/vllm_${SLURM_JOB_ID:-manual}.log" 2>&1 &
VLLM_PID=$!

cleanup() {
  if kill -0 "$VLLM_PID" >/dev/null 2>&1; then
    kill "$VLLM_PID" >/dev/null 2>&1 || true
    wait "$VLLM_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

python - <<'PY'
import os
import sys
import time
import requests

base_url = f"http://{os.environ['VLLM_HOST']}:{os.environ['VLLM_PORT']}/v1"
deadline = time.time() + 900

while time.time() < deadline:
    try:
        response = requests.get(f"{base_url}/models", timeout=5)
        if response.ok:
            print("vLLM server is ready", flush=True)
            sys.exit(0)
    except Exception:
        pass
    time.sleep(5)

print("vLLM server did not become ready in time", file=sys.stderr)
sys.exit(1)
PY

python - <<'PY'
import json
import os
import re
from decimal import Decimal, InvalidOperation

import requests
from datasets import load_dataset

base_url = f"http://{os.environ['VLLM_HOST']}:{os.environ['VLLM_PORT']}/v1"
model = os.environ["SERVED_MODEL_NAME"]
dataset_id = os.environ["DATASET_ID"]
dataset_config = os.environ["DATASET_CONFIG"] or None
split = os.environ["DATASET_SPLIT"]
question_field = os.environ["DATASET_QUESTION_FIELD"]
answer_field = os.environ["DATASET_ANSWER_FIELD"]
num_problems = int(os.environ["NUM_PROBLEMS"])
results_file = os.environ["RESULTS_FILE"]

def extract_gold(answer: str) -> str:
    if "####" in answer:
        answer = answer.rsplit("####", 1)[1]
    return extract_number(answer)

def extract_number(text: str) -> str:
    matches = re.findall(r"[-+]?\d[\d,]*(?:\.\d+)?", text)
    if not matches:
        return ""
    return matches[-1].replace(",", "")

def normalize_number(value: str) -> str:
    if not value:
        return ""
    try:
        number = Decimal(value)
    except InvalidOperation:
        return value.strip()
    return format(number.normalize(), "f").rstrip("0").rstrip(".") or "0"

def generate(prompt: str) -> str:
    response = requests.post(
        f"{base_url}/completions",
        json={
            "model": model,
            "prompt": prompt,
            "max_tokens": 256,
            "temperature": 0.0,
            "stop": ["\n\nQuestion:"],
        },
        timeout=120,
    )
    response.raise_for_status()
    return response.json()["choices"][0]["text"]

if dataset_config:
    dataset = load_dataset(dataset_id, dataset_config, split=split)
else:
    dataset = load_dataset(dataset_id, split=split)

limit = min(num_problems, len(dataset))
correct = 0
rows = []

for index, example in enumerate(dataset.select(range(limit))):
    question = str(example[question_field])
    gold = normalize_number(extract_gold(str(example[answer_field])))
    prompt = (
        "Solve the problem. Show concise reasoning and end with exactly "
        "'Final answer: <number>'.\n\n"
        f"Question: {question}\nAnswer:"
    )
    output = generate(prompt)
    pred = normalize_number(extract_number(output))
    is_correct = pred == gold
    correct += int(is_correct)
    row = {
        "index": index,
        "question": question,
        "gold": gold,
        "prediction": pred,
        "correct": is_correct,
        "output": output.strip(),
    }
    rows.append(row)
    print(json.dumps(row, ensure_ascii=True), flush=True)

accuracy = correct / limit if limit else 0.0
summary = {
    "model": model,
    "model_id": os.environ["MODEL_ID"],
    "model_path": os.environ["MODEL_PATH"],
    "dataset": dataset_id,
    "dataset_config": dataset_config,
    "split": split,
    "num_problems": limit,
    "requested_num_problems": num_problems,
    "correct": correct,
    "accuracy": accuracy,
}

with open(results_file, "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row, ensure_ascii=True) + "\n")
    handle.write(json.dumps({"summary": summary}, ensure_ascii=True) + "\n")

print("SUMMARY " + json.dumps(summary, ensure_ascii=True), flush=True)
print(f"Wrote {results_file}", flush=True)
PY

echo "Completed: $(date -Is)"
