#!/usr/bin/env python3
"""Run no-tool one-shot Codex attempts for multiline distillation rows."""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path

from distillation_common import CODEX_BIN, append_jsonl, done_keys, extract_last_fenced_code, make_sorry_question, read_jsonl, row_key


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--input", type=Path, default=here / "01_multiline_distillation.jsonl")
    parser.add_argument("--output", type=Path, default=here / "02_oneshot_rollouts.jsonl")
    parser.add_argument("--limit", type=int, help="Maximum new rows to process.")
    parser.add_argument("--model", default="gpt-5.5")
    parser.add_argument("--codex-bin", default=CODEX_BIN)
    return parser.parse_args()


def prompt_for(row: dict) -> str:
    return f"""You are completing an Isabelle/HOL proof.

Rules:
- Do not use tools, search, shell commands, MCP, or external resources.
- Reason from the provided Isabelle theory prefix only.
- Replace the final `sorry` with a complete proof.
- End your answer with exactly one fenced code block containing only the replacement proof text.

Theory: {row.get("theory")}
Line: {row.get("line")}
Offset: {row.get("offset")}

Isabelle theory prefix with the missing proof marked by sorry:
```isabelle
{make_sorry_question(str(row.get("question", "")))}
```
"""


def run_codex(codex_bin: str, model: str, prompt: str) -> tuple[int, str, str]:
    with tempfile.TemporaryDirectory(prefix="codex-oneshot-") as tmp:
        last = Path(tmp) / "last.txt"
        cmd = [
            codex_bin,
            "exec",
            "--ignore-user-config",
            "--ignore-rules",
            "--disable",
            "shell_tool",
            "--sandbox",
            "read-only",
            "-c",
            "approval_policy=\"never\"",
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


def main() -> None:
    args = parse_args()
    rows = read_jsonl(args.input)
    completed = done_keys(args.output)
    processed = 0
    for row in rows:
        if row_key(row) in completed:
            continue
        prompt = prompt_for(row)
        returncode, final, events = run_codex(args.codex_bin, args.model, prompt)
        proof = extract_last_fenced_code(final)
        out = dict(row)
        out.update(
            {
                "oneshot_prompt": prompt,
                "oneshot_returncode": returncode,
                "oneshot_response": final,
                "oneshot_events_jsonl": events,
                "oneshot_extracted_proof": proof,
                "oneshot_rollout_status": "extracted" if proof else "no_code_block",
            }
        )
        append_jsonl(args.output, out)
        processed += 1
        if args.limit is not None and processed >= args.limit:
            break


if __name__ == "__main__":
    main()
