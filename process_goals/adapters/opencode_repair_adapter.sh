#!/usr/bin/env bash
# Repair adapter: reads a prompt on stdin, drives an opencode agent that has
# access only to the mini_ir MCP tool -- pre-pointed (via env vars) at a
# specific AutoCorrode repl that goals_repair.scala already opened at the
# exact goal -- and prints a JSON envelope to stdout:
#   {"transcript": [...], "final_text": "..."}
# `transcript` is opencode's own session export (includes reasoning/"thinking"
# parts, not just the final answer), for later fine-tuning on the full
# repair trace, not just the outcome.
#
# Required env vars (set by goals_repair.scala per goal):
#   MINI_IR_HOST, MINI_IR_PORT, MINI_IR_TOKEN, MINI_IR_REPL_ID
# Optional:
#   REPAIR_MODEL          provider/model (default: opencode/big-pickle)
#   REPAIR_TIMEOUT_SECS   total budget; opencode itself gets 15s less so this
#                         script still reaches the export step on timeout
#   REPAIR_ADAPTER_DEBUG_DIR  if set, copy intermediate artifacts there
set -euo pipefail

: "${MINI_IR_HOST:?}"
: "${MINI_IR_PORT:?}"
: "${MINI_IR_TOKEN:?}"
: "${MINI_IR_REPL_ID:?}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
model="${REPAIR_MODEL:-opencode/big-pickle}"
prompt="$(cat)"
debug_dir="${REPAIR_ADAPTER_DEBUG_DIR:-}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/.opencode/agents"
cp "$script_dir/opencode_workspace/.opencode/agents/repair.md" "$tmpdir/.opencode/agents/repair.md"

cat > "$tmpdir/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
    "mini_ir": {
      "type": "local",
      "command": ["python3", "$script_dir/mini_ir_mcp.py",
                  "--host", "$MINI_IR_HOST", "--port", "$MINI_IR_PORT",
                  "--token", "$MINI_IR_TOKEN", "--repl", "$MINI_IR_REPL_ID"],
      "enabled": true
    }
  }
}
JSON

# self-limit opencode to less than the caller's own timeout, so this script
# always reaches the export step below with whatever transcript exists so
# far -- otherwise the caller kills the whole adapter mid-run and we lose it.
total_secs="${REPAIR_TIMEOUT_SECS:-300}"
run_secs=$((total_secs > 20 ? total_secs - 15 : total_secs))

events_file="$tmpdir/events.jsonl"
timeout "${run_secs}s" opencode run --pure --format json --model "$model" --agent repair \
  --dir "$tmpdir" "$prompt" < /dev/null > "$events_file" 2>"$tmpdir/stderr.log" || true

session_id="$(python3 -c '
import json, sys
for line in open(sys.argv[1], "r", encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    sid = event.get("sessionID")
    if sid:
        print(sid)
        break
' "$events_file")"

if [ -n "$debug_dir" ]; then
  mkdir -p "$debug_dir"
  cp "$events_file" "$debug_dir/events.jsonl" 2>/dev/null || true
  cp "$tmpdir/stderr.log" "$debug_dir/run_stderr.log" 2>/dev/null || true
  echo "session_id=$session_id" > "$debug_dir/meta.txt"
fi

if [ -z "$session_id" ]; then
  python3 -c 'import json, sys; json.dump({"transcript": [], "final_text": ""}, sys.stdout)'
  exit 0
fi

# "Exporting session: ..." goes to stderr; stdout is already clean JSON.
export_file="$tmpdir/export.json"
opencode export "$session_id" > "$export_file" 2>"$tmpdir/export_stderr.log" || true

if [ -n "$debug_dir" ]; then
  cp "$export_file" "$debug_dir/export.json" 2>/dev/null || true
fi

python3 -c '
import json, sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}

# recorded verbatim -- this is exactly what the agent saw (mini_ir already
# consolidates its own [timing] noise before the agent sees it), so the trace
# matches what a model would see interacting with the real tool at inference time
messages = data.get("messages", [])
final_text = ""
for message in messages:
    info = message.get("info", {}) if isinstance(message, dict) else {}
    if info.get("role") != "assistant":
        continue
    for part in message.get("parts", []):
        if isinstance(part, dict) and part.get("type") == "text" and not part.get("synthetic"):
            text = part.get("text")
            if isinstance(text, str):
                final_text = text

json.dump({"transcript": messages, "final_text": final_text}, sys.stdout)
' "$export_file"
