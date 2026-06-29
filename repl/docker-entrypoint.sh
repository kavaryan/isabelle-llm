#!/usr/bin/env bash

set -euo pipefail

: "${IQ_MCP_INTERNAL_PORT:=8765}"
: "${IQ_MCP_PORT:=18765}"
: "${IQ_MCP_HTTP_PORT:=8766}"
: "${IQ_AUTH_TOKEN:=local-dev-token}"
export IQ_AUTH_TOKEN

(
    until timeout 1 bash -c "</dev/tcp/127.0.0.1/${IQ_MCP_INTERNAL_PORT}" >/dev/null 2>&1; do
        sleep 0.5
    done
    /usr/local/bin/iq-http-bridge "$IQ_MCP_HTTP_PORT" &
    exec socat TCP-LISTEN:${IQ_MCP_PORT},fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:${IQ_MCP_INTERNAL_PORT}
) &

if [ "${ISABELLE_USE_XVFB:-}" = "1" ]; then
    : "${DISPLAY:=:99}"
    export DISPLAY
    Xvfb "$DISPLAY" -screen 0 1280x1024x24 -nolisten tcp &
fi

exec /home/isabelle/Isabelle/bin/isabelle "$@"
