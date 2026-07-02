"""Shared helpers for distillation-data pipeline scripts."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not path.exists():
        return rows
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError(f"{path}:{line_no} is not a JSON object")
            rows.append(row)
    return rows


def append_jsonl(path: Path, row: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        json.dump(row, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")


def row_key(row: dict[str, Any]) -> str:
    source_file = row.get("source_file", "")
    source_index = row.get("source_index", "")
    theory = row.get("theory", "")
    line = row.get("line", "")
    offset = row.get("offset", "")
    return f"{source_file}:{source_index}:{theory}:{line}:{offset}"


def done_keys(path: Path) -> set[str]:
    return {row_key(row) for row in read_jsonl(path)}


def extract_last_fenced_code(text: str) -> str:
    matches = re.findall(r"```(?:[^\n`]*)\n(.*?)```", text, flags=re.DOTALL)
    if not matches:
        return ""
    return matches[-1].strip()


def make_sorry_question(question: str) -> str:
    return f"{question.rstrip()}\n  sorry\n"


def build_candidate_theory(row: dict[str, Any], proof: str) -> str:
    question = str(row.get("question", "")).rstrip()
    return f"{question}\n{proof.strip()}\n"
