#!/usr/bin/env python3
"""Check one GRPO completion with Isabelle in headless batch mode.

Input is one JSON object on stdin. Required fields:
  completion, source_file, source_index

The checker reconstructs a temporary theory prefix from the extractor record's
`proof_text_before`, inserts the sampled completion, appends `end`, and runs
`isabelle build` on that temporary session. Exit code 0 means the candidate
proved the extracted training goal.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify one Isabelle reward candidate.")
    parser.add_argument(
        "--extractor-json-dir",
        type=Path,
        default=Path(os.environ.get("ISABELLE_EXTRACTOR_JSON_DIR", "")),
        help="Directory containing extractor JSON files.",
    )
    parser.add_argument(
        "--isabelle",
        default=os.environ.get("ISABELLE", "isabelle"),
        help="Isabelle executable.",
    )
    parser.add_argument(
        "--logic",
        default=os.environ.get("ISABELLE_REWARD_LOGIC", "HOL"),
        help="Parent session for temporary reward checks when no theory session map is supplied.",
    )
    parser.add_argument(
        "--theory-session-map",
        type=Path,
        default=Path(os.environ.get("ISABELLE_THEORY_SESSION_MAP", "")),
        help="JSON object mapping theory names to parent Isabelle sessions.",
    )
    parser.add_argument(
        "--extra-dir",
        action="append",
        default=os.environ.get("ISABELLE_REWARD_EXTRA_DIRS", "").split(":")
        if os.environ.get("ISABELLE_REWARD_EXTRA_DIRS")
        else [],
        help="Extra -d session directory for Isabelle build. Can be repeated.",
    )
    parser.add_argument("--keep-tmp", action="store_true", help="Do not delete temporary check directory.")
    return parser.parse_args()


def load_payload() -> dict[str, Any]:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON payload: {exc}") from exc
    if not isinstance(payload, dict):
        raise SystemExit("payload must be a JSON object")
    return payload


def get_record(payload: dict[str, Any], extractor_json_dir: Path) -> dict[str, Any]:
    source_file = str(payload.get("source_file", "")).strip()
    if not source_file:
        raise SystemExit("payload missing source_file")
    try:
        source_index = int(payload["source_index"])
    except Exception as exc:
        raise SystemExit("payload missing integer source_index") from exc

    path = extractor_json_dir / source_file
    if not path.is_file():
        raise SystemExit(f"extractor source file not found: {path}")
    records = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(records, list):
        raise SystemExit(f"extractor source is not a JSON list: {path}")
    try:
        record = records[source_index]
    except IndexError as exc:
        raise SystemExit(f"source_index {source_index} out of range for {path}") from exc
    if not isinstance(record, dict):
        raise SystemExit(f"extractor record {source_file}[{source_index}] is not an object")
    return record


def theory_name_from_source(source: str) -> str:
    match = re.search(r"(?m)^\s*theory\s+([A-Za-z0-9_'.]+)\b", source)
    if not match:
        raise SystemExit("could not find theory header in proof_text_before")
    return match.group(1)


def validate_completion(text: str) -> str:
    completion = text.strip()
    if not completion:
        raise SystemExit("empty completion")
    forbidden = re.compile(r"(?i)(?<![A-Za-z0-9_'])(sorry|oops|sledgehammer|try0|nitpick|quickcheck)(?![A-Za-z0-9_'])")
    if forbidden.search(completion):
        raise SystemExit("completion contains a forbidden proof command")
    return completion


def isabelle_home_from_executable(isabelle: str) -> Path:
    executable = Path(isabelle).expanduser()
    if shutil.which(isabelle) is not None and not executable.is_file():
        executable = Path(shutil.which(isabelle) or isabelle)
    executable = executable.resolve()
    if executable.name != "isabelle" or executable.parent.name != "bin":
        raise SystemExit(f"cannot derive Isabelle home from executable path: {isabelle}")
    return executable.parent.parent


def load_isabelle_symbol_map(isabelle: str) -> dict[str, str]:
    symbols_path = isabelle_home_from_executable(isabelle) / "etc" / "symbols"
    if not symbols_path.is_file():
        raise SystemExit(f"Isabelle symbols table not found: {symbols_path}")
    symbol_map: dict[str, str] = {}
    pattern = re.compile(r"^(\\<[^>]+>)\s+code:\s+0x([0-9A-Fa-f]+)\b")
    for line in symbols_path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            char = chr(int(match.group(2), 16))
            if ord(char) >= 128:
                symbol_map[char] = match.group(1)
    return symbol_map


def normalize_isabelle_symbols(source: str, symbol_map: dict[str, str]) -> str:
    return "".join(symbol_map.get(char, char) for char in source)


STANDARD_IMPORTS = {"Main", "Complex_Main", "HOL", "Pure"}


def theory_name_from_import_token(token: str) -> str:
    name = token.strip('"')
    if "/" in name:
        name = Path(name).name
    if name.endswith(".thy"):
        name = name[:-4]
    return name


def qualify_import_token(token: str, parent_session: str) -> str:
    if token.startswith("(*") or token.startswith("--"):
        return token
    quoted = token.startswith('"') and token.endswith('"')
    name = theory_name_from_import_token(token)
    if name in STANDARD_IMPORTS or "." in name:
        return token
    qualified = f"{parent_session}.{name}"
    return json.dumps(qualified)


def qualify_imports(source: str, parent_session: str) -> str:
    match = re.search(r"(?ms)^(\s*theory\s+[A-Za-z0-9_'.]+\s+imports\s+)(.*?)(\s+begin\b)", source)
    if not match:
        return source
    imports = match.group(2)
    tokens = re.findall(r'"[^"]+"|\(\*.*?\*\)|\S+', imports, flags=re.S)
    rewritten = " ".join(qualify_import_token(token, parent_session) for token in tokens)
    return f"{source[:match.start(2)]}{rewritten}{source[match.end(2):]}"


def build_theory_source(
    record: dict[str, Any],
    completion: str,
    parent_session: str,
    symbol_map: dict[str, str],
) -> tuple[str, str]:
    proof_text_before = str(record.get("proof_text_before", ""))
    if not proof_text_before:
        raise SystemExit("extractor record missing proof_text_before")
    theory = theory_name_from_source(proof_text_before)
    qualified_prefix = qualify_imports(proof_text_before.rstrip(), parent_session)
    theory_source = f"{qualified_prefix}\n{completion}\nend\n"
    return theory, normalize_isabelle_symbols(theory_source, symbol_map)


def load_theory_session_map(path: Path) -> dict[str, str] | None:
    if not path:
        return None
    session_map_path = path.expanduser().resolve()
    if not session_map_path.is_file():
        raise SystemExit(f"theory session map not found: {session_map_path}")
    raw = json.loads(session_map_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in raw.items()):
        raise SystemExit(f"theory session map must be a JSON object of strings: {session_map_path}")
    return raw


def parent_session_for_theory(theory: str, default_logic: str, theory_session_map: dict[str, str] | None) -> str:
    if theory_session_map is None:
        return default_logic
    try:
        return theory_session_map[theory]
    except KeyError as exc:
        raise SystemExit(f"no parent session configured for theory: {theory}") from exc


def root_session_name(session: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_'.]+", session):
        return session
    return json.dumps(session)


def run_isabelle_build(args: argparse.Namespace, tmp_dir: Path, theory: str, source_session: str) -> int:
    imported_sessions = ""
    if source_session != args.logic:
        imported_sessions = f"  sessions {root_session_name(source_session)}\n"
    root = tmp_dir / "ROOT"
    root.write_text(
        f"session Reward_Check = {root_session_name(args.logic)} +\n"
        "  options [timeout = 60]\n"
        f"{imported_sessions}"
        f"  theories {theory}\n",
        encoding="utf-8",
    )
    cmd = [args.isabelle, "build"]
    for directory in args.extra_dir:
        if directory:
            cmd.extend(["-d", directory])
    cmd.extend(["-D", str(tmp_dir)])
    result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
    return result.returncode


def main() -> None:
    args = parse_args()
    if not args.extractor_json_dir:
        raise SystemExit("--extractor-json-dir or ISABELLE_EXTRACTOR_JSON_DIR is required")
    extractor_json_dir = args.extractor_json_dir.expanduser().resolve()
    if not extractor_json_dir.is_dir():
        raise SystemExit(f"extractor JSON directory not found: {extractor_json_dir}")
    if shutil.which(args.isabelle) is None and not Path(args.isabelle).expanduser().is_file():
        raise SystemExit(f"Isabelle executable not found: {args.isabelle}")
    theory_session_map = load_theory_session_map(args.theory_session_map)
    symbol_map = load_isabelle_symbol_map(args.isabelle)

    payload = load_payload()
    completion = validate_completion(str(payload.get("completion", "")))
    record = get_record(payload, extractor_json_dir)
    theory = theory_name_from_source(str(record.get("proof_text_before", "")))
    parent_session = parent_session_for_theory(theory, args.logic, theory_session_map)
    theory, theory_source = build_theory_source(record, completion, parent_session, symbol_map)

    tmp_path = Path(tempfile.mkdtemp(prefix="isabelle_reward_"))
    try:
        (tmp_path / f"{theory}.thy").write_text(theory_source, encoding="utf-8")
        raise SystemExit(run_isabelle_build(args, tmp_path, theory, parent_session))
    finally:
        if args.keep_tmp:
            print(f"kept temporary reward check directory: {tmp_path}", file=sys.stderr)
        else:
            shutil.rmtree(tmp_path)


if __name__ == "__main__":
    main()
