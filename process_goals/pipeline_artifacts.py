#!/usr/bin/env python3
"""Completion markers, joined rows, statistics, and audit metadata."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any


PHASES = (
    ("discover", "01_discover.json"),
    ("oneshot", "02_oneshot.json"),
    ("check", "03_check.json"),
    ("repair", "04_repair.json"),
)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_array(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or not all(isinstance(row, dict) for row in data):
        raise ValueError(f"{path} must contain a JSON array of objects")
    return data


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def marker_path(output: Path) -> Path:
    return output.with_name(output.name + ".complete.json")


def valid_marker(output: Path) -> bool:
    marker = marker_path(output)
    if not output.is_file() or not marker.is_file():
        return False
    try:
        metadata = json.loads(marker.read_text(encoding="utf-8"))
        rows = read_array(output)
    except (OSError, ValueError, json.JSONDecodeError):
        return False
    return (
        metadata.get("output") == output.name
        and metadata.get("sha256") == sha256(output)
        and metadata.get("records") == len(rows)
    )


def mark_complete(output: Path, phase: str) -> None:
    rows = read_array(output)
    write_json(marker_path(output), {
        "completed_at": now(),
        "output": output.name,
        "phase": phase,
        "records": len(rows),
        "sha256": sha256(output),
    })


def key(row: dict[str, Any]) -> tuple[str, int, int]:
    return str(row.get("theory", "")), int(row.get("line", 0)), int(row.get("offset", 0))


def by_key(rows: list[dict[str, Any]]) -> dict[tuple[str, int, int], dict[str, Any]]:
    result: dict[tuple[str, int, int], dict[str, Any]] = {}
    for row in rows:
        row_key = key(row)
        if row_key in result:
            raise ValueError(f"duplicate goal key: {row_key}")
        result[row_key] = row
    return result


def transcript_events(transcript: Any) -> str:
    if not isinstance(transcript, list):
        return ""
    events: list[str] = []
    for message in transcript:
        if not isinstance(message, dict):
            continue
        parts = message.get("parts")
        if isinstance(parts, list):
            for part in parts:
                events.append(json.dumps({"type": "transcript", "part": part}, ensure_ascii=False))
        else:
            events.append(json.dumps(message, ensure_ascii=False))
    return "\n".join(events)


def joined_row(
    discover: dict[str, Any],
    oneshot: dict[str, Any] | None,
    check: dict[str, Any] | None,
    repair: dict[str, Any] | None,
) -> dict[str, Any]:
    oneshot_ok = oneshot is not None and check is None and oneshot.get("status") == "extracted"
    repair_ok = repair is not None and repair.get("success") is True
    row: dict[str, Any] = {
        **discover,
        "discover": discover,
        "oneshot": oneshot,
        "check": check,
        "repair": repair,
        "question": (oneshot or {}).get("context", (repair or {}).get("context", "")),
        "answer": discover.get("answer", ""),
        "oneshot_prompt": (oneshot or {}).get("prompt", ""),
        "oneshot_response": (oneshot or {}).get("raw_response", ""),
        "oneshot_extracted_proof": (oneshot or {}).get("proof_text", ""),
        "oneshot_rollout_status": (oneshot or {}).get("status", "missing"),
        "oneshot_isabelle_ok": oneshot_ok,
        "oneshot_isabelle_error": (check or {}).get("check_error", ""),
        "oneshot_isabelle_notes": "live speculate_check_many",
        "mini_ir_prompt": (repair or {}).get("prompt", ""),
        "mini_ir_response": (repair or {}).get("adapter_final_text_hint", ""),
        "mini_ir_extracted_proof": (repair or {}).get("final_proof_text", ""),
        "mini_ir_events_jsonl": transcript_events((repair or {}).get("transcript")),
        "mini_ir_rollout_status": (repair or {}).get("status", "not_attempted"),
        "mini_ir_isabelle_ok": repair_ok,
        "mini_ir_isabelle_error": (repair or {}).get("adapter_error", ""),
        "mini_ir_isabelle_notes": "live speculate_check_many",
    }
    row["final_status"] = "oneshot_solved" if oneshot_ok else "repair_solved" if repair_ok else "unsolved"
    row["final_proof_text"] = (
        row["oneshot_extracted_proof"] if oneshot_ok else row["mini_ir_extracted_proof"] if repair_ok else ""
    )
    return row


def git_revision(root: Path) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return os.environ.get("PIPELINE_REVISION", "unknown")


def source_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    ignored = {"lib", "pipeline_out", "pipeline_smoke_out", "__pycache__"}
    for path in sorted(p for p in root.rglob("*") if p.is_file() and not ignored.intersection(p.parts)):
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode("utf-8") + b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def finalize(out_dir: Path, started_at: str, pipeline_args: list[str], source_root: Path) -> None:
    if pipeline_args[:1] == ["--"]:
        pipeline_args = pipeline_args[1:]
    loaded: dict[str, list[dict[str, Any]]] = {}
    artifacts: dict[str, Any] = {}
    for phase, filename in PHASES:
        path = out_dir / filename
        if path.exists():
            loaded[phase] = read_array(path)
            artifacts[phase] = {
                "file": filename,
                "records": len(loaded[phase]),
                "sha256": sha256(path),
                "complete": valid_marker(path),
            }
        else:
            loaded[phase] = []
            artifacts[phase] = {"file": filename, "records": 0, "missing": True, "complete": False}

    oneshot = by_key(loaded["oneshot"])
    checks = by_key(loaded["check"])
    repairs = by_key(loaded["repair"])
    rows = [joined_row(row, oneshot.get(key(row)), checks.get(key(row)), repairs.get(key(row)))
            for row in loaded["discover"]]
    joined_path = out_dir / "05_joined.json"
    write_json(joined_path, rows)

    stats = {
        "total": len(rows),
        "oneshot_solved": sum(row["final_status"] == "oneshot_solved" for row in rows),
        "oneshot_failed": sum(row["oneshot_isabelle_ok"] is not True for row in rows),
        "repair_attempted": sum(row["repair"] is not None for row in rows),
        "repair_solved": sum(row["final_status"] == "repair_solved" for row in rows),
        "unsolved": sum(row["final_status"] == "unsolved" for row in rows),
        "solved_total": sum(row["final_status"] != "unsolved" for row in rows),
    }
    stats["solve_rate"] = stats["solved_total"] / stats["total"] if stats["total"] else 0.0
    write_json(out_dir / "06_stats.json", stats)

    audit = {
        "started_at": started_at,
        "completed_at": now(),
        "hostname": socket.gethostname(),
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "pipeline_revision": git_revision(source_root),
        "pipeline_source_sha256": source_sha256(source_root),
        "pipeline_args": pipeline_args,
        "configuration": {
            name: os.environ.get(name, "") for name in (
                "ISABELLE", "IR_DIR", "ADAPTER_ONESHOT", "ADAPTER_REPAIR",
                "PROMPT_ONESHOT", "PROMPT_REPAIR", "MAX_SYMBOLS",
                "CHECK_TIMEOUT_SECS", "REPAIR_TIMEOUT_SECS", "ONESHOT_MODEL", "REPAIR_MODEL",
                "OPENCODE_API_KEY_FILE", "PIPELINE_SMOKETEST",
            )
        },
        "artifacts": artifacts,
        "joined": {"file": joined_path.name, "records": len(rows), "sha256": sha256(joined_path)},
        "statistics": stats,
    }
    write_json(out_dir / "pipeline_run.json", audit)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    valid = sub.add_parser("phase-valid")
    valid.add_argument("output", type=Path)
    mark = sub.add_parser("mark-complete")
    mark.add_argument("phase")
    mark.add_argument("output", type=Path)
    finish = sub.add_parser("finalize")
    finish.add_argument("out_dir", type=Path)
    finish.add_argument("started_at")
    finish.add_argument("source_root", type=Path)
    finish.add_argument("pipeline_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command == "phase-valid":
        raise SystemExit(0 if valid_marker(args.output) else 1)
    if args.command == "mark-complete":
        mark_complete(args.output, args.phase)
    else:
        finalize(args.out_dir, args.started_at, args.pipeline_args, args.source_root)


if __name__ == "__main__":
    main()
