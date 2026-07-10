#!/usr/bin/env bash
# Drives the goals distillation pipeline (discover -> oneshot -> check -> repair)
# end to end via `isabelle goals_run`. Each phase's output is the next phase's
# whitelist (-W). Completed outputs have checksum markers; partial outputs are
# rerun, and rerunning a phase invalidates every downstream phase.
#
# Usage: ./run_pipeline.sh [--smoketest] [goals_run options...] THEORIES...
#   e.g. ./run_pipeline.sh -m 3 HOL-Data_Structures.Sorted_Less
#
# All configuration is via env vars (ISABELLE, OUT_DIR, IR_DIR, ADAPTER_ONESHOT,
# ADAPTER_REPAIR, PROMPT_ONESHOT, PROMPT_REPAIR, MAX_SYMBOLS, CHECK_TIMEOUT_SECS,
# REPAIR_TIMEOUT_SECS, FORCE) -- see the defaults below for what each does.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SMOKETEST=0
if [[ "${1:-}" == "--smoketest" || "${1:-}" == "--smoke-test" ]]; then
  SMOKETEST=1
  shift
fi

resolve_isabelle() {
  if [[ -n "${ISABELLE:-}" ]]; then echo "$ISABELLE"; return; fi
  if [[ -n "${ISABELLE_HOME:-}" && -x "$ISABELLE_HOME/bin/isabelle" ]]; then
    echo "$ISABELLE_HOME/bin/isabelle"; return
  fi
  local candidate="$script_dir/../../pide_mcp/isabelle/bin/isabelle"
  if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
  echo "isabelle"
}

ISABELLE="$(resolve_isabelle)"
if [[ "$SMOKETEST" -eq 1 ]]; then
  OUT_DIR="${OUT_DIR:-$script_dir/pipeline_smoke_out}"
  ADAPTER_ONESHOT="${ADAPTER_ONESHOT:-$script_dir/adapters/opencode_adapter.sh}"
  ADAPTER_REPAIR="${ADAPTER_REPAIR:-$script_dir/adapters/opencode_repair_adapter.sh}"
  ONESHOT_MODEL="${ONESHOT_MODEL:-opencode/deepseek-v4-pro}"
  REPAIR_MODEL="${REPAIR_MODEL:-opencode/deepseek-v4-pro}"
  OPENCODE_API_KEY_FILE="${OPENCODE_API_KEY_FILE:-$HOME/.opencode-api-key}"
  if [[ ! -s "$OPENCODE_API_KEY_FILE" ]]; then
    echo "error: OpenCode API key file not found or empty: $OPENCODE_API_KEY_FILE" >&2
    exit 2
  fi
  OPENCODE_API_KEY="$(python3 - "$OPENCODE_API_KEY_FILE" <<'PY'
from pathlib import Path
import sys

line = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
if "=" in line:
    name, value = line.split("=", 1)
    if name.removeprefix("export ").strip() != "OPENCODE_API_KEY":
        raise SystemExit("API key file must define OPENCODE_API_KEY")
else:
    value = line
value = value.strip()
if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
    value = value[1:-1]
if not value:
    raise SystemExit("OPENCODE_API_KEY is empty")
print(value)
PY
)"
else
  OUT_DIR="${OUT_DIR:-$script_dir/pipeline_out}"
  ADAPTER_ONESHOT="${ADAPTER_ONESHOT:-$script_dir/adapters/opencode_adapter.sh}"
  ADAPTER_REPAIR="${ADAPTER_REPAIR:-$script_dir/adapters/opencode_repair_adapter.sh}"
fi
PROMPT_ONESHOT="${PROMPT_ONESHOT:-$script_dir/prompts/oneshot_prompt.txt}"
PROMPT_REPAIR="${PROMPT_REPAIR:-$script_dir/prompts/repair_prompt.txt}"
MAX_SYMBOLS="${MAX_SYMBOLS:-4000}"
CHECK_TIMEOUT_SECS="${CHECK_TIMEOUT_SECS:-10}"
REPAIR_TIMEOUT_SECS="${REPAIR_TIMEOUT_SECS:-300}"
FORCE="${FORCE:-0}"
PIPELINE_SMOKETEST="$SMOKETEST"
export ISABELLE OUT_DIR ADAPTER_ONESHOT ADAPTER_REPAIR PROMPT_ONESHOT PROMPT_REPAIR
export MAX_SYMBOLS CHECK_TIMEOUT_SECS REPAIR_TIMEOUT_SECS PIPELINE_SMOKETEST
export ONESHOT_MODEL REPAIR_MODEL OPENCODE_API_KEY OPENCODE_API_KEY_FILE

if [[ "$SMOKETEST" -eq 1 ]]; then
  if [[ "$#" -eq 0 ]]; then
    set -- -m 10 HOL-Library.Multiset
  fi
fi

mkdir -p "$OUT_DIR"

log_step() {
  printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*" >&2
}

pipeline_dirty="$FORCE"

# Reuse only a checksum-verified completed phase. Once a phase reruns, rerun
# every downstream phase so no artifact can refer to stale upstream data.
run_phase() {
  local name="$1" out="$2"
  shift 2
  if [[ "$pipeline_dirty" -ne 1 ]] && python3 "$script_dir/pipeline_artifacts.py" phase-valid "$out"; then
    log_step "phase $name: using existing $out"
    return
  fi
  log_step "phase $name: running"
  pipeline_dirty=1
  rm -f "$out.complete.json"
  "$ISABELLE" goals_run -P "$name" -O "$out" "$@"
  python3 "$script_dir/pipeline_artifacts.py" mark-complete "$name" "$out"
}

discover_out="$OUT_DIR/01_discover.json"
oneshot_out="$OUT_DIR/02_oneshot.json"
check_out="$OUT_DIR/03_check.json"
repair_out="$OUT_DIR/04_repair.json"

run_phase discover "$discover_out" "$@"

run_phase oneshot "$oneshot_out" -W "$discover_out" \
  -A "$discover_out" -A "$ADAPTER_ONESHOT" -A "$PROMPT_ONESHOT" -A "$MAX_SYMBOLS" "$@"

run_phase check "$check_out" -W "$oneshot_out" \
  -A "$oneshot_out" -A "$CHECK_TIMEOUT_SECS" "$@"

if [[ -z "${IR_DIR:-}" ]]; then
  log_step "phase repair: skipped (IR_DIR not set)"
  rm -f "$repair_out" "$repair_out.complete.json"
else
  run_phase repair "$repair_out" -W "$check_out" \
    -A "$check_out" -A "$IR_DIR" -A "$ADAPTER_REPAIR" -A "$PROMPT_REPAIR" \
    -A "$MAX_SYMBOLS" -A "$REPAIR_TIMEOUT_SECS" "$@"
fi

python3 "$script_dir/pipeline_artifacts.py" finalize "$OUT_DIR" "$started_at" "$script_dir" -- "$@"
log_step "done -> $OUT_DIR"
