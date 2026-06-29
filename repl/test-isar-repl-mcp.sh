#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

start_mcp() {
  coproc MCP_SERVER {
    "$script_dir/isar-repl" \
      --mcp \
      --host "${IR_REPL_HOST:-127.0.0.1}" \
      --port "${IR_REPL_PORT:-9147}" \
      --token "${IR_AUTH_TOKEN:-local-dev-token}"
  }
  MCP_OUT="${MCP_SERVER[0]}"
  MCP_IN="${MCP_SERVER[1]}"
  MCP_PID="$MCP_SERVER_PID"
}

stop_mcp() {
  exec {MCP_IN}>&-
  wait "$MCP_PID" 2>/dev/null || true
}

send_mcp() {
  local line="$1"
  printf '>>> %s\n' "$line" >&2
  printf '%s\n' "$line" >&"${MCP_IN}"
}

read_response() {
  local id="$1"
  local line
  while IFS= read -r -u "${MCP_OUT}" line; do
    if jq -e --argjson id "$id" '.id == $id' >/dev/null <<<"$line"; then
      printf '%s\n' "$line"
      return 0
    fi
  done
  echo "missing MCP response id=$id" >&2
  return 1
}

read_response_var() {
  local __var="$1"
  local id="$2"
  local line
  while IFS= read -r -u "${MCP_OUT}" line; do
    if jq -e --argjson id "$id" '.id == $id' >/dev/null <<<"$line"; then
      printf -v "$__var" '%s' "$line"
      return 0
    fi
  done
  echo "missing MCP response id=$id" >&2
  return 1
}

print_tool_result() {
  jq -r '
    "id=\(.id)\n" +
    if .error then
      "ERROR: \(.error.message)"
    else
      (.result.content[0].text // (.result | tostring))
    end +
    "\n"
  '
}

run_commands() {
  local -n commands_ref="$1"
  local mode="$2"
  local response
  local id
  local method
  local index

  for index in "${!commands_ref[@]}"; do
    send_mcp "${commands_ref[$index]}"

    id="$(jq -r '.id // empty' <<<"${commands_ref[$index]}")"
    if [[ -z "$id" ]]; then
      continue
    fi

    method="$(jq -r '.method' <<<"${commands_ref[$index]}")"
    read_response_var response "$id"

    case "$method:$mode" in
      "initialize:"*)
        ;;
      "tools/list:"*)
        jq -r '.result.tools[].name' <<<"$response"
        ;;
      "tools/call:tool")
        print_tool_result <<<"$response"
        ;;
    esac
  done
}

echo "== tools/list =="
tools_commands=(
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-isar-repl-mcp","version":"0.1"}}}'
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
)
start_mcp
run_commands tools_commands tools
stop_mcp

echo
echo "== simulated lemma repair =="
repair_commands=(
  '{"jsonrpc":"2.0","id":10,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-isar-repl-mcp","version":"0.1"}}}'
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"reset","arguments":{}}}'
  '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"step","arguments":{"isar_text":"lemma mcp_fix_test: \"((A --> B) --> A) --> A\""}}}'
  '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"step","arguments":{"isar_text":"apply rule"}}}'
  '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"step","arguments":{"isar_text":"apply assumption"}}}'
  '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"back","arguments":{}}}'
  '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"step","arguments":{"isar_text":"by blast"}}}'
)
start_mcp
run_commands repair_commands tool
stop_mcp
