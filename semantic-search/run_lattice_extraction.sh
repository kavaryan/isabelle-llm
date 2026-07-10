#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
IMAGE="${IMAGE:-isabelle-extractor}"
HEAPS_VOLUME="${HEAPS_VOLUME:-isabelle-extractor-heaps}"
IMAGE_BUILD_COMMAND="${IMAGE_BUILD_COMMAND:-make -C /home/me/wr/ai4math/isabelle docker-proof}"
TARGET_THEORIES=("$@")

if [ "${#TARGET_THEORIES[@]}" -eq 0 ]; then
  TARGET_THEORIES=(HOL-Lattice.Lattice)
fi

find_docker() {
  if command -v docker >/dev/null 2>&1; then
    command -v docker
    return 0
  fi
  if command -v docker.exe >/dev/null 2>&1; then
    command -v docker.exe
    return 0
  fi
  local docker_desktop="/mnt/c/Program Files/Docker/Docker/resources/bin/docker"
  if [ -x "$docker_desktop" ]; then
    printf '%s\n' "$docker_desktop"
    return 0
  fi
  return 1
}

DOCKER_BIN="$(find_docker || true)"
if [ -z "$DOCKER_BIN" ]; then
  echo "ERROR: Docker was not found. Install Docker or enable Docker Desktop WSL integration." >&2
  exit 127
fi

if ! "$DOCKER_BIN" version >/dev/null 2>&1; then
  echo "ERROR: '$DOCKER_BIN version' failed. Docker exists, but the daemon/integration is not usable." >&2
  "$DOCKER_BIN" version >&2 || true
  exit 1
fi

mkdir -p "$OUT_DIR/logs"

if ! "$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: required Docker image is missing: $IMAGE" >&2
  echo "Build it first with:" >&2
  echo "  $IMAGE_BUILD_COMMAND" >&2
  exit 1
fi

if ! rm -rf "$OUT_DIR/extractor"; then
  echo "ERROR: could not remove old extractor output: $OUT_DIR/extractor" >&2
  echo "Fix the directory ownership/permissions, then rerun this script." >&2
  exit 1
fi
mkdir -p "$OUT_DIR/extractor"

printf '%s\n' "${TARGET_THEORIES[@]}" > "$OUT_DIR/theories.txt"
echo "Extracting theories: ${TARGET_THEORIES[*]}"
"$DOCKER_BIN" run --rm \
  -v "$OUT_DIR/extractor:/out:Z" \
  -v "$HEAPS_VOLUME:/home/isabelle/.isabelle/heaps" \
  "$IMAGE" \
  -A -m 0 -c 0 -v "${TARGET_THEORIES[@]}" \
  2>&1 | tee "$OUT_DIR/logs/extract.log"

json_count="$(find "$OUT_DIR/extractor/json" -type f -name '*.json' 2>/dev/null | wc -l)"
if [ "$json_count" -eq 0 ]; then
  echo "ERROR: extraction finished without JSON files under $OUT_DIR/extractor/json" >&2
  exit 1
fi

echo "Wrote $json_count extractor JSON file(s) under $OUT_DIR/extractor/json"
