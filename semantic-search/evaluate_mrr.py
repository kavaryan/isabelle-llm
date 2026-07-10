#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        fail(f"missing JSONL file: {path}")
    rows = []
    with path.open(encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except Exception as exc:
                fail(f"could not parse {path}:{lineno}: {exc}")
            if not isinstance(value, dict):
                fail(f"{path}:{lineno} must be a JSON object")
            rows.append(value)
    if not rows:
        fail(f"no rows in {path}")
    return rows


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def load_db(db_dir: Path) -> tuple[list[dict], np.ndarray, str]:
    metadata_path = db_dir / "theorems.jsonl"
    vectors_path = db_dir / "vectors.npy"
    model_path = db_dir / "model.txt"
    if not db_dir.is_dir():
        fail(f"embedding DB directory does not exist: {db_dir}")
    if not vectors_path.is_file():
        fail(f"missing vectors file: {vectors_path}")
    if not model_path.is_file():
        fail(f"missing model file: {model_path}")

    rows = read_jsonl(metadata_path)
    try:
        vectors = np.load(vectors_path)
    except Exception as exc:
        fail(f"could not load vectors from {vectors_path}: {exc}")
    if vectors.ndim != 2:
        fail(f"vectors must be a 2D array, got shape {vectors.shape}")
    if vectors.shape[0] != len(rows):
        fail(f"vectors rows ({vectors.shape[0]}) != metadata rows ({len(rows)})")

    seen: set[str] = set()
    for row in rows:
        for field in ("id", "theory", "kind", "name", "statement"):
            if not isinstance(row.get(field), str) or not row[field]:
                fail(f"metadata row missing string field {field}: {row}")
        if row["id"] in seen:
            fail(f"duplicate theorem id in metadata: {row['id']}")
        seen.add(row["id"])

    model_name = model_path.read_text(encoding="utf-8").strip()
    if not model_name:
        fail(f"empty model file: {model_path}")

    vectors = np.asarray(vectors, dtype=np.float32)
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    if np.any(norms == 0):
        fail("vectors contain zero-norm rows")
    vectors = vectors / norms
    return rows, vectors, model_name


def load_benchmark(path: Path, known_ids: set[str]) -> list[dict]:
    rows = read_jsonl(path)
    seen: set[str] = set()
    for row in rows:
        for field in ("id", "query_id", "query_text", "source"):
            if not isinstance(row.get(field), str) or not row[field]:
                fail(f"benchmark row missing string field {field}: {row}")
        if row["id"] in seen:
            fail(f"duplicate benchmark id: {row['id']}")
        seen.add(row["id"])
        if row["query_id"] not in known_ids:
            fail(f"benchmark query_id is absent from DB: {row['query_id']}")
        relevant = row.get("relevant_ids")
        if not isinstance(relevant, list) or not relevant:
            fail(f"benchmark row must have a non-empty relevant_ids list: {row}")
        for dep_id in relevant:
            if not isinstance(dep_id, str) or not dep_id:
                fail(f"benchmark relevant id must be a non-empty string: {row}")
            if dep_id not in known_ids:
                fail(f"benchmark relevant id is absent from DB: {dep_id}")
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate dependency retrieval MRR@10.")
    parser.add_argument("--db-dir", default="out/embeddings")
    parser.add_argument("--benchmark", default="out/benchmark/benchmark.jsonl")
    parser.add_argument("--out-dir", default="out/eval")
    parser.add_argument("--top-k", type=int, default=10)
    args = parser.parse_args()

    if args.top_k <= 0:
        fail("--top-k must be positive")

    db_dir = Path(args.db_dir).resolve()
    benchmark_path = Path(args.benchmark).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    records, vectors, model_name = load_db(db_dir)
    id_to_index = {row["id"]: i for i, row in enumerate(records)}
    benchmark = load_benchmark(benchmark_path, set(id_to_index))

    print(f"Embedding {len(benchmark)} benchmark querie(s) with {model_name}")
    model = SentenceTransformer(model_name)
    query_vectors = model.encode(
        [row["query_text"] for row in benchmark],
        batch_size=32,
        convert_to_numpy=True,
        normalize_embeddings=True,
        show_progress_bar=True,
    )
    query_vectors = np.asarray(query_vectors, dtype=np.float32)
    if query_vectors.shape[0] != len(benchmark):
        fail(f"model returned {query_vectors.shape[0]} vectors for {len(benchmark)} queries")

    per_query: list[dict] = []
    reciprocal_ranks: list[float] = []
    dependency_reciprocal_ranks: list[float] = []
    dependency_hits = 0
    dependency_total = 0
    for row, query_vector in zip(benchmark, query_vectors):
        scores = vectors @ query_vector
        query_index = id_to_index[row["query_id"]]
        scores[query_index] = -np.inf

        order = np.argsort(-scores)
        top_indices = order[: args.top_k]
        top = [
            {
                "rank": rank,
                "id": records[index]["id"],
                "score": float(scores[index]),
                "kind": records[index]["kind"],
                "name": records[index]["name"],
                "statement": records[index]["statement"],
            }
            for rank, index in enumerate(top_indices, 1)
        ]

        relevant = set(row["relevant_ids"])
        rank_by_id = {item["id"]: item["rank"] for item in top}
        relevant_ranks = []
        for dep_id in row["relevant_ids"]:
            rank = rank_by_id.get(dep_id, 0)
            dep_reciprocal_rank = 0.0 if rank == 0 else 1.0 / rank
            dependency_total += 1
            dependency_reciprocal_ranks.append(dep_reciprocal_rank)
            if rank > 0:
                dependency_hits += 1
            relevant_ranks.append(
                {
                    "id": dep_id,
                    "rank": rank,
                    "reciprocal_rank": dep_reciprocal_rank,
                }
            )
        first_rank = next((item["rank"] for item in top if item["id"] in relevant), None)
        reciprocal_rank = 0.0 if first_rank is None else 1.0 / first_rank
        reciprocal_ranks.append(reciprocal_rank)
        per_query.append(
            {
                "id": row["id"],
                "query_id": row["query_id"],
                "query_text": row["query_text"],
                "relevant_ids": row["relevant_ids"],
                "relevant_ranks": relevant_ranks,
                "first_relevant_rank": first_rank,
                "reciprocal_rank": reciprocal_rank,
                "top_k": top,
            }
        )

    hit_count = sum(1 for x in reciprocal_ranks if x > 0)
    mrr = float(np.mean(reciprocal_ranks))
    dependency_mrr = float(np.mean(dependency_reciprocal_ranks))
    metrics = {
        "mrr@10" if args.top_k == 10 else f"mrr@{args.top_k}": mrr,
        "dependency_mrr@10" if args.top_k == 10 else f"dependency_mrr@{args.top_k}": dependency_mrr,
        "top_k": args.top_k,
        "queries": len(benchmark),
        "hits": hit_count,
        "misses": len(benchmark) - hit_count,
        "dependency_edges": dependency_total,
        "dependency_hits": dependency_hits,
        "dependency_misses": dependency_total - dependency_hits,
        "model": model_name,
        "db_dir": str(db_dir),
        "benchmark": str(benchmark_path),
    }
    (out_dir / "metrics.json").write_text(
        json.dumps(metrics, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_jsonl(out_dir / "per_query.jsonl", per_query)

    print(f"MRR@{args.top_k}: {mrr:.6f} ({hit_count}/{len(benchmark)} hits)")
    print(
        f"Dependency MRR@{args.top_k}: {dependency_mrr:.6f} "
        f"({dependency_hits}/{dependency_total} dependency hits)"
    )
    print(f"Wrote metrics: {out_dir / 'metrics.json'}")
    print(f"Wrote per-query results: {out_dir / 'per_query.jsonl'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
