#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

positive_context='theory Test
  imports Main
begin

lemma swap_conj: "A \<and> B \<Longrightarrow> B \<and> A"'

negative_context='theory Test
  imports Main
begin

lemma impossible: "False"'

start_mcp() {
  local context="$1"
  coproc MCP_SERVER {
    MINI_IR_CONTEXT="$context" "$script_dir/isar-repl" \
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

call_step_by_blast() {
  local context="$1"
  local response
  start_mcp "$context"
  send_mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-mini-ir-context-env","version":"0.1"}}}'
  read_response_var response 1
  send_mcp '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  send_mcp '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"step","arguments":{"isar_text":"by blast"}}}'
  read_response_var response 2
  stop_mcp
  jq -r '.result.content[0].text // (.error.message // .)' <<<"$response"
}

call_step_then_back_twice() {
  local context="$1"
  local response
  start_mcp "$context"
  send_mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-mini-ir-context-env","version":"0.1"}}}'
  read_response_var response 1
  send_mcp '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  send_mcp '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"step","arguments":{"isar_text":"by blast"}}}'
  read_response_var response 2
  send_mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"back","arguments":{}}}'
  read_response_var response 3
  jq -r '.result.content[0].text // (.error.message // .)' <<<"$response"
  send_mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"back","arguments":{}}}'
  read_response_var response 4
  stop_mcp
  jq -r '.result.content[0].text // (.error.message // .)' <<<"$response"
}

echo "== positive: MINI_IR_CONTEXT proves with by blast =="
positive_output="$(call_step_by_blast "$positive_context")"
printf '%s\n\n' "$positive_output"
if ! grep -q 'theorem swap_conj' <<<"$positive_output"; then
  echo "positive case did not prove swap_conj" >&2
  exit 1
fi

echo "== negative: only MINI_IR_CONTEXT differs; by blast should fail =="
negative_output="$(call_step_by_blast "$negative_context")"
printf '%s\n\n' "$negative_output"
if ! grep -Eq 'Error executing tool step|Failed to apply proof method|False' <<<"$negative_output"; then
  echo "negative case did not show the expected failure" >&2
  exit 1
fi

echo "== back protection: cannot back past MINI_IR_CONTEXT =="
back_output="$(call_step_then_back_twice "$positive_context")"
printf '%s\n\n' "$back_output"
if ! grep -q 'refusing to back past protected context' <<<"$back_output"; then
  echo "back protection did not refuse to remove MINI_IR_CONTEXT" >&2
  exit 1
fi

echo "mini_ir MINI_IR_CONTEXT env test passed"
