#!/usr/bin/env bash
set -euo pipefail

ISABELLE_VERSION="Isabelle2025-2"
ISABELLE_ARCHIVE="Isabelle2025-2_linux.tar.gz"
ISABELLE_URL="https://isabelle.in.tum.de/dist/Isabelle2025-2_linux.tar.gz"
ISABELLE_SHA256="a20a507bc7c1270d8be96a9f3fbec06345387789d2dc2c4d3df6260d47bfb33c"

AFP_ARCHIVE="afp-2025-2-Isabelle2025-2.tar.gz"
AFP_URL="https://foss.heptapod.net/isa-afp/afp-2025-2/-/archive/Isabelle2025-2/afp-2025-2-Isabelle2025-2.tar.gz"

SCRATCH_ROOT="${SCRATCH_ROOT:-/scratch/users/$USER}"
INSTALL_ROOT="${INSTALL_ROOT:-$SCRATCH_ROOT/ai4math}"
ISABELLE_ROOT="$INSTALL_ROOT/isabelle"
AFP_ROOT="$INSTALL_ROOT/afp"
ISABELLE_HOME="$ISABELLE_ROOT/$ISABELLE_VERSION"
ISABELLE_BIN="$ISABELLE_HOME/bin/isabelle"
ISABELLE_HOME_USER_DIR="$INSTALL_ROOT/isabelle-home-user/$ISABELLE_VERSION"
AFP_DIR="$AFP_ROOT/afp-2025-2"
REPO_ROOT="${REPO_ROOT:-$HOME/isabelle-llm}"
RUN_REWARD_SMOKE=0

usage() {
  cat <<'USAGE'
Usage:
  install_isabelle_hpc.sh [options]

Options:
  --install-root DIR     Install under DIR. Default: /scratch/users/$USER/ai4math.
  --repo-root DIR        Repo path used for reward smoke validation. Default: $HOME/isabelle-llm.
  --reward-smoke         Also run the reward checker smoke test.
  -h, --help             Show this help.

This installs Isabelle2025-2 and AFP 2025-2 under scratch, verifies the Isabelle
archive SHA256, and configures Isabelle heap/user state under scratch instead of
$HOME/.isabelle.
USAGE
}

