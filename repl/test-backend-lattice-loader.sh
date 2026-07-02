#!/usr/bin/env bash
set -euo pipefail

host="${IR_REPL_HOST:-127.0.0.1}"
port="${IR_REPL_PORT:-9147}"
token="${IR_AUTH_TOKEN:-local-dev-token}"
run_id="${TEST_RUN_ID:-$$}"
mcp_url="${IR_MCP_URL:-http://127.0.0.1:9148/mcp}"
complete_lattice_path="${COMPLETE_LATTICE_PATH:-/home/isabelle/Isabelle/src/HOL/Lattice/CompleteLattice.thy}"

mcp_session_id="$(
  curl -i -sS -X POST "$mcp_url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-backend-lattice-loader","version":"0.1"}}}' |
    tr -d '\r' |
    awk -F': ' 'tolower($1) == "mcp-session-id" {print $2; exit}'
)"

mcp_call() {
  local payload="$1"

  curl -sS -X POST "$mcp_url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: ${mcp_session_id}" \
    --data "$payload" |
    sed -n 's/^data: //p' |
    jq -r '.result.content[0].text // .error.message'
}

echo "== bare import still fails in the backend =="
{
  printf '%s\n' "$token"
  sleep 0.1
  printf 'Ir.init "BackendBareLattice_%s" ["Lattice"];\n' "$run_id"
  sleep 1
} | socat - "TCP:${host}:${port}"

echo "== qualified theory can initialize after it is known to the backend =="
{
  printf '%s\n' "$token"
  sleep 0.1
  printf 'Ir.init "BackendBareLattice_%s" ["HOL-Lattice.Lattice"];\n' "$run_id"
  sleep 1
} | socat - "TCP:${host}:${port}"

echo "== qualified theory works after explicit load =="
{
  printf '%s\n' "$token"
  sleep 0.1
  printf '%s\n' 'Ir.load_theory "HOL-Lattice.Lattice";'
  sleep 2
  printf 'Ir.init "BackendLoadedLattice_%s" ["HOL-Lattice.Lattice"];\n' "$run_id"
  sleep 2
} | socat - "TCP:${host}:${port}"

echo "== backend resolve maps source line to theory segment only with source maps =="
{
  printf '%s\n' "$token"
  sleep 0.1
  printf '/resolve "%s" 20\n' "$complete_lattice_path"
  sleep 5
} | socat - "TCP:${host}:${port}"

echo "== init_at_line opens the lattice context and accepts a lattice step =="
mcp_call "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"connect\",\"arguments\":{\"host\":\"${host}\",\"port\":${port},\"token\":\"${token}\"}}}"
mcp_call "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"init_at_line\",\"arguments\":{\"id\":\"McpInitAtLine_${run_id}\",\"theory_or_file\":\"${complete_lattice_path}\",\"line\":20}}}"
mcp_call "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"step\",\"arguments\":{\"repl\":\"McpInitAtLine_${run_id}\",\"isar_text\":\"lemma mcp_init_at_line_context_${run_id}: \\\"leq (x::'a::partial_order) x\\\"\"}}}"
mcp_call "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"step\",\"arguments\":{\"repl\":\"McpInitAtLine_${run_id}\",\"isar_text\":\"by (rule leq_refl)\"}}}"
