#!/bin/bash -l
#SBATCH --job-name=finetune_trl
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=48G
#SBATCH --time=04:00:00
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
SOURCE_DATASET_ID="$DATASET_ID"
DATASET_CONFIG="${DATASET_CONFIG:-}"
DATASET_SPLIT="${DATASET_SPLIT:-train}"
MAX_TRAIN_SAMPLES="${MAX_TRAIN_SAMPLES:--1}"
QUESTION_FIELD="${QUESTION_FIELD:-question}"
SOLUTION_FIELD="${SOLUTION_FIELD:-solution}"
ANSWER_FIELD="${ANSWER_FIELD:-answer}"
TEXT_FIELD="${TEXT_FIELD:-}"
PREPARE_ISABELLE_SFT_DATA="${PREPARE_ISABELLE_SFT_DATA:-1}"
SMOKE_TEST="${SMOKE_TEST:-0}"
RUN_EVAL_AFTER_TRAIN="${RUN_EVAL_AFTER_TRAIN:-1}"

SCRATCH_ROOT="${SCRATCH:-/scratch/users/$USER}"
PREPARE_SFT_DATA_SCRIPT="${PREPARE_SFT_DATA_SCRIPT:-$DATASET_ID/prepare_sft_data.py}"
if [[ "$SMOKE_TEST" == "1" ]]; then
  SMOKE_DATASET_DIR="${SMOKE_DATASET_DIR:-$SCRATCH_ROOT/isabelle-sft-smoke-${SLURM_JOB_ID:-manual}}"
  DATASET_ID="$SMOKE_DATASET_DIR"
  DATASET_CONFIG=""
  MAX_TRAIN_SAMPLES="${MAX_TRAIN_SAMPLES:--1}"
fi
EVAL_DATASET_ID="${EVAL_DATASET_ID:-$DATASET_ID}"
EVAL_DATASET_CONFIG="${EVAL_DATASET_CONFIG:-}"
EVAL_DATASET_SPLIT="${EVAL_DATASET_SPLIT:-test}"
if [[ "$SMOKE_TEST" == "1" ]]; then
  EVAL_NUM_PROBLEMS="${EVAL_NUM_PROBLEMS:-2}"
else
  EVAL_NUM_PROBLEMS="${EVAL_NUM_PROBLEMS:--1}"
fi
EVAL_MAX_TOKENS="${EVAL_MAX_TOKENS:-128}"
EVAL_BATCH_SIZE="${EVAL_BATCH_SIZE:-16}"
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
DATASET_LABEL="$(basename "$DATASET_ID")"
RUN_TIMESTAMP="${RUN_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
RUN_NAME="${RUN_NAME:-$(printf '%s_%s_%s' "${MODEL_ID#*/}" "$DATASET_LABEL" "$RUN_TIMESTAMP" | tr '/: ' '___' | tr -cd '[:alnum:]_.-')_first${MAX_TRAIN_SAMPLES}_${SLURM_JOB_ID:-manual}}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/ai4math/finetunes}"
TRAIN_OUTPUT_DIR="${TRAIN_OUTPUT_DIR:-$OUTPUT_ROOT/$RUN_NAME/adapter_or_full}"
MERGED_MODEL_DIR="${MERGED_MODEL_DIR:-$OUTPUT_ROOT/$RUN_NAME/merged}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/ai4math/results}"
EVAL_RESULTS_FILE="${EVAL_RESULTS_FILE:-$RESULTS_DIR/${RUN_NAME}_eval_${EVAL_DATASET_SPLIT}_${SLURM_JOB_ID:-manual}.jsonl}"

MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-3072}"
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
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-3072}"

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
echo "Epochs: $NUM_EPOCHS"
if [[ "$SMOKE_TEST" == "1" ]]; then
  echo "Smoke test: enabled (10 train examples, 2 test examples)"
  echo "Estimated runtime: env build 20-45 min if cold, train/eval 3-8 min if the environment and model cache already exist; 45 min walltime is intended for warm-cache smoke tests."
else
  echo "Estimated runtime: env build 20-45 min if cold, train 15-45 min for Qwen3-0.6B LoRA on 2483 Isabelle examples, eval 10-25 min for 497 test examples; 4h walltime is conservative."
fi
echo "Train output: $TRAIN_OUTPUT_DIR"
echo "Merged checkpoint: $MERGED_MODEL_DIR"
echo "Eval after train: $RUN_EVAL_AFTER_TRAIN dataset=$EVAL_DATASET_ID split=$EVAL_DATASET_SPLIT num=$EVAL_NUM_PROBLEMS results=$EVAL_RESULTS_FILE"
echo "Started: $(date -Is)"

