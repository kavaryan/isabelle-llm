#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH_SECONDS="${SLURM_MONITOR_REFRESH:-10}"
SUBMIT_ARGS=()

usage() {
  cat <<'USAGE'
Usage:
  submit_and_monitor.sh [--refresh SECONDS] [submit_slurm_job.sh options] <job.sbatch> [-- sbatch options]

Submits through submit_slurm_job.sh, extracts the Slurm job id, then monitors
that job through monitor_slurm_job.sh. Monitoring exits on Ctrl-C or when the
job finishes, fails, or otherwise leaves the live queue in a terminal state.

Examples:
  submit_and_monitor.sh download_qwen3_0_6b.sbatch
  submit_and_monitor.sh --refresh 5 download_qwen3_0_6b.sbatch
  submit_and_monitor.sh --remote-dir '~/qwen_download' download_qwen3_0_6b.sbatch -- --partition=cpu
USAGE
}

while (($#)); do
  case "$1" in
    --refresh|-r)
      if (($# < 2)); then
        echo "error: --refresh requires a value" >&2
        exit 2
      fi
      REFRESH_SECONDS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      SUBMIT_ARGS+=("$1")
      shift
      ;;
  esac
done

if ! [[ "$REFRESH_SECONDS" =~ ^[0-9]+$ ]] || [[ "$REFRESH_SECONDS" -lt 1 ]]; then
  echo "error: refresh interval must be a positive integer" >&2
  exit 2
fi

submit_output="$("$SCRIPT_DIR/submit_slurm_job.sh" "${SUBMIT_ARGS[@]}")"
printf '%s\n' "$submit_output"

job_id="$(printf '%s\n' "$submit_output" | awk '/Submitted batch job/ {job=$NF} END {print job}')"
if [[ -z "$job_id" ]]; then
  echo "error: could not find Slurm job id in submit output" >&2
  exit 1
fi

exec "$SCRIPT_DIR/monitor_slurm_job.sh" --refresh "$REFRESH_SECONDS" "$job_id"
