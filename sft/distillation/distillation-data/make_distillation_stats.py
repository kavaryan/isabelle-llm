#!/usr/bin/env python3
"""Summarize staged distillation proof-solving results."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from distillation_common import read_jsonl, row_key


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--oneshot-checked", type=Path, default=here / "03_oneshot_checked.jsonl")
    parser.add_argument("--repair-checked", type=Path, default=here / "05_mini_ir_checked.jsonl")
    parser.add_argument("--output", type=Path, default=here / "06_distillation_stats.json")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    oneshot_rows = read_jsonl(args.oneshot_checked)
    repair_rows = read_jsonl(args.repair_checked)
    repair_by_key = {row_key(row): row for row in repair_rows}

    total = len(oneshot_rows)
    oneshot_solved = sum(1 for row in oneshot_rows if row.get("oneshot_isabelle_ok") is True)
    failed_after_oneshot = [row for row in oneshot_rows if row.get("oneshot_isabelle_ok") is not True]
    mini_ir_solved = 0
    unsolved = 0
    not_repaired = 0
    for row in failed_after_oneshot:
        repaired = repair_by_key.get(row_key(row))
        if repaired is None:
            not_repaired += 1
        elif repaired.get("mini_ir_isabelle_ok") is True:
            mini_ir_solved += 1
        else:
            unsolved += 1

    stats = {
        "total_checked": total,
        "oneshot_solved": oneshot_solved,
        "oneshot_failed": len(failed_after_oneshot),
        "mini_ir_solved_after_oneshot_failed": mini_ir_solved,
        "unsolved_after_mini_ir": unsolved,
        "not_repaired_yet": not_repaired,
        "solved_total": oneshot_solved + mini_ir_solved,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(stats, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(stats, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
