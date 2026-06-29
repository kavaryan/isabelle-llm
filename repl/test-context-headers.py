#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import pathlib
import random
import subprocess
import sys
import tempfile


def load_repl_module(script_dir: pathlib.Path):
    path = script_dir / "repl-isar.py"
    spec = importlib.util.spec_from_file_location("repl_isar", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def find_header_begin(lines: list[str], repl_module) -> int | None:
    theory_seen = False
    in_ml_comment = False
    cartouche_comment_depth = 0

    for index, line in enumerate(lines):
        if cartouche_comment_depth > 0:
            cartouche_comment_depth += line.count("\\<open>") - line.count("\\<close>")
            continue

        cleaned, in_ml_comment = repl_module.strip_header_comments(line, in_ml_comment)
        comment_pos = cleaned.find("\\<comment>")
        if comment_pos != -1:
            segment = cleaned[comment_pos:]
            cartouche_comment_depth = segment.count("\\<open>") - segment.count("\\<close>")
            cleaned = cleaned[:comment_pos]

        tokens = repl_module.header_tokens(cleaned)
        if tokens and tokens[0] == "theory":
            theory_seen = True
        if theory_seen and "begin" in tokens:
            return index

    return None


def suspicious_imports(imports: list[str]) -> list[str]:
    bad_words = {"abbrevs", "keywords", "begin", "and"}
    return [
        item
        for item in imports
        if item in bad_words
        or item.startswith('"')
        or item.endswith('"')
        or item.startswith("(*")
        or item in {"<comment>", "\\<comment>"}
    ]


def main() -> int:
    script_dir = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Verify repl-isar.py CONTEXT parsing on Isabelle theory headers."
    )
    parser.add_argument(
        "root",
        nargs="?",
        help="Directory to search for .thy files. If omitted, clone mirror-isabelle and use src/HOL.",
    )
    parser.add_argument(
        "--repo-url",
        default="https://github.com/isabelle-prover/mirror-isabelle",
        help="Repository to clone when root is omitted.",
    )
    parser.add_argument("--sample", type=int, default=100, help="Number of random files to test.")
    parser.add_argument("--seed", type=int, default=20260629)
    parser.add_argument("--next-lines", type=int, default=5)
    parser.add_argument("--all", action="store_true", help="Test all .thy files instead of sampling.")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="mirror-isabelle-") as tmp:
        if args.root:
            root = pathlib.Path(args.root).expanduser().resolve()
        else:
            checkout = pathlib.Path(tmp) / "mirror-isabelle"
            print(f"cloning {args.repo_url} into {checkout}", file=sys.stderr)
            subprocess.run(
                [
                    "git",
                    "clone",
                    "--depth",
                    "1",
                    "--filter=blob:none",
                    "--sparse",
                    args.repo_url,
                    str(checkout),
                ],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(checkout), "sparse-checkout", "set", "src/HOL"],
                check=True,
            )
            root = checkout / "src" / "HOL"

        files = sorted(root.rglob("*.thy"))
        if not files:
            print(f"no .thy files found under {root}", file=sys.stderr)
            return 2

        if args.all:
            selected = files
        else:
            count = min(args.sample, len(files))
            selected = random.Random(args.seed).sample(files, count)

        repl_module = load_repl_module(script_dir)
        failures: list[tuple[str, str, object, object]] = []

        for path in selected:
            lines = path.read_text(errors="replace").splitlines()
            begin_index = find_header_begin(lines, repl_module)
            rel = str(path.relative_to(root))
            if begin_index is None:
                failures.append((rel, "missing header begin", "", ""))
                continue

            next_lines = lines[begin_index + 1 : begin_index + 1 + args.next_lines]
            context = "\n".join(lines[: begin_index + 1] + next_lines)
            imports, body = repl_module.parse_context(context)
            expected = "\n".join(next_lines).strip()
            bad_imports = suspicious_imports(imports)

            if not imports:
                failures.append((rel, "missing imports", "", body[:120]))
            elif bad_imports:
                failures.append((rel, "bad imports", bad_imports, imports[:12]))
            elif body != expected:
                failures.append((rel, "body mismatch", expected[:120], body[:120]))

        print(f"checked {len(selected)} theory headers under {root}")
        if failures:
            print(f"failures: {len(failures)}")
            for rel, reason, expected, actual in failures[:50]:
                print(f"- {rel}: {reason}")
                print(f"  expected: {expected!r}")
                print(f"  actual:   {actual!r}")
            return 1

        print("failures: 0")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
