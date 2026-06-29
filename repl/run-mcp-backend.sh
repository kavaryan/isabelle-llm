#!/usr/bin/env bash

set -euo pipefail

image_name="isabelle-mcp:local"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo $script_dir

if ! docker image inspect "$image_name" >/dev/null 2>&1; then
    echo "Docker image '$image_name' not found." >&2
    echo "Build it first with:" >&2
    echo "  cd \"$script_dir\" && make docker" >&2
    exit 1
fi

args=(
    --shm-size=2g
    -p 9147:19147
    -p 9148:19148
)
run_flags=(-i --rm)
if [ -t 0 ] && [ -t 1 ]; then
    run_flags=(-it --rm)
fi

if [ -n "${DISPLAY:-}" ]; then
    xhost +local: >/dev/null 2>&1 || true
    args+=(-e "DISPLAY=${DISPLAY}")

    if [ -d /tmp/.X11-unix ]; then
        args+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
    fi

    if [ -n "${XAUTHORITY:-}" ] && [ -f "${XAUTHORITY}" ]; then
        args+=(-e XAUTHORITY=/home/isabelle/.Xauthority -v "${XAUTHORITY}:/home/isabelle/.Xauthority:ro")
    elif [ -f "${HOME}/.Xauthority" ]; then
        args+=(-e XAUTHORITY=/home/isabelle/.Xauthority -v "${HOME}/.Xauthority:/home/isabelle/.Xauthority:ro")
    fi
else
    echo "DISPLAY is not set; running Isabelle under Xvfb inside the container." >&2
    echo "GUI tools such as 'vscode' will start on that virtual display, not on your desktop." >&2
    args+=(-e ISABELLE_USE_XVFB=1)
fi

args+=(-e "IQ_AUTH_TOKEN=${IQ_AUTH_TOKEN:-local-dev-token}")
args+=(-e "IQ_MCP_ALLOWED_ROOTS=/home/isabelle/thys/" -e "IQ_MCP_ALLOWED_READ_ROOTS=/home/isabelle/thys/")
args+=(-e "ISABELLE_IR_HOME=/home/isabelle/AutoCorrode/ir")
args+=(-e "IR_AUTH_TOKEN=${IR_AUTH_TOKEN:-local-dev-token}")

cmd=(
    env bash -lc
    'set -euo pipefail
cd /home/isabelle/AutoCorrode/ir
socat TCP-LISTEN:19147,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:9147 &
socat TCP-LISTEN:19148,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:9148 &
exec python3 ./repl.py \
  --isabelle /home/isabelle/Isabelle2025-2/bin/isabelle \
  --session "${IR_SESSION:-HOL}" \
  --poly-ml-port 9146 \
  --port 9147 \
  --mcp \
  --mcp-options "--transport streamable-http --port 9148 --repl-port 9147" \
  --server-only'
)
if [ "$#" -gt 0 ]; then
    cmd=("$@")
fi

exec docker run "${run_flags[@]}" "${args[@]}" "$image_name" "${cmd[@]}"