mkdir -p "$OUTPUT_ROOT" "$RESULTS_DIR" "$HF_HOME" "$PIP_CACHE_DIR" "$(dirname "$VENV_DIR")"
export SOURCE_DATASET_ID DATASET_ID MERGED_MODEL_DIR VLLM_MAX_MODEL_LEN
export EVAL_DATASET_ID EVAL_DATASET_CONFIG EVAL_DATASET_SPLIT EVAL_NUM_PROBLEMS EVAL_MAX_TOKENS EVAL_BATCH_SIZE EVAL_RESULTS_FILE
export PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}"

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
  export WANDB_RUN_ID="${WANDB_RUN_ID:-$RUN_NAME}"
  export WANDB_RESUME="${WANDB_RESUME:-allow}"
  export WANDB_MODE="${WANDB_MODE:-online}"
  echo "W&B reporting: project=$WANDB_PROJECT run=$WANDB_RUN_NAME id=$WANDB_RUN_ID"
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

if [[ "$SMOKE_TEST" == "1" && -f "$SOURCE_DATASET_ID/train.jsonl" && -f "$SOURCE_DATASET_ID/test.jsonl" ]]; then
  echo "Preparing smoke split from existing raw JSONL data: $SOURCE_DATASET_ID"
  mkdir -p "$DATASET_ID"
  python - <<'PY'
import json
import os
from pathlib import Path

source = Path(os.environ["SOURCE_DATASET_ID"])
target = Path(os.environ["DATASET_ID"])
train_rows = source.joinpath("train.jsonl").read_text(encoding="utf-8").splitlines()[:10]
test_rows = source.joinpath("test.jsonl").read_text(encoding="utf-8").splitlines()[:2]
if len(train_rows) != 10 or len(test_rows) != 2:
    raise ValueError(f"smoke split requires 10 train and 2 test rows; got {len(train_rows)} and {len(test_rows)}")
