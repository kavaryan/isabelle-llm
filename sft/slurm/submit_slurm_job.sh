#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CREATE_HOST="${CREATE_HOST:-create}"
CREATE_IDENTITY="${CREATE_IDENTITY:-$HOME/.ssh/create_hpc_rsa}"
REMOTE_DIR="${CREATE_REMOTE_DIR:-}"
SOURCE_DIR="$SCRIPT_DIR"
SBATCH_FILE=""
UPLOAD=1
DRY_RUN=0
SBATCH_ARGS=()

usage() {
  cat <<'USAGE'
Usage:
  submit_slurm_job.sh [options] <job.sbatch> [-- sbatch options]

Examples:
  submit_slurm_job.sh cpu_test.sbatch
  submit_slurm_job.sh --remote-dir '~/jobs/cpu_test' cpu_test.sbatch
  submit_slurm_job.sh --source-dir /path/to/project scripts/job.sbatch -- --partition=cpu
  submit_slurm_job.sh --no-upload --remote-dir '~/jobs/already_remote' job.sbatch

Options:
  --source-dir DIR       Directory to upload. Default: this script's directory.
  --remote-dir DIR       Remote working directory. Default: ~/<source-dir-name>.
  --host HOST            SSH host alias or login host. Default: create.
  --identity KEY         SSH private key. Default: ~/.ssh/create_hpc_rsa.
  --no-upload            Do not rsync files before submitting.
  --dry-run              Print the remote sbatch command without uploading/submitting.
  -h, --help             Show this help.

Environment:
  CREATE_HOST            Same as --host.
  CREATE_IDENTITY        Same as --identity.
  CREATE_REMOTE_DIR      Same as --remote-dir.
USAGE
}

while (($#)); do
  case "$1" in
    --source-dir)
      if (($# < 2)); then
        echo "error: --source-dir requires a value" >&2
        exit 2
      fi
      SOURCE_DIR="$2"
      shift 2
      ;;
    --remote-dir)
      if (($# < 2)); then
        echo "error: --remote-dir requires a value" >&2
        exit 2
      fi
      REMOTE_DIR="$2"
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
    --no-upload)
      UPLOAD=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$SBATCH_FILE" ]]; then
        echo "error: only one batch file may be specified" >&2
        exit 2
      fi
      SBATCH_FILE="$1"
      shift
      ;;
  esac
done

if [[ -z "$SBATCH_FILE" ]]; then
  if [[ -f "$SCRIPT_DIR/cpu_test.sbatch" ]]; then
    SBATCH_FILE="cpu_test.sbatch"
  else
    echo "error: missing batch file" >&2
    usage >&2
    exit 2
  fi
fi

if [[ -z "$REMOTE_DIR" ]]; then
  REMOTE_DIR="~/$(basename "$SOURCE_DIR")"
fi

if [[ "$UPLOAD" -eq 1 ]]; then
  if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "error: source directory does not exist: $SOURCE_DIR" >&2
    exit 2
  fi

  if [[ "$SBATCH_FILE" = /* ]]; then
    case "$SBATCH_FILE" in
      "$SOURCE_DIR"/*)
        SBATCH_FILE="${SBATCH_FILE#"$SOURCE_DIR"/}"
        ;;
      *)
        echo "error: absolute batch file must be inside --source-dir when uploading" >&2
        exit 2
        ;;
    esac
  fi

  if [[ ! -f "$SOURCE_DIR/$SBATCH_FILE" ]]; then
    echo "error: batch file not found under source directory: $SOURCE_DIR/$SBATCH_FILE" >&2
    exit 2
  fi
fi

SSH_OPTS=(
  -i "$CREATE_IDENTITY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=20
  -o ServerAliveInterval=60
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'Would run on %s: cd %q && sbatch' "$CREATE_HOST" "$REMOTE_DIR"
  printf ' %q' "${SBATCH_ARGS[@]}" "$SBATCH_FILE"
  printf '\n'
  exit 0
fi

if [[ "$UPLOAD" -eq 1 ]]; then
  echo "Uploading $SOURCE_DIR to $CREATE_HOST:$REMOTE_DIR"
  remote_dir="$(ssh "${SSH_OPTS[@]}" "$CREATE_HOST" bash -s -- "$REMOTE_DIR" <<'REMOTE'
set -euo pipefail

remote_dir="$1"
case "$remote_dir" in
  "~")
    remote_dir="$HOME"
    ;;
  "~/"*)
    remote_dir="$HOME/${remote_dir#~/}"
    ;;
esac

mkdir -p "$remote_dir"
printf '%s' "$remote_dir"
REMOTE
)"
  rsync -avz -e "ssh -i $CREATE_IDENTITY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=60" \
    "$SOURCE_DIR/" "$CREATE_HOST:$remote_dir/"
fi

echo "Submitting $SBATCH_FILE on $CREATE_HOST"
ssh "${SSH_OPTS[@]}" "$CREATE_HOST" bash -s -- "$REMOTE_DIR" "$SBATCH_FILE" "${SBATCH_ARGS[@]}" <<'REMOTE'
set -euo pipefail

remote_dir="$1"
sbatch_file="$2"
shift 2

case "$remote_dir" in
  "~")
    remote_dir="$HOME"
    ;;
  "~/"*)
    remote_dir="$HOME/${remote_dir#~/}"
    ;;
esac

cd "$remote_dir"
sbatch "$@" "$sbatch_file"
REMOTE
