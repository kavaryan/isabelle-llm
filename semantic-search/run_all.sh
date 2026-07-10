#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$HOME/.venv/bin/python}"
MODEL="${MODEL:-sentence-transformers/all-MiniLM-L6-v2}"

if [ ! -x "$PYTHON_BIN" ]; then
  echo "ERROR: Python executable not found or not executable: $PYTHON_BIN" >&2
  exit 127
fi

rm -rf "$SCRIPT_DIR/out/embeddings"

"$SCRIPT_DIR/run_lattice_extraction.sh" "$@"

"$PYTHON_BIN" "$SCRIPT_DIR/embed_theorems.py" \
  --json-dir "$SCRIPT_DIR/out/extractor/json" \
  --out-dir "$SCRIPT_DIR/out/embeddings" \
  --model "$MODEL"
