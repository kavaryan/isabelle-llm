#!/usr/bin/env bash
# Drives the goals distillation pipeline (discover -> oneshot -> check -> repair)
# end to end via `isabelle goals_run`. Each phase's output is the next phase's
# whitelist (-W); an existing output file is reused unless FORCE=1.
#
# Usage: ./run_pipeline.sh [goals_run options...] THEORIES...
#   e.g. ./run_pipeline.sh -m 3 HOL-Data_Structures.Sorted_Less
#
# All configuration is via env vars (ISABELLE, OUT_DIR, IR_DIR, ADAPTER_ONESHOT,
# ADAPTER_REPAIR, PROMPT_ONESHOT, PROMPT_REPAIR, MAX_SYMBOLS, CHECK_TIMEOUT_SECS,
# REPAIR_TIMEOUT_SECS, FORCE) -- see the defaults below for what each does.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

resolve_isabelle() {
  if [[ -n "${ISABELLE:-}" ]]; then echo "$ISABELLE"; return; fi
  local candidate="$script_dir/../../pide_mcp/isabelle/bin/isabelle"
  if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
  echo "isabelle"
}

ISABELLE="$(resolve_isabelle)"
OUT_DIR="${OUT_DIR:-$script_dir/pipeline_out}"
ADAPTER_ONESHOT="${ADAPTER_ONESHOT:-$script_dir/adapters/opencode_adapter.sh}"
ADAPTER_REPAIR="${ADAPTER_REPAIR:-$script_dir/adapters/opencode_repair_adapter.sh}"
PROMPT_ONESHOT="${PROMPT_ONESHOT:-$script_dir/prompts/oneshot_prompt.txt}"
PROMPT_REPAIR="${PROMPT_REPAIR:-$script_dir/prompts/repair_prompt.txt}"
MAX_SYMBOLS="${MAX_SYMBOLS:-4000}"
CHECK_TIMEOUT_SECS="${CHECK_TIMEOUT_SECS:-10}"
REPAIR_TIMEOUT_SECS="${REPAIR_TIMEOUT_SECS:-300}"
FORCE="${FORCE:-0}"

mkdir -p "$OUT_DIR"

log_step() {
  printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*" >&2
}

# runs `$ISABELLE goals_run -P "$1" -O "$2" "${@:3}"`, skipping if "$2" already
# exists and FORCE=0
run_phase() {
  local name="$1" out="$2"
  shift 2
  if [[ "$FORCE" -ne 1 && -s "$out" ]]; then
    log_step "phase $name: using existing $out"
    return
  fi
  log_step "phase $name: running"
  "$ISABELLE" goals_run -P "$name" -O "$out" "$@"
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
else
  run_phase repair "$repair_out" -W "$check_out" \
    -A "$check_out" -A "$IR_DIR" -A "$ADAPTER_REPAIR" -A "$PROMPT_REPAIR" \
    -A "$MAX_SYMBOLS" -A "$REPAIR_TIMEOUT_SECS" "$@"
fi

log_step "done -> $OUT_DIR"
