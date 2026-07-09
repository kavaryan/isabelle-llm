#!/usr/bin/env bash
# Oneshot adapter: reads a prompt on stdin, prints the plain-text completion
# on stdout. Talks to opencode in non-interactive run mode, using the
# dedicated `oneshot` agent (opencode_workspace/.opencode/agents/oneshot.md)
# which has every built-in tool explicitly disabled -- an empty --dir alone
# only removes MCP servers, not opencode's default bash/edit/etc. tools.
#
# Env vars:
#   ONESHOT_MODEL          provider/model (default: opencode/big-pickle, the free tier)
#   ONESHOT_TIMEOUT_SECS   default: 90
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace="$script_dir/opencode_workspace"
model="${ONESHOT_MODEL:-opencode/big-pickle}"
timeout_secs="${ONESHOT_TIMEOUT_SECS:-90}"
prompt="$(cat)"

timeout "${timeout_secs}s" opencode run --pure --format json --model "$model" --agent oneshot --dir "$workspace" "$prompt" \
  < /dev/null 2>/dev/null | python3 -c '
import sys, json

text_parts = []
saw_error = False
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("type") == "error":
        saw_error = True
        sys.stderr.write(line + "\n")
        continue
    part = event.get("part")
    if event.get("type") == "text" and isinstance(part, dict):
        text = part.get("text")
        if isinstance(text, str):
            text_parts.append(text)

if saw_error and not text_parts:
    sys.exit(1)
sys.stdout.write("\n".join(text_parts))
'
