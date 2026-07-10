#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
image="${DISTILLATION_IMAGE:-isabelle-goals}"
output_dir="${DISTILLATION_OUT_DIR:-$repo_root/isabelle-llm/process_goals/pipeline_smoke_out}"
api_key_file="${OPENCODE_API_KEY_FILE:-$HOME/.opencode-api-key}"

if [[ ! -s "$api_key_file" ]]; then
  echo "error: OpenCode API key file not found or empty: $api_key_file" >&2
  exit 2
fi

if [[ "$#" -eq 0 ]]; then
  set -- -m 10 HOL-Lattice.CompleteLattice
fi

mkdir -p "$output_dir"
chmod a+rwx "$output_dir"

if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker build -t "$image" "$repo_root/isabelle-llm/process_goals"
fi

revision="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
docker run --rm \
  --entrypoint /bin/bash \
  -v "$output_dir:/out" \
  -v "$api_key_file:/home/isabelle/.opencode-api-key:ro" \
  -e OUT_DIR=/out \
  -e PIPELINE_REVISION="$revision" \
  "$image" \
  /home/isabelle/process_goals/run_pipeline.sh --smoketest "$@"

echo "Results: $output_dir"
