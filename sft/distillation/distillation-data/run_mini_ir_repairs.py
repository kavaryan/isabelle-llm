#!/usr/bin/env python3
"""Repair failed one-shot proofs through Codex using mini_ir MCP only."""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

from distillation_common import (
    CODEX_BIN,
    append_jsonl,
    done_keys,
    extract_last_fenced_code,
    make_sorry_question,
    read_jsonl,
    row_key,
)


ALLOWED_CODEX_DISCOVERY_TOOLS = {"list_mcp_resources", "list_mcp_resource_templates"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--input", type=Path, default=here / "03_oneshot_checked.jsonl")
    parser.add_argument("--output", type=Path, default=here / "04_mini_ir_repair_rollouts.jsonl")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--model", default="gpt-5.5")
    parser.add_argument("--codex-bin", default=CODEX_BIN)
    return parser.parse_args()


def prompt_for(row: dict) -> str:
    return f"""Repair this Isabelle/HOL proof.

Rules:
- Use only the mini_ir MCP tools.
- Do not use web search.
- Do not use shell commands for proof checking.
- Do not use IQ/IR tools other than mini_ir.
- You may step through the proof interactively with mini_ir.
- End your answer with exactly one fenced code block containing only the final replacement proof text.

Theory: {row.get("theory")}
Line: {row.get("line")}
Offset: {row.get("offset")}

One-shot proof attempt:
```isabelle
{row.get("oneshot_extracted_proof", "")}
```

One-shot checker error:
```text
{row.get("oneshot_isabelle_error", "")}
{row.get("oneshot_isabelle_notes", "")}
```

Isabelle theory prefix with the missing proof marked by sorry:
```isabelle
{make_sorry_question(str(row.get("question", "")))}
```
"""


def run_codex(codex_bin: str, model: str, prompt: str) -> tuple[int, str, str]:
    with tempfile.TemporaryDirectory(prefix="codex-mini-ir-") as tmp:
        last = Path(tmp) / "last.txt"
        cmd = [
            codex_bin,
            "exec",
            "--ignore-user-config",
            "--ignore-rules",
            "--disable",
            "shell_tool",
            "-c",
            'mcp_servers.mini_ir.command="/home/me/.venv/bin/python"',
            "-c",
            'mcp_servers.mini_ir.args=["/home/me/wr/ai4math/isabelle/local-repl/repl-isar.py", "--mcp", "--host", "127.0.0.1", "--port", "9147", "--token", "local-dev-token"]',
            "--dangerously-bypass-approvals-and-sandbox",
            "--model",
            model,
            "--json",
            "--output-last-message",
            str(last),
            "-",
        ]
        proc = subprocess.run(cmd, input=prompt, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        final = last.read_text(encoding="utf-8") if last.exists() else ""
        return proc.returncode, final, proc.stdout


def policy_violations(events: str) -> list[str]:
    violations: list[str] = []
    if '"type":"command_execution"' in events:
        violations.append("shell command_execution used")
    for line in events.splitlines():
        if '"type":"mcp_tool_call"' not in line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            violations.append("unparseable MCP event: " + line[:1000])
            continue
        item = event.get("item")
        if not isinstance(item, dict) or item.get("type") != "mcp_tool_call":
            continue
        server = item.get("server")
        tool = item.get("tool")
        if server == "mini_ir":
            continue
        if server == "codex" and tool in ALLOWED_CODEX_DISCOVERY_TOOLS:
            continue
        violations.append("forbidden MCP tool call: " + line[:1000])
    return violations


def main() -> None:
    args = parse_args()
    rows = read_jsonl(args.input)
    completed = done_keys(args.output)
    processed = 0
    for row in rows:
        if row_key(row) in completed:
            continue
        if row.get("oneshot_isabelle_ok") is True:
            continue
        prompt = prompt_for(row)
        returncode, final, events = run_codex(args.codex_bin, args.model, prompt)
        proof = extract_last_fenced_code(final)
        violations = policy_violations(events)
        out = dict(row)
        out.update(
            {
                "mini_ir_prompt": prompt,
                "mini_ir_returncode": returncode,
                "mini_ir_response": final,
                "mini_ir_events_jsonl": events,
                "mini_ir_extracted_proof": proof,
                "mini_ir_policy_violations": violations,
                "mini_ir_rollout_status": (
                    "policy_violation" if violations else "extracted" if proof else "no_code_block"
                ),
            }
        )
        append_jsonl(args.output, out)
        processed += 1
        if args.limit is not None and processed >= args.limit:
            break


if __name__ == "__main__":
    main()
