#!/usr/bin/env python3
"""Deterministically check extracted proofs with Isabelle in Docker.

Despite the historical filename, this script is not agentic and does not call
Codex.  It creates a temporary Isabelle theory from:

    row["question"] + row[proof_field] + "end"

The theory header is renamed to a unique temporary theory and same-session bare
imports are qualified from the extractor source path, e.g. ``Lattice`` becomes
``HOL-Lattice.Lattice`` for ``~~/src/HOL/Lattice/CompleteLattice.thy``.  The
temporary session is then checked inside the ``isabelle-extractor`` Docker image.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from distillation_common import append_jsonl, build_candidate_theory, done_keys, read_jsonl, row_key


DEFAULT_DOCKER_IMAGE = "isabelle-extractor"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--input", type=Path, default=here / "02_oneshot_rollouts.jsonl")
    parser.add_argument("--output", type=Path, default=here / "03_oneshot_checked.jsonl")
    parser.add_argument("--proof-field", default="oneshot_extracted_proof")
    parser.add_argument("--prefix", default="oneshot")
    parser.add_argument("--docker-image", default=DEFAULT_DOCKER_IMAGE)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--limit", type=int)
    return parser.parse_args()


def source_session(source_path: str) -> str:
    marker = "/src/HOL/"
    if source_path.startswith("~~/src/HOL/"):
        rest = source_path[len("~~/src/HOL/") :]
    elif marker in source_path:
        rest = source_path.split(marker, 1)[1]
    else:
        raise ValueError(f"cannot infer HOL session from source_path: {source_path!r}")
    parts = rest.split("/")
    if len(parts) == 1:
        return "HOL"
    return "HOL-" + parts[0]


def qualify_import(name: str, session: str) -> str:
    stripped = name.strip('"')
    if "." in stripped or stripped in {"Main", "Complex_Main", "HOL"}:
        return name
    if session == "HOL":
        return name
    return f'"{session}.{stripped}"'


def rewrite_header(text: str, new_theory: str, session: str) -> str:
    pattern = re.compile(r"^theory\s+\S+\s+imports\s+(.*?)\s+begin", flags=re.DOTALL | re.MULTILINE)
    match = pattern.search(text)
    if not match:
        raise ValueError("candidate text has no Isabelle theory header of form 'theory ... imports ... begin'")
    imports = match.group(1).split()
    rewritten_imports = " ".join(qualify_import(item, session) for item in imports)
    replacement = f"theory {new_theory} imports {rewritten_imports} begin"
    return text[: match.start()] + replacement + text[match.end() :]


def candidate_text(row: dict[str, Any], proof_field: str, theory_name: str) -> str:
    proof = str(row.get(proof_field, "")).strip()
    if not proof:
        raise ValueError(f"{proof_field} is empty")
    text = build_candidate_theory(row, proof).rstrip() + "\n\nend\n"
    session = source_session(str(row.get("source_path", "")))
    return rewrite_header(text, theory_name, session)


def check_with_docker(row: dict[str, Any], proof_field: str, docker_image: str, timeout: int) -> tuple[bool, str, str]:
    source_path = str(row.get("source_path", ""))
    session = source_session(source_path)
    digest = hashlib.sha1(row_key(row).encode("utf-8")).hexdigest()[:12]
    theory_name = f"Distill_Check_{digest}"
    try:
        text = candidate_text(row, proof_field, theory_name)
    except Exception as exc:
        return False, str(exc), ""

    with tempfile.TemporaryDirectory(prefix="isabelle-check-") as tmp:
        root = Path(tmp)
        thy_path = root / f"{theory_name}.thy"
        thy_path.write_text(text, encoding="utf-8")
        root_text = (
            f"session Distill_Check_{digest} = HOL +\n"
            f"  sessions \"{session}\"\n"
            f"  theories [document = false] {theory_name}\n"
        )
        (root / "ROOT").write_text(root_text, encoding="utf-8")
        cmd = [
            "docker",
            "run",
            "--rm",
            "-v",
            f"{root}:/check",
            "--entrypoint",
            "isabelle",
            docker_image,
            "build",
            "-D",
            "/check",
        ]
        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            output = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
            return False, f"timeout after {timeout}s", output
        return proc.returncode == 0, "" if proc.returncode == 0 else proc.stdout, proc.stdout


def main() -> None:
    args = parse_args()
    if shutil.which("docker") is None:
        raise RuntimeError("docker executable not found")
    rows = read_jsonl(args.input)
    completed = done_keys(args.output)
    processed = 0
    for row in rows:
        if row_key(row) in completed:
            continue
        ok, error, output = check_with_docker(row, args.proof_field, args.docker_image, args.timeout)
        proof = str(row.get(args.proof_field, ""))
        out = dict(row)
        out.update(
            {
                f"{args.prefix}_isabelle_ok": ok,
                f"{args.prefix}_isabelle_error": error,
                f"{args.prefix}_isabelle_notes": "docker isabelle build",
                f"{args.prefix}_check_output": output,
                f"{args.prefix}_checked_theory_text": build_candidate_theory(row, proof) if proof else "",
            }
        )
        append_jsonl(args.output, out)
        processed += 1
        if args.limit is not None and processed >= args.limit:
            break


if __name__ == "__main__":
    main()
