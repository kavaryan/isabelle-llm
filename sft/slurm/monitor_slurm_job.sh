#!/usr/bin/env bash
set -euo pipefail

CREATE_HOST="${CREATE_HOST:-create-mx}"
CREATE_IDENTITY="${CREATE_IDENTITY:-$HOME/.ssh/create_hpc_rsa}"
REFRESH_SECONDS="${SLURM_MONITOR_REFRESH:-10}"
JOB_ID=""

usage() {
  cat <<'USAGE'
Usage:
  monitor_slurm_job.sh [--refresh SECONDS] <job_id>

Shows a live Slurm view for one job using a single persistent SSH session.
The monitor exits on Ctrl-C or once the job reaches a terminal state.

Environment:
  CREATE_HOST              SSH host alias or login host. Default: create
  CREATE_IDENTITY          SSH private key. Default: ~/.ssh/create_hpc_rsa
  SLURM_MONITOR_REFRESH    Default refresh interval. Default: 10
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
    --host)
      if (($# < 2)); then
        echo "error: --host requires a value" >&2
        exit 2
      fi
      CREATE_HOST="$2"
      shift 2
      ;;
    --identity)
      if (($# < 2)); then
        echo "error: --identity requires a value" >&2
        exit 2
      fi
      CREATE_IDENTITY="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$JOB_ID" ]]; then
        echo "error: only one job id may be specified" >&2
        exit 2
      fi
      JOB_ID="$1"
      shift
      ;;
  esac
done

if [[ -z "$JOB_ID" ]]; then
  echo "error: missing job id" >&2
  usage >&2
  exit 2
fi

if ! [[ "$REFRESH_SECONDS" =~ ^[0-9]+$ ]] || [[ "$REFRESH_SECONDS" -lt 1 ]]; then
  echo "error: refresh interval must be a positive integer" >&2
  exit 2
fi

SSH_OPTS=(
  -i "$CREATE_IDENTITY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=20
  -o ServerAliveInterval=60
)

ssh "${SSH_OPTS[@]}" "$CREATE_HOST" bash -s -- "$JOB_ID" "$REFRESH_SECONDS" <<'REMOTE'
set -euo pipefail

job_id="$1"
refresh="$2"
terminal_states='^(COMPLETED|FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|PREEMPTED|BOOT_FAIL|DEADLINE|REVOKED|SPECIAL_EXIT)$'

while true; do
  state="$(sacct -j "$job_id" --noheader --parsable2 --format=State 2>/dev/null | awk -F'|' 'NF {print $1; exit}')"
  if [[ -z "$state" ]]; then
    state="$(squeue -j "$job_id" --noheader --format='%T' 2>/dev/null | head -n 1 || true)"
  fi
  state="${state:-UNKNOWN}"
  state="${state%% *}"

  if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] && command -v clear >/dev/null 2>&1; then
    clear || true
  else
    printf '\n\n'
  fi

  echo "Slurm job monitor"
  echo "Now: $(date -Is)"
  echo "User: $USER"
  echo "Job ID: $job_id"
  echo "State: $state"
  echo

  echo "Job accounting"
  sacct -j "$job_id" \
    --format=JobID,JobName%32,Partition,State,Submit,Start,End,Elapsed,AllocCPUS,ReqMem%12,ExitCode \
    2>/dev/null || true
  echo

  echo "Queue entry"
  squeue -j "$job_id" \
    --format="%.18i %.9P %.32j %.8u %.2t %.12M %.12l %.6D %V %R" \
    2>/dev/null || true
  echo

  echo "My queued/running jobs"
  squeue --user="$USER" \
    --format="%.18i %.9P %.32j %.2t %.10M %.6D %R" \
    2>/dev/null || true
  echo

  total_jobs="$(squeue --noheader 2>/dev/null | wc -l | awk '{print $1}')"
  my_jobs="$(squeue --user="$USER" --noheader 2>/dev/null | wc -l | awk '{print $1}')"
  my_running="$(squeue --user="$USER" --states=R --noheader 2>/dev/null | wc -l | awk '{print $1}')"
  my_pending="$(squeue --user="$USER" --states=PD --noheader 2>/dev/null | wc -l | awk '{print $1}')"

  echo "Queue stats"
  echo "  total live jobs: $total_jobs"
  echo "  my live jobs:    $my_jobs"
  echo "  my running jobs: $my_running"
  echo "  my pending jobs: $my_pending"

  if [[ "$state" =~ $terminal_states ]]; then
    final_elapsed="$(sacct -j "$job_id" --noheader --parsable2 --format=Elapsed 2>/dev/null | awk -F'|' 'NF {print $1; exit}')"
    final_elapsed="${final_elapsed:-unknown}"
    echo
    echo "Job reached terminal state: $state"
    echo "Total time: $final_elapsed"
    exit 0
  fi

  sleep "$refresh"
done
REMOTE
