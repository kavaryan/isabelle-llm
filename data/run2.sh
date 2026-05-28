#!/usr/bin/env bash

set -euo pipefail

image_name="isabelle-mcp:local"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${DISPLAY:-}" ]; then
    echo "DISPLAY is not set; run this from an X11/XWayland desktop session." >&2
    exit 1
fi

if ! docker image inspect "$image_name" >/dev/null 2>&1; then
    docker build -t "$image_name" "$script_dir"
fi

args=(--shm-size=2g -p 8765:8765 -p 8766:8766 -v "$script_dir/d:/d")
xhost +local: >/dev/null 2>&1 || true
args+=(-e "DISPLAY=${DISPLAY}")
args+=(-e "IQ_AUTH_TOKEN=${IQ_AUTH_TOKEN:-local-dev-token}")
args+=(-e "IQ_MCP_ALLOWED_ROOTS=/d" -e "IQ_MCP_ALLOWED_READ_ROOTS=/d")

if [ -d /tmp/.X11-unix ]; then
    args+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
fi

if [ -n "${XAUTHORITY:-}" ] && [ -f "${XAUTHORITY}" ]; then
    args+=(-e XAUTHORITY=/home/isabelle/.Xauthority -v "${XAUTHORITY}:/home/isabelle/.Xauthority:ro")
elif [ -f "${HOME}/.Xauthority" ]; then
    args+=(-e XAUTHORITY=/home/isabelle/.Xauthority -v "${HOME}/.Xauthority:/home/isabelle/.Xauthority:ro")
fi

exec docker run -it --rm "${args[@]}" "$image_name" jedit
