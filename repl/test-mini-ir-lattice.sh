#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

lattice_context='(*  Title:      HOL/Lattice/CompleteLattice.thy
    Author:     Markus Wenzel, TU Muenchen
*)

section \<open>Complete lattices\<close>

theory CompleteLattice
  imports Lattice
begin

class complete_lattice =
  assumes ex_Inf: "\<exists>inf. is_Inf A inf"'

start_mcp() {
  coproc MCP_SERVER {
    MINI_IR_CONTEXT_TEXT="$lattice_context" "$script_dir/isar-repl" \
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

mcp_call() {
  local id="$1"
  local tool="$2"
  local isar_text="$3"
  jq -cn \
    --argjson id "$id" \
    --arg tool "$tool" \
    --arg isar_text "$isar_text" \
    '{jsonrpc:"2.0", id:$id, method:"tools/call", params:{name:$tool, arguments:{isar_text:$isar_text}}}'
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

start_mcp
send_mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-mini-ir-lattice","version":"0.1"}}}'
read_response_var response 1
send_mcp '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
send_mcp "$(mcp_call 2 step 'lemma lattice_context_smoke: "(x::'\''a::partial_order) \<sqsubseteq> x"')"
read_response_var response 2
text="$(jq -r '.result.content[0].text // (.error.message // .)' <<<"$response")"
printf '%s\n' "$text"

if grep -q 'Theory loader: undefined entry for theory "Lattice"' <<<"$text"; then
  stop_mcp
  echo "mini_ir still cannot resolve imports Lattice" >&2
  exit 1
fi

send_mcp "$(mcp_call 3 step 'by (rule leq_refl)')"
read_response_var response 3
stop_mcp

text="$(jq -r '.result.content[0].text // (.error.message // .)' <<<"$response")"
printf '%s\n' "$text"

if grep -q 'theorem lattice_context_smoke' <<<"$text"; then
  echo "mini_ir Lattice context test passed" >&2
  exit 0
fi

echo "expected to prove lattice_context_smoke" >&2
exit 1
