#!/usr/bin/env python3
"""Prepare multiline proof-block distillation rows from extractor JSON.

Rows are sourced from the same Docker image used by the extractor.  In
particular, extractor paths like ``~~/src/HOL/Library/FuncSet.thy`` are read
from ``isabelle-extractor:/home/isabelle/Isabelle/src/HOL/Library/FuncSet.thy``.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any


DEFAULT_DOCKER_IMAGE = "isabelle-extractor"
DEFAULT_DOCKER_ISABELLE_HOME = Path("/home/isabelle/Isabelle")
DEFAULT_SANITY_SOURCE_PATH = "~~/src/HOL/Library/FuncSet.thy"
DEFAULT_SMOKE_SOURCE_PATH = "~~/src/HOL/Lattice/CompleteLattice.thy"
DEFAULT_SMOKE_LINE = 118
DEFAULT_SMOKE_OFFSET = 3374
DEFAULT_SMOKE_SOURCE_INDEX = 17


def repo_relative(path: str) -> Path:
    return Path(__file__).resolve().parents[3] / path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input-dir",
        type=Path,
        default=repo_relative("extractor/proof_extractor_out/json"),
        help="Directory containing extractor JSON files.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent / "01_multiline_distillation.jsonl",
        help="Output JSONL path.",
    )
    parser.add_argument("--limit", type=int, help="Keep only the first N rows, for smoke tests.")
    parser.add_argument(
        "--known-hard-smoke-row",
        action="store_true",
        help="Keep the known CompleteLattice row whose one-shot rollout previously failed.",
    )
    parser.add_argument("--docker-image", default=DEFAULT_DOCKER_IMAGE)
    parser.add_argument("--docker-isabelle-home", type=Path, default=DEFAULT_DOCKER_ISABELLE_HOME)
    parser.add_argument("--sanity-source-path", default=DEFAULT_SANITY_SOURCE_PATH)
    return parser.parse_args()


def is_known_hard_smoke_row(record: dict[str, Any], source_index: int) -> bool:
    return (
        record.get("source_path") == DEFAULT_SMOKE_SOURCE_PATH
        and record.get("line") == DEFAULT_SMOKE_LINE
        and record.get("offset") == DEFAULT_SMOKE_OFFSET
        and source_index == DEFAULT_SMOKE_SOURCE_INDEX
    )


def load_records(input_dir: Path, limit: int | None, known_hard_smoke_row: bool) -> list[dict[str, Any]]:
    if not input_dir.is_dir():
        raise FileNotFoundError(f"extractor JSON directory does not exist: {input_dir}")
    rows: list[dict[str, Any]] = []
    for path in sorted(input_dir.glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, list):
            raise ValueError(f"{path} must contain a JSON list")
        for index, record in enumerate(payload):
            if not isinstance(record, dict):
                raise ValueError(f"{path}[{index}] must be a JSON object")
            proof_block = record.get("proof_block")
            if isinstance(proof_block, str) and "\n" in proof_block:
                if known_hard_smoke_row and not is_known_hard_smoke_row(record, index):
                    continue
                row = dict(record)
                row["_source_file"] = path.name
                row["_source_index"] = index
                rows.append(row)
                if limit is not None and len(rows) >= limit:
                    return rows
    if known_hard_smoke_row and not rows:
        raise ValueError(
            "known hard smoke row was not found: "
            f"source_path={DEFAULT_SMOKE_SOURCE_PATH!r}, "
            f"line={DEFAULT_SMOKE_LINE}, offset={DEFAULT_SMOKE_OFFSET}, "
            f"source_index={DEFAULT_SMOKE_SOURCE_INDEX}"
        )
    return rows


def docker_path(source_path: str, docker_isabelle_home: Path) -> Path:
    if not source_path:
        raise ValueError("record is missing source_path")
    if source_path.startswith("~~/"):
        return docker_isabelle_home / source_path[3:]
    path = Path(source_path)
    if path.is_absolute():
        return path
    raise ValueError(f"unsupported non-absolute source_path: {source_path!r}")


def run_quiet(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)


def check_source_exists(image: str, path: Path) -> None:
    result = run_quiet(["docker", "run", "--rm", "--entrypoint", "test", image, "-f", path.as_posix()])
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise FileNotFoundError(f"source file not found in Docker image {image}: {path}: {detail}")


class DockerSourceReader:
    def __init__(self, image: str, docker_isabelle_home: Path) -> None:
        self.image = image
        self.docker_isabelle_home = docker_isabelle_home
        self._tmpdir = tempfile.TemporaryDirectory(prefix="isabelle-sources-")
        self._container_id: str | None = None
        self._cache: dict[Path, str] = {}

    def __enter__(self) -> "DockerSourceReader":
        result = run_quiet(["docker", "create", "--entrypoint", "sh", self.image, "-c", "sleep infinity"])
        if result.returncode != 0:
            raise RuntimeError(f"failed to create container from {self.image}: {result.stderr.strip()}")
        self._container_id = result.stdout.strip()
        if not self._container_id:
            raise RuntimeError("docker create returned an empty container id")
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        if self._container_id:
            subprocess.run(["docker", "rm", "-f", self._container_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self._container_id = None
        self._tmpdir.cleanup()

    def read(self, source_path: str) -> tuple[Path, str]:
        path = docker_path(source_path, self.docker_isabelle_home)
        if path in self._cache:
            return path, self._cache[path]
        if self._container_id is None:
            raise RuntimeError("DockerSourceReader must be used as a context manager")
        local = Path(self._tmpdir.name) / path.relative_to("/")
        local.parent.mkdir(parents=True, exist_ok=True)
        result = run_quiet(["docker", "cp", f"{self._container_id}:{path.as_posix()}", str(local)])
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip()
            raise FileNotFoundError(f"failed to copy {path} from Docker image {self.image}: {detail}")
        text = local.read_text(encoding="utf-8")
        self._cache[path] = text
        return path, text


def raw_index_from_isabelle_offset(source: str, offset: int) -> int:
    if offset <= 1:
        return 0
    symbol_count = 1
    raw_index = 0
    while raw_index < len(source) and symbol_count < offset:
        if source.startswith("\\<", raw_index):
            close = source.find(">", raw_index + 2)
            raw_index = close + 1 if close != -1 else raw_index + 1
        else:
            raw_index += 1
        symbol_count += 1
    return raw_index


def require_record(record: dict[str, Any]) -> tuple[str, int, int, str, str, Any]:
    source_file = record["_source_file"]
    source_index = record["_source_index"]
    theory = record.get("theory")
    line = record.get("line")
    offset = record.get("offset")
    proof_block = record.get("proof_block")
    source_path = record.get("source_path")
    if not isinstance(theory, str) or not theory:
        raise ValueError(f"{source_file}[{source_index}] missing string theory")
    if not isinstance(line, int):
        raise ValueError(f"{source_file}[{source_index}] missing integer line")
    if not isinstance(offset, int):
        raise ValueError(f"{source_file}[{source_index}] missing integer offset")
    if not isinstance(proof_block, str):
        raise ValueError(f"{source_file}[{source_index}] missing string proof_block")
    if not isinstance(source_path, str) or not source_path:
        raise ValueError(f"{source_file}[{source_index}] missing string source_path")
    return theory, line, offset, proof_block, source_path, record.get("is_leaf")


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            json.dump(row, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")


def main() -> None:
    args = parse_args()
    if shutil.which("docker") is None:
        raise RuntimeError("docker executable not found")
    input_dir = args.input_dir.expanduser().resolve()
    output = args.output.expanduser().resolve()
    sanity_path = docker_path(args.sanity_source_path, args.docker_isabelle_home)
    check_source_exists(args.docker_image, sanity_path)

    records = load_records(input_dir, args.limit, args.known_hard_smoke_row)
    if not records:
        raise ValueError(f"no records with multiline proof_block found in {input_dir}")

    examples: list[dict[str, Any]] = []
    with DockerSourceReader(args.docker_image, args.docker_isabelle_home) as reader:
        for record in records:
            theory, line, offset, proof_block, source_path, is_leaf = require_record(record)
            resolved_source_path, source = reader.read(source_path)
            question = source[: raw_index_from_isabelle_offset(source, offset)]
            examples.append(
                {
                    "question": question,
                    "answer": proof_block,
                    "theory": theory,
                    "line": line,
                    "offset": offset,
                    "is_leaf": is_leaf,
                    "source_path": source_path,
                    "resolved_source_path": str(resolved_source_path),
                    "source_file": record["_source_file"],
                    "source_index": record["_source_index"],
                }
            )

    write_jsonl(output, examples)
    output.with_suffix(".dataset_info.json").write_text(
        json.dumps(
            {
                "input_dir": str(input_dir),
                "output": str(output),
                "docker_image": args.docker_image,
                "docker_isabelle_home": str(args.docker_isabelle_home),
                "sanity_source_path": args.sanity_source_path,
                "num_examples": len(examples),
                "filter": "proof_block contains newline",
                "format": "jsonl",
                "split": None,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