target.joinpath("train.jsonl").write_text("\n".join(train_rows) + "\n", encoding="utf-8")
target.joinpath("test.jsonl").write_text("\n".join(test_rows) + "\n", encoding="utf-8")
info = {
    "format": "jsonl",
    "smoke_test": True,
    "source_dataset": str(source),
    "num_train_examples": len(train_rows),
    "num_test_examples": len(test_rows),
    "prompt_field": "prompt",
    "completion_field": "completion",
    "text_field": "text",
}
target.joinpath("dataset_info.json").write_text(json.dumps(info, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"Wrote smoke split to {target}: train={len(train_rows)} test={len(test_rows)}", flush=True)
PY
elif [[ -f "$DATASET_ID/$DATASET_SPLIT.jsonl" && -f "$DATASET_ID/$EVAL_DATASET_SPLIT.jsonl" ]]; then
  echo "Using existing raw JSONL dataset at $DATASET_ID"
elif [[ "$PREPARE_ISABELLE_SFT_DATA" == "1" && -f "$PREPARE_SFT_DATA_SCRIPT" ]]; then
  echo "Preparing raw Isabelle SFT data"
  prepare_args=(
    --max-seq-length "$MAX_SEQ_LENGTH"
    --output-dir "$DATASET_ID"
  )
  if [[ "$SMOKE_TEST" == "1" ]]; then
    prepare_args+=(--smoke-test)
  fi
  python "$PREPARE_SFT_DATA_SCRIPT" "${prepare_args[@]}"
fi

train_args=(
  --model "$MODEL_PATH"
  --dataset "$DATASET_ID"
  --split "$DATASET_SPLIT"
  --eval-split "$EVAL_DATASET_SPLIT"
  --max-eval-samples "$EVAL_NUM_PROBLEMS"
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

if [[ "$RUN_EVAL_AFTER_TRAIN" == "1" ]]; then
  echo "Evaluating merged checkpoint on $EVAL_DATASET_ID split=$EVAL_DATASET_SPLIT with vLLM"
  python - <<'PY'
import json
import math
import os
import time
import gc

import wandb
from datasets import load_dataset
from sft_chat_stats import summarize_token_lengths
from transformers import AutoTokenizer
from vllm import LLM, SamplingParams

model_dir = os.environ["MERGED_MODEL_DIR"]
dataset_id = os.environ["EVAL_DATASET_ID"]
dataset_config = os.environ["EVAL_DATASET_CONFIG"] or None
split = os.environ["EVAL_DATASET_SPLIT"]
num_problems = int(os.environ["EVAL_NUM_PROBLEMS"])
max_tokens = int(os.environ["EVAL_MAX_TOKENS"])
batch_size = int(os.environ["EVAL_BATCH_SIZE"])
results_file = os.environ["EVAL_RESULTS_FILE"]

started = time.time()
tokenizer = AutoTokenizer.from_pretrained(model_dir, trust_remote_code=True)

if dataset_config:
    dataset = load_dataset("json", data_files={split: f"{dataset_id}/{split}.jsonl"}, split=split) if os.path.isdir(dataset_id) else load_dataset(dataset_id, dataset_config, split=split)
else:
    dataset = load_dataset("json", data_files={split: f"{dataset_id}/{split}.jsonl"}, split=split) if os.path.isdir(dataset_id) else load_dataset(dataset_id, split=split)

required = {"prompt", "completion"}
missing = required - set(dataset.column_names)
if missing:
    raise ValueError(f"evaluation dataset must contain {sorted(required)}; missing {sorted(missing)}")

limit = len(dataset) if num_problems < 0 else min(num_problems, len(dataset))
dataset = dataset.select(range(limit))

def format_prompt(prompt: str) -> str:
    if tokenizer.chat_template is None:
        return prompt
    return tokenizer.apply_chat_template(
        [{"role": "user", "content": prompt.strip()}],
        tokenize=False,
        add_generation_prompt=True,
    )

stop = [tokenizer.eos_token, "<|im_end|>", "\n\n<unfinished_theory>"]
stop = [item for item in stop if item]
sampling = SamplingParams(
    max_tokens=max_tokens,
    temperature=0.0,
    stop=stop,
)
prompts = [format_prompt(str(row["prompt"])) for row in dataset]
token_lengths = [len(tokenizer(prompt, add_special_tokens=False)["input_ids"]) for prompt in prompts]
max_model_len = int(os.environ["VLLM_MAX_MODEL_LEN"])
summarize_token_lengths(token_lengths, max_model_len, split)
kept_indices = [index for index, length in enumerate(token_lengths) if length <= max_model_len]
if not kept_indices:
    raise ValueError(f"{split} split has no examples within max_seq_length={max_model_len}")
if len(kept_indices) != len(prompts):
    print(
        f"{split} split dropping {len(prompts) - len(kept_indices)} examples over max_seq_length={max_model_len}",
        flush=True,
    )
dataset = dataset.select(kept_indices)
prompts = [prompts[index] for index in kept_indices]
print(f"{split} split kept {len(prompts)} examples for evaluation", flush=True)
llm = LLM(
    model=model_dir,
    trust_remote_code=True,
    dtype="auto",
    max_model_len=max_model_len,
    gpu_memory_utilization=0.70,
)
outputs = []
for start in range(0, len(prompts), batch_size):
    end = min(start + batch_size, len(prompts))
    print(f"Eval batch {start // batch_size + 1}/{math.ceil(len(prompts) / batch_size)}: examples {start}-{end - 1}", flush=True)
    outputs.extend(llm.generate(prompts[start:end], sampling))
    print(f"Eval batch {start // batch_size + 1} complete", flush=True)

rows = []
exact = 0
for index, (example, output) in enumerate(zip(dataset, outputs)):
    prediction = output.outputs[0].text.strip()
    gold = str(example["completion"]).strip()
    is_exact = prediction == gold
    exact += int(is_exact)
    row = {
        "index": index,
        "theory": example.get("theory", ""),
        "line": example.get("line"),
        "gold": gold,
        "prediction": prediction,
        "exact_match": is_exact,
    }
    rows.append(row)
    print(json.dumps(row, ensure_ascii=False), flush=True)

summary = {
    "eval/model_dir": model_dir,
    "eval/dataset": dataset_id,
    "eval/split": split,
    "eval/requested_num_examples": limit,
    "eval/num_examples": len(prompts),
    "eval/batch_size": batch_size,
    "eval/exact": exact,
    "eval/exact_match": exact / limit if limit else 0.0,
    "eval/runtime_seconds": time.time() - started,
}

os.makedirs(os.path.dirname(results_file), exist_ok=True)
with open(results_file, "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    handle.write(json.dumps({"summary": summary}, ensure_ascii=False) + "\n")

if os.environ.get("WANDB_MODE") != "disabled" and os.environ.get("WANDB_API_KEY"):
    run = wandb.init(
        project=os.environ.get("WANDB_PROJECT", "ai4math"),
        name=os.environ.get("WANDB_RUN_NAME"),
        id=os.environ.get("WANDB_RUN_ID"),
        resume="allow",
        job_type="eval",
    )
    wandb.log(summary)
    table = wandb.Table(columns=["index", "theory", "line", "gold", "prediction", "exact_match"])
    for row in rows:
        table.add_data(row["index"], row["theory"], row["line"], row["gold"], row["prediction"], row["exact_match"])
    try:
        wandb.log({"eval/results": table})
    except Exception as exc:
        print(f"Warning: failed to log W&B eval table: {exc}", flush=True)
    run.finish()

print("SUMMARY " + json.dumps(summary, ensure_ascii=False), flush=True)
print(f"Wrote {results_file}", flush=True)
if hasattr(llm, "llm_engine") and hasattr(llm.llm_engine, "shutdown"):
    llm.llm_engine.shutdown()
del llm
try:
    from vllm.distributed.parallel_state import destroy_model_parallel

    destroy_model_parallel()
except Exception as exc:
    print(f"Warning: vLLM model-parallel teardown skipped: {exc}", flush=True)
gc.collect()
PY
elif [[ "$SKIP_VLLM_SMOKE" != "1" ]]; then
  echo "Testing merged checkpoint with vLLM: $MERGED_MODEL_DIR"
  python - <<'PY'
import gc
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
if hasattr(llm, "llm_engine") and hasattr(llm.llm_engine, "shutdown"):
    llm.llm_engine.shutdown()
del llm
try:
    from vllm.distributed.parallel_state import destroy_model_parallel

    destroy_model_parallel()
except Exception as exc:
    print(f"Warning: vLLM model-parallel teardown skipped: {exc}", flush=True)
gc.collect()
PY
fi

echo "Completed: $(date -Is)"
