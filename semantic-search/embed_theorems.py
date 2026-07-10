#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer


DECL_RE = re.compile(
    r"(?m)(?:^|\n)\s*"
    r"(?P<kind>lemma|theorem|corollary|proposition|schematic_goal)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_'.]*(?:\s*\[[^\]]+\])?)?"
    r"\s*:"
)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def clean_text(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def strip_after_first_proof_command(text: str) -> str:
    split = re.split(
        r"(?m)(?:^\s*(?:by|proof|apply|using|unfolding|sorry|done)\b|"
        r"(?<=\")\s+(?:by|proof|using|unfolding|sorry|done)\b)",
        text,
        maxsplit=1,
    )
    return split[0].strip()


def statement_from_context(context: str) -> tuple[str, str, str] | None:
    match = None
    for match in DECL_RE.finditer(context):
        pass
    if match is None:
        return None

    kind = match.group("kind")
    raw_name = match.group("name") or ""
    name = raw_name.split("[", 1)[0].strip()
    body = strip_after_first_proof_command(context[match.end():])
    statement = clean_text(body)
    if not name or not statement:
        return None
    return kind, name, statement


def load_records(json_dir: Path) -> list[dict[str, str]]:
    if not json_dir.is_dir():
        fail(f"input JSON directory does not exist: {json_dir}")

    paths = sorted(json_dir.glob("*.json"))
    if not paths:
        fail(f"no extractor JSON files found in {json_dir}")

    records: dict[tuple[str, str, str], dict[str, str]] = {}
    parse_failures = 0
    for path in paths:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            fail(f"could not parse {path}: {exc}")
        if not isinstance(data, list):
            fail(f"{path} must contain a JSON list, got {type(data).__name__}")

        for item in data:
            if not isinstance(item, dict):
                parse_failures += 1
                continue
            context = item.get("proof_text_before")
            if not isinstance(context, str):
                parse_failures += 1
                continue
            parsed = statement_from_context(context)
            if parsed is None:
                parse_failures += 1
                continue
            kind, name, statement = parsed
            theory = str(item.get("theory") or path.stem)
            key = (theory, name, statement)
            records.setdefault(
                key,
                {
                    "id": f"{theory}.{name}",
                    "theory": theory,
                    "kind": kind,
                    "name": name,
                    "statement": statement,
                    "source_json": str(path),
                },
            )

    if not records:
        fail(
            "no theorem-like declarations could be reconstructed from extractor JSON "
            f"({parse_failures} skipped proof-step records)"
        )

    ordered = sorted(records.values(), key=lambda r: (r["theory"], r["name"], r["statement"]))
    return ordered


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Embed theorem-like declarations reconstructed from Isabelle proof_extractor JSON."
    )
    parser.add_argument(
        "--json-dir",
        default="out/extractor/json",
        help="directory containing proof_extractor JSON files",
    )
    parser.add_argument(
        "--out-dir",
        default="out/embeddings",
        help="directory for theorem metadata and vectors",
    )
    parser.add_argument(
        "--model",
        default="sentence-transformers/all-MiniLM-L6-v2",
        help="SentenceTransformer model name or local path",
    )
    args = parser.parse_args()

    json_dir = Path(args.json_dir).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    records = load_records(json_dir)
    texts = [f"{r['kind']} {r['name']}: {r['statement']}" for r in records]

    print(f"Embedding {len(records)} theorem-like declaration(s) from {json_dir}")
    print(f"Model: {args.model}")
    model = SentenceTransformer(args.model)
    vectors = model.encode(
        texts,
        batch_size=32,
        convert_to_numpy=True,
        normalize_embeddings=True,
        show_progress_bar=True,
    )
    if vectors.shape[0] != len(records):
        fail(f"model returned {vectors.shape[0]} vectors for {len(records)} records")

    vectors = np.asarray(vectors, dtype=np.float32)
    write_jsonl(out_dir / "theorems.jsonl", records)
    np.save(out_dir / "vectors.npy", vectors)
    (out_dir / "model.txt").write_text(args.model + "\n", encoding="utf-8")
    (out_dir / "summary.json").write_text(
        json.dumps(
            {
                "records": len(records),
                "dimensions": int(vectors.shape[1]),
                "model": args.model,
                "json_dir": str(json_dir),
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    print(f"Wrote metadata: {out_dir / 'theorems.jsonl'}")
    print(f"Wrote vectors:  {out_dir / 'vectors.npy'} shape={vectors.shape}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