while (($#)); do
  case "$1" in
    --install-root)
      if (($# < 2)); then
        echo "error: --install-root requires a value" >&2
        exit 2
      fi
      INSTALL_ROOT="$2"
      ISABELLE_ROOT="$INSTALL_ROOT/isabelle"
      AFP_ROOT="$INSTALL_ROOT/afp"
      ISABELLE_HOME="$ISABELLE_ROOT/$ISABELLE_VERSION"
      ISABELLE_BIN="$ISABELLE_HOME/bin/isabelle"
      ISABELLE_HOME_USER_DIR="$INSTALL_ROOT/isabelle-home-user/$ISABELLE_VERSION"
      AFP_DIR="$AFP_ROOT/afp-2025-2"
      shift 2
      ;;
    --repo-root)
      if (($# < 2)); then
        echo "error: --repo-root requires a value" >&2
        exit 2
      fi
      REPO_ROOT="$2"
      shift 2
      ;;
    --reward-smoke)
      RUN_REWARD_SMOKE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

download() {
  local url="$1"
  local output="$2"
  if [[ -f "$output" ]]; then
    return
  fi
  mkdir -p "$(dirname "$output")"
  wget -O "$output" "$url"
}

verify_sha256() {
  local expected="$1"
  local file="$2"
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: SHA256 mismatch for $file" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

configure_scratch_state() {
  local settings="$ISABELLE_HOME/etc/settings"
  local marker="# ai4math scratch user state"
  if [[ ! -f "$settings" ]]; then
    echo "error: Isabelle settings file not found: $settings" >&2
    exit 1
  fi
  if ! grep -Fq "$marker" "$settings"; then
    python3 - "$settings" "$ISABELLE_HOME_USER_DIR" "$marker" <<'PY'
import sys
from pathlib import Path

settings = Path(sys.argv[1])
scratch_home = sys.argv[2]
marker = sys.argv[3]
text = settings.read_text()
needle = 'fi\n\n# Where to look for isabelle tools'
insert = (
    'fi\n'
    f'{marker}\n'
    f'ISABELLE_HOME_USER="{scratch_home}"\n'
    'isabelle_directory "$ISABELLE_HOME_USER"\n\n'
    '# Where to look for isabelle tools'
)
if needle not in text:
    raise SystemExit(f'expected ISABELLE_HOME_USER block not found in {settings}')
settings.write_text(text.replace(needle, insert, 1))
PY
  fi
  mkdir -p "$ISABELLE_HOME_USER_DIR"
}

install_isabelle() {
  local archive="$ISABELLE_ROOT/$ISABELLE_ARCHIVE"
  mkdir -p "$ISABELLE_ROOT"
  download "$ISABELLE_URL" "$archive"
  verify_sha256 "$ISABELLE_SHA256" "$archive"
  if [[ ! -x "$ISABELLE_BIN" ]]; then
    tar -xzf "$archive" -C "$ISABELLE_ROOT"
  fi
  if [[ ! -x "$ISABELLE_BIN" ]]; then
    echo "error: Isabelle executable not found after extraction: $ISABELLE_BIN" >&2
    exit 1
  fi
  configure_scratch_state
}

install_afp() {
  local archive="$AFP_ROOT/$AFP_ARCHIVE"
  mkdir -p "$AFP_ROOT"
  download "$AFP_URL" "$archive"
  if [[ ! -d "$AFP_DIR/thys" ]]; then
    tar -xzf "$archive" -C "$AFP_ROOT"
  fi
  if [[ ! -d "$AFP_DIR/thys" ]]; then
    echo "error: AFP theories directory not found after extraction: $AFP_DIR/thys" >&2
    exit 1
  fi
}

validate_install() {
  "$ISABELLE_BIN" version
  "$ISABELLE_BIN" getenv -b ISABELLE_IDENTIFIER ISABELLE_HOME_USER ISABELLE_HEAPS
  test -d "$AFP_DIR/thys"
}

run_reward_smoke() {
  local checker="$REPO_ROOT/rl/slurm/check_isabelle_reward.py"
  local extractor_json_dir="$REPO_ROOT/extractor/proof_extractor_out/json"
  local theory_session_map="$REPO_ROOT/rl/slurm/theory_sessions.json"
  if [[ ! -f "$checker" ]]; then
    echo "error: reward checker not found: $checker" >&2
    exit 1
  fi
  if [[ ! -d "$extractor_json_dir" ]]; then
    echo "error: extractor JSON directory not found: $extractor_json_dir" >&2
    exit 1
  fi
  if [[ ! -f "$theory_session_map" ]]; then
    echo "error: theory session map not found: $theory_session_map" >&2
    exit 1
  fi
  (
    cd "$REPO_ROOT"
    python3 - <<'PY' | env \
      ISABELLE="$ISABELLE_BIN" \
      ISABELLE_EXTRACTOR_JSON_DIR="$extractor_json_dir" \
      ISABELLE_REWARD_EXTRA_DIRS="$AFP_DIR/thys" \
      ISABELLE_THEORY_SESSION_MAP="$theory_session_map" \
      python3 "$checker"
import json
from pathlib import Path

records = json.loads(Path("extractor/proof_extractor_out/json/AList_Upd_Del.json").read_text())
record = records[0]
print(json.dumps({
    "completion": record["proof_block"],
    "source_file": "AList_Upd_Del.json",
    "source_index": 0,
}))
PY
  )
}

install_isabelle
install_afp
validate_install
if [[ "$RUN_REWARD_SMOKE" == "1" ]]; then
  run_reward_smoke
fi

cat <<EOF
Isabelle install complete.
ISABELLE=$ISABELLE_BIN
ISABELLE_HOME_USER=$ISABELLE_HOME_USER_DIR
ISABELLE_REWARD_EXTRA_DIRS=$AFP_DIR/thys
EOF
