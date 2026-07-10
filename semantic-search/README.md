# Isabelle Semantic Search

Small pipeline for testing theorem-statement embeddings against proof-dependency retrieval.

The current prototype is scoped to `HOL-Lattice.Lattice`.

## Goal

- Build an embedding database of Isabelle theorem-like declarations.
- Curate a benchmark from explicit theorem dependencies in proof text.
- Measure whether cosine similarity retrieves proof dependencies from a theorem statement.

## Data Flow

- `run_lattice_extraction.sh` runs the existing `isabelle-extractor` Docker image.
- The extractor writes proof-step JSON under `out/extractor/json`.
- `embed_theorems.py` reconstructs theorem declarations from extractor JSON.
- `curate_dependency_benchmark.py` turns proof-command fact mentions into retrieval ground truth.
- `evaluate_mrr.py` embeds benchmark queries and computes MRR@10.
- It reports both query-level MRR and dependency-level MRR.

## Embedding Database

- Values are theorem-like declarations.
- The embedded text is:

```text
kind name: statement
```

- Proof text is not embedded in the value.
- Proof states are not embedded in the value.
- The theorem name is included because the benchmark query also includes it.

## Benchmark

- A benchmark row is one query theorem and its proof dependencies.
- The query text is also:

```text
kind name: statement
```

- Ground truth comes from explicit fact names in `proof_commands`.
- Example dependency sources include `rule foo`, `simp add: foo`, `auto intro: foo`, `using foo`, and `OF foo`.
- The benchmark asks: can the query theorem statement retrieve the theorems used in its proof?
- Query-level MRR uses the first relevant dependency in the top 10.
- Dependency-level MRR gives every proof dependency its own rank; missing dependencies get rank `0` and reciprocal rank `0`.

## Ground Truth Decisions

- Use explicit proof-text facts, not Sledgehammer/MePo suggested facts.
- Resolve dependency names to theorem ids by exact id first.
- Resolve unqualified names only when the name is unique in the embedding DB.
- Exclude self edges.
- Drop unresolved names from scoring.
- Write unresolved names to `out/benchmark/unresolved_dependencies.jsonl`.

## Why Not Suggested Facts

- Suggested facts are candidates from Sledgehammer relevance filtering.
- They are useful retrieval hints, but they are not proof dependencies.
- This benchmark is intended to measure recovery of facts actually mentioned in proofs.

## Why Not Heap Conversion

- Isabelle heaps are Poly/ML runtime images.
- They are not a stable JSON theorem database.
- The robust route is to run Isabelle once, export structured data, then use JSON downstream.

## Extractor Limitation

- The current extractor is proof-step oriented.
- It does not enumerate every theorem/fact in the final theory context.
- Dynamic facts from packages such as `datatype` are not guaranteed to appear.
- They appear only if they occur in proof context outputs or suggested facts.

## Docker Decisions

- `run_lattice_extraction.sh` does not build Docker.
- It requires the image `isabelle-extractor` to already exist.
- If the image is missing, build it with:

```bash
make -C /home/me/wr/ai4math/isabelle docker-proof
```

- The script also does not run a separate `isabelle build` first.
- The extractor already invokes Isabelle build/recheck internally.

## Failure Policy

- Scripts should fail loud.
- Missing Docker, missing image, missing DB files, malformed benchmark rows, and vector/metadata mismatches are hard errors.
- Unresolved proof dependencies are not hard errors.
- Unresolved dependencies are diagnostics because many proof names are local, generated, ambiguous, or outside the embedded corpus.

## Current Result

- Corpus: 42 theorem-like declarations.
- Benchmark: 27 query rows.
- Resolved dependency edges: 42.
- Unresolved dependency mentions: 208.
- MRR@10: `0.46125808348030567`.
- Hits@10: 25 of 27 queries.
- Dependency MRR@10: `0.31149848828420257`.
- Dependency hits@10: 29 of 42 dependency edges.

## Commands

Run the full fresh pipeline:

```bash
./run_all.sh
```

Curate benchmark from existing extractor JSON and embeddings:

```bash
~/.venv/bin/python curate_dependency_benchmark.py \
  --json-dir out/extractor/json \
  --metadata out/embeddings/theorems.jsonl \
  --out-dir out/benchmark
```

Evaluate MRR@10:

```bash
~/.venv/bin/python evaluate_mrr.py \
  --db-dir out/embeddings \
  --benchmark out/benchmark/benchmark.jsonl \
  --out-dir out/eval
```

## Output Files

- `out/embeddings/theorems.jsonl`: theorem metadata.
- `out/embeddings/vectors.npy`: normalized SBERT vectors.
- `out/embeddings/model.txt`: embedding model name.
- `out/benchmark/benchmark.jsonl`: dependency-retrieval benchmark.
- `out/benchmark/unresolved_dependencies.jsonl`: dropped dependency names.
- `out/eval/metrics.json`: aggregate metrics.
- `out/eval/per_query.jsonl`: top-10 retrievals and reciprocal rank per query.
