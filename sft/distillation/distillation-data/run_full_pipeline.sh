#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

SMOKETEST=0
if [[ "${1:-}" == "--smoketest" || "${1:-}" == "--smoke-test" ]]; then
  SMOKETEST=1
  shift
fi
if [[ "$#" -gt 0 ]]; then
  echo "usage: $0 [--smoketest]" >&2
  exit 2
fi

log_step() {
  printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

if [[ "$SMOKETEST" -eq 1 ]]; then
  ROWS=smoke_01_multiline.jsonl
  ONESHOT=smoke_02_oneshot.jsonl
  ONESHOT_CHECKED=smoke_03_checked.jsonl
  REPAIRS=smoke_04_repair.jsonl
  REPAIRS_CHECKED=smoke_05_repair_checked.jsonl
  STATS=smoke_06_stats.json
  PREPARE_LIMIT=(--known-hard-smoke-row --limit 1)
else
  ROWS=01_multiline_distillation.jsonl
  ONESHOT=02_oneshot_rollouts.jsonl
  ONESHOT_CHECKED=03_oneshot_checked.jsonl
  REPAIRS=04_mini_ir_repair_rollouts.jsonl
  REPAIRS_CHECKED=05_mini_ir_checked.jsonl
  STATS=06_distillation_stats.json
  PREPARE_LIMIT=()
fi

if [[ "$SMOKETEST" -eq 1 ]]; then
  log_step "smoketest: removing previous smoke outputs"
  rm -f "$ROWS" "$ONESHOT" "$ONESHOT_CHECKED" "$REPAIRS" "$REPAIRS_CHECKED" "$STATS" \
    "${ROWS%.jsonl}.dataset_info.json"
fi

if [[ ! -s "$ROWS" ]]; then
  log_step "stage 1: prepare multiline rows"
  python3 prepare_multiline_distillation_data.py \
    --output "$ROWS" \
    "${PREPARE_LIMIT[@]}"
else
  log_step "stage 1: using existing $ROWS"
fi

log_step "stage 2: one-shot OpenCode rollouts"
python3 run_oneshot_codex.py \
  --input "$ROWS" \
  --output "$ONESHOT"

log_step "stage 3: check one-shot proofs"
python3 check_with_iq_mcp.py \
  --input "$ONESHOT" \
  --output "$ONESHOT_CHECKED" \
  --proof-field oneshot_extracted_proof \
  --prefix oneshot

log_step "stage 4: mini_ir repairs"
python3 run_mini_ir_repairs.py \
  --input "$ONESHOT_CHECKED" \
  --output "$REPAIRS"

log_step "stage 5: check mini_ir repairs"
python3 check_with_iq_mcp.py \
  --input "$REPAIRS" \
  --output "$REPAIRS_CHECKED" \
  --proof-field mini_ir_extracted_proof \
  --prefix mini_ir

log_step "stage 6: stats"
python3 make_distillation_stats.py \
  --oneshot-checked "$ONESHOT_CHECKED" \
  --repair-checked "$REPAIRS_CHECKED" \
  --output "$STATS"

log_step "done"
