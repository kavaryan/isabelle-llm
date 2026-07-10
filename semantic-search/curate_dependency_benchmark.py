#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


DECL_RE = re.compile(
    r"(?m)(?:^|\n)\s*"
    r"(?P<kind>lemma|theorem|corollary|proposition|schematic_goal)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_'.]*(?:\s*\[[^\]]+\])?)?"
    r"\s*:"
)

TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_'.]*(?:\.[A-Za-z_][A-Za-z0-9_'.]*)*")

METHOD_WORDS = {
    "OF", "THEN", "where", "of", "in", "for",
    "add", "del", "only", "split", "cong",
    "intro", "intro!", "intro?", "elim", "elim!", "elim?", "dest", "simp",
    "rule", "erule", "drule", "frule", "subst", "cases", "induct", "coinduct",
    "simp_all", "auto", "blast", "fastforce", "force", "metis", "meson",
    "presburger", "linarith", "arith", "assumption", "assumptions", "clarify",
    "safe", "clarsimp", "unfolding", "using", "apply", "by", "proof", "qed",
    "done", "from", "then", "hence", "thus", "show", "have", "obtain", "fix",
    "assume", "let", "note", "ultimately", "finally", "also", "moreover",
}


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
    statement = clean_text(strip_after_first_proof_command(context[match.end():]))
    if not name or not statement:
        return None
    return kind, name, statement


def theorem_text(row: dict) -> str:
    return f"{row['kind']} {row['name']}: {row['statement']}"


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
                rows.append(json.loads(line))
            except Exception as exc:
                fail(f"could not parse {path}:{lineno}: {exc}")
    if not rows:
        fail(f"no rows in {path}")
    return rows


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def load_metadata(path: Path) -> tuple[dict[str, dict], dict[str, str], set[str]]:
    rows = read_jsonl(path)
    by_id: dict[str, dict] = {}
    name_counts: Counter[str] = Counter()
    for row in rows:
        for field in ("id", "theory", "kind", "name", "statement"):
            if not isinstance(row.get(field), str) or not row[field]:
                fail(f"metadata row missing string field {field}: {row}")
        if row["id"] in by_id:
            fail(f"duplicate theorem id in metadata: {row['id']}")
        by_id[row["id"]] = row
        name_counts[row["name"]] += 1

    unique_name_to_id = {
        row["name"]: row["id"]
        for row in rows
        if name_counts[row["name"]] == 1
    }
    return by_id, unique_name_to_id, set(by_id)


def normalize_dep_name(token: str) -> str:
    return token.strip("'").split("[", 1)[0].strip()


def proof_command_dependencies(commands: list[str]) -> set[str]:
    deps: set[str] = set()
    for command in commands:
        if not isinstance(command, str):
            continue
        cleaned = re.sub(r"‹[^›]*›|\"[^\"]*\"|\?[_A-Za-z0-9'.]+", " ", command)
        for token in TOKEN_RE.findall(cleaned):
            token = normalize_dep_name(token)
            if not token or token in METHOD_WORDS:
                continue
            if token[0].islower() or "." in token:
                deps.add(token)
    return deps


def resolve_dependency(name: str, ids: set[str], unique_name_to_id: dict[str, str]) -> str | None:
    if name in ids:
        return name
    if name in unique_name_to_id:
        return unique_name_to_id[name]
    base = name.rsplit(".", 1)[-1]
    if base in unique_name_to_id:
        return unique_name_to_id[base]
    return None


def load_extractor_records(json_dir: Path) -> list[tuple[Path, dict]]:
    if not json_dir.is_dir():
        fail(f"input extractor JSON directory does not exist: {json_dir}")
    paths = sorted(json_dir.glob("*.json"))
    if not paths:
        fail(f"no extractor JSON files found in {json_dir}")
    records: list[tuple[Path, dict]] = []
    for path in paths:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            fail(f"could not parse {path}: {exc}")
        if not isinstance(data, list):
            fail(f"{path} must contain a JSON list, got {type(data).__name__}")
        for item in data:
            if isinstance(item, dict):
                records.append((path, item))
    if not records:
        fail(f"no proof-step records found in {json_dir}")
    return records


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Curate theorem-dependency retrieval benchmark from proof_extractor JSON."
    )
    parser.add_argument("--json-dir", default="out/extractor/json")
    parser.add_argument("--metadata", default="out/embeddings/theorems.jsonl")
    parser.add_argument("--out-dir", default="out/benchmark")
    args = parser.parse_args()

    json_dir = Path(args.json_dir).resolve()
    metadata_path = Path(args.metadata).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    by_id, unique_name_to_id, ids = load_metadata(metadata_path)
    deps_by_query: dict[str, set[str]] = defaultdict(set)
    unresolved: Counter[tuple[str, str]] = Counter()
    skipped: Counter[str] = Counter()

    for path, item in load_extractor_records(json_dir):
        context = item.get("proof_text_before")
        if not isinstance(context, str):
            skipped["missing_proof_text_before"] += 1
            continue
        parsed = statement_from_context(context)
        if parsed is None:
            skipped["no_theorem_declaration"] += 1
            continue
        _, name, _ = parsed
        theory = str(item.get("theory") or path.stem)
        query_id = f"{theory}.{name}"
        if query_id not in by_id:
            skipped["query_not_in_metadata"] += 1
            continue
        commands = item.get("proof_commands")
        if not isinstance(commands, list):
            skipped["missing_proof_commands"] += 1
            continue
        for dep_name in proof_command_dependencies(commands):
            dep_id = resolve_dependency(dep_name, ids, unique_name_to_id)
            if dep_id is None:
                unresolved[(query_id, dep_name)] += 1
                continue
            if dep_id == query_id:
                skipped["self_edge"] += 1
                continue
            deps_by_query[query_id].add(dep_id)

    rows = []
    for query_id in sorted(deps_by_query):
        relevant_ids = sorted(deps_by_query[query_id])
        if not relevant_ids:
            continue
        query = by_id[query_id]
        rows.append(
            {
                "id": "dep_" + re.sub(r"[^A-Za-z0-9]+", "_", query_id).strip("_").lower(),
                "query_id": query_id,
                "query_text": theorem_text(query),
                "relevant_ids": relevant_ids,
                "source": "proof_text_facts",
            }
        )

    if not rows:
        fail("no benchmark rows with resolved non-self dependencies were found")

    write_jsonl(out_dir / "benchmark.jsonl", rows)
    unresolved_rows = [
        {"query_id": q, "dependency_name": dep, "count": count}
        for (q, dep), count in sorted(unresolved.items())
    ]
    write_jsonl(out_dir / "unresolved_dependencies.jsonl", unresolved_rows)
    (out_dir / "summary.json").write_text(
        json.dumps(
            {
                "benchmark_rows": len(rows),
                "resolved_edges": sum(len(row["relevant_ids"]) for row in rows),
                "unresolved_edges": sum(unresolved.values()),
                "skipped": dict(sorted(skipped.items())),
                "json_dir": str(json_dir),
                "metadata": str(metadata_path),
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    print(f"Wrote benchmark: {out_dir / 'benchmark.jsonl'} ({len(rows)} rows)")
    print(f"Wrote unresolved dependency report: {out_dir / 'unresolved_dependencies.jsonl'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
