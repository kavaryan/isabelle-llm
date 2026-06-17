#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR=""
HF_REPO_ID=""
SUBMIT_ARGS=()
SBATCH_ARGS=()
EXPORT_VARS=()
submit_script="$SCRIPT_DIR/submit_slurm_job.sh"

usage() {
  cat <<'USAGE'
Usage:
  submit_upload_model.sh [options] MODEL_DIR HF_REPO_ID [-- sbatch options]

Example:
  submit_upload_model.sh \
    '~/ai4math/finetunes/my-run/merged' \
    kavaryan/my-model

Options:
  --private             Create a private Hugging Face repository.
  --monitor             Wait for the Slurm job and print its logs.
  --rebuild-env         Rebuild the Hugging Face upload virtual environment.
  -h, --help            Show this help.

Any submit_slurm_job.sh connection options are accepted before MODEL_DIR.
Arguments after -- are passed directly to sbatch.
Authentication uses HF_TOKEN when exported, then ~/.hf_token on CREATE, then
the cached Hugging Face login on CREATE.
USAGE
}

while (($#)); do
  case "$1" in
    --private)
      EXPORT_VARS+=("HF_REPO_PRIVATE=1")
      shift
      ;;
    --monitor)
      submit_script="$SCRIPT_DIR/submit_and_monitor.sh"
      shift
      ;;
    --rebuild-env)
      EXPORT_VARS+=("REBUILD_ENV=1")
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
      if [[ -z "$MODEL_DIR" ]]; then
        MODEL_DIR="$1"
      elif [[ -z "$HF_REPO_ID" ]]; then
        HF_REPO_ID="$1"
      else
        echo "error: unexpected argument: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$MODEL_DIR" || -z "$HF_REPO_ID" ]]; then
  echo "error: MODEL_DIR and HF_REPO_ID are required" >&2
  usage >&2
  exit 2
fi

if [[ "$HF_REPO_ID" != */* ]]; then
  echo "error: HF_REPO_ID must be in namespace/repository format" >&2
  exit 2
fi

EXPORT_VARS=("MODEL_DIR=$MODEL_DIR" "HF_REPO_ID=$HF_REPO_ID" "${EXPORT_VARS[@]}")
export_arg="ALL"
for export_var in "${EXPORT_VARS[@]}"; do
  export_arg+=",$export_var"
done
SBATCH_ARGS=("--export=$export_arg" "${SBATCH_ARGS[@]}")

exec "$submit_script" "${SUBMIT_ARGS[@]}" upload_model.sbatch -- "${SBATCH_ARGS[@]}"
