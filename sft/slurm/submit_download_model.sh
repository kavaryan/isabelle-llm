#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_ID=""
SUBMIT_ARGS=()
SBATCH_ARGS=()
EXPORT_VARS=()
DEFAULT_MODEL_ID="Qwen/Qwen3-0.6B"

usage() {
  cat <<'USAGE'
Usage:
  submit_download_model.sh [options] [model_id] [-- sbatch options]

Examples:
  submit_download_model.sh
  submit_download_model.sh Qwen/Qwen3-4B-Instruct-2507
  submit_download_model.sh --model-root '~/ai4math/models' Qwen/Qwen3-0.6B
  submit_download_model.sh -- --partition=cpu --time=01:00:00

Options:
  --model-root DIR      Set MODEL_ROOT for per-model download directories.
  --model-dir DIR       Set MODEL_DIR for a single model download.
  --monitor             Submit through submit_and_monitor.sh.
  -h, --help            Show this help.

Any other options before the first model are passed to submit_slurm_job.sh.
Arguments after -- are passed directly to sbatch.
USAGE
}

submit_script="$SCRIPT_DIR/submit_slurm_job.sh"

while (($#)); do
  case "$1" in
    --model-root)
      if (($# < 2)); then
        echo "error: --model-root requires a value" >&2
        exit 2
      fi
      EXPORT_VARS+=("MODEL_ROOT=$2")
      shift 2
      ;;
    --model-dir)
      if (($# < 2)); then
        echo "error: --model-dir requires a value" >&2
        exit 2
      fi
      EXPORT_VARS+=("MODEL_DIR=$2")
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
      if [[ -n "$MODEL_ID" ]]; then
        echo "error: only one model_id may be specified" >&2
        exit 2
      fi
      MODEL_ID="$1"
      shift
      ;;
  esac
done

if [[ -z "$MODEL_ID" ]]; then
  MODEL_ID="$DEFAULT_MODEL_ID"
fi

EXPORT_VARS=("MODEL_ID=$MODEL_ID" "${EXPORT_VARS[@]}")
export_arg="ALL"
for export_var in "${EXPORT_VARS[@]}"; do
  export_arg+=",$export_var"
done
SBATCH_ARGS=("--export=$export_arg" "${SBATCH_ARGS[@]}")

exec "$submit_script" "${SUBMIT_ARGS[@]}" download_model.sbatch -- "${SBATCH_ARGS[@]}"
