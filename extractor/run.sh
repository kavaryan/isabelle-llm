#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Run the proof-extractor with recommended defaults:
#  -L: keep only leaf proofs (steps whose innermost proof block has no nested sub-proofs)
#  -A: exclude proofs containing any 'apply' command
#  -m 16: cap sledgehammer relevance facts per goal to 16
#  -c 4000: limit proof_text_before to its last 4000 symbols
#  -v: verbose mode (enable build_progress_detailed for theory-by-theory compilation output)
#  -T theories_2k.txt: target theories yielding ~2000 goals in total
#  -d out: output directory (fixed to /out inside the container by the entrypoint)
# Pass theory names (or other options) as arguments to override the default
# theory list, e.g.  ./run.sh HOL-Lattice.Lattice

mkdir -p proof_extractor_out

# Default to the curated ~2000-goal theory list; any arguments override it.
if [ "$#" -gt 0 ]; then
  targets=("$@")
else
  targets=(-T theories_2k.txt)
fi

# Persist the Isabelle session heaps in a named volume so the parent sessions
# (e.g. HOL-Computational_Algebra) built on the first run are reused by later
# runs instead of being rebuilt from scratch each time (docker run --rm would
# otherwise discard them). A named volume is pre-populated from the image, so
# the prebuilt HOL heap is kept.
HEAPS_VOLUME="${HEAPS_VOLUME:-isabelle-extractor-heaps}"

docker run --rm \
  -v "$PWD/proof_extractor_out:/out:Z" \
  -v "$HEAPS_VOLUME:/home/isabelle/.isabelle/heaps" \
  isabelle-extractor \
  -L -A -m 16 -c 4000 -v "${targets[@]}"