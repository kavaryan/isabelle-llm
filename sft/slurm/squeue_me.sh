#!/usr/bin/env bash
set -euo pipefail

CREATE_HOST="${CREATE_HOST:-create}"
CREATE_IDENTITY="${CREATE_IDENTITY:-$HOME/.ssh/create_hpc_rsa}"
MODE="queue"
SINCE="${SQUEUE_ME_SINCE:-now-7days}"
ALL=0
ARGS=()

usage() {
  cat <<'USAGE'
Usage:
  squeue_me.sh [squeue options]
  squeue_me.sh --all [squeue options]
  squeue_me.sh --history [sacct options]
  squeue_me.sh --history --since YYYY-MM-DD [sacct options]
  squeue_me.sh --history --all [sacct options]

Defaults:
  Queue mode runs squeue for only your CREATE user.
  History mode runs sacct for only your CREATE user since now-7days.
  History columns include Submit, Eligible, Start, End, and Elapsed.
  Use --all to omit the user filter.

Environment:
  CREATE_HOST          SSH host alias or login host. Default: create
  CREATE_IDENTITY      SSH private key. Default: ~/.ssh/create_hpc_rsa
  SQUEUE_ME_SINCE      Default history start time. Default: now-7days
USAGE
}

while (($#)); do
  case "$1" in
    --history|history)
      MODE="history"
      shift
      ;;
    --all)
      ALL=1
      shift
      ;;
    --since)
      if (($# < 2)); then
        echo "error: --since requires a value" >&2
        exit 2
      fi
      SINCE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      ARGS+=("$@")
      break
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

SSH_OPTS=(
  -i "$CREATE_IDENTITY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=20
  -o ServerAliveInterval=60
)

remote_user="$(ssh "${SSH_OPTS[@]}" "$CREATE_HOST" 'printf "%s" "$USER"')"

ssh "${SSH_OPTS[@]}" "$CREATE_HOST" bash -s -- "$remote_user" "$MODE" "$SINCE" "$ALL" "${ARGS[@]}" <<'REMOTE'
set -euo pipefail

remote_user="$1"
mode="$2"
since="$3"
all="$4"
shift 4

case "$mode" in
  queue)
    if [[ "$all" -eq 1 ]]; then
      squeue \
        --format="%.18i %.9P %.32j %.8u %.2t %.10M %.6D %R" \
        "$@"
    else
      squeue --user="$remote_user" \
        --format="%.18i %.9P %.32j %.8u %.2t %.10M %.6D %R" \
        "$@"
    fi
    ;;
  history)
    if [[ "$all" -eq 1 ]]; then
      sacct -X \
        --starttime="$since" \
        --format="JobID,JobName%22,Partition,State,Submit%22,Eligible%22,Start%22,End%22,Elapsed,AllocCPUS,ReqMem%12,ExitCode" \
        "$@"
    else
      sacct -X --user="$remote_user" \
        --starttime="$since" \
        --format="JobID,JobName%22,Partition,State,Submit%22,Eligible%22,Start%22,End%22,Elapsed,AllocCPUS,ReqMem%12,ExitCode" \
        "$@"
    fi
    ;;
  *)
    echo "error: unknown mode: $mode" >&2
    exit 2
    ;;
esac
REMOTE
