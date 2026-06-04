#!/usr/bin/env bash
set -euo pipefail

CREATE_HOST="${CREATE_HOST:-create}"
CREATE_IDENTITY="${CREATE_IDENTITY:-$HOME/.ssh/create_hpc_rsa}"
ARGS=()

usage() {
  cat <<'USAGE'
Usage:
  scancel_me.sh <job_id> [job_id ...]
  scancel_me.sh [scancel options]

Runs scancel on the CREATE login host using the same SSH defaults as squeue_me.sh.
Arguments are forwarded directly to scancel.

Examples:
  scancel_me.sh 123456
  scancel_me.sh --name my_job
  scancel_me.sh --user "$USER" --state=PENDING

Environment:
  CREATE_HOST          SSH host alias or login host. Default: create
  CREATE_IDENTITY      SSH private key. Default: ~/.ssh/create_hpc_rsa
USAGE
}

while (($#)); do
  case "$1" in
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

if ((${#ARGS[@]} == 0)); then
  echo "error: missing scancel arguments" >&2
  usage >&2
  exit 2
fi

SSH_OPTS=(
  -i "$CREATE_IDENTITY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=20
  -o ServerAliveInterval=60
)

ssh "${SSH_OPTS[@]}" "$CREATE_HOST" bash -s -- "${ARGS[@]}" <<'REMOTE'
set -euo pipefail

scancel "$@"
REMOTE
