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
#  -d out: output directory
# Any additional arguments passed to this script will override/augment the command options.
# isabelle proof_extractor -L -A -m 16 -c 4000 -v -T theories_2k.txt -d out "$@"


mkdir -p proof_extractor_out

docker run --rm \
  -v "$PWD/proof_extractor_out:/out" \
  isabelle-extractor:2025-2 \
  -L -A -m 0 -c 4000 -v -T theories_2k.txt