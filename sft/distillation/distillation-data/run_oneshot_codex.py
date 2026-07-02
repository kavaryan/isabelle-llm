#!/usr/bin/env python3
"""Run no-tool one-shot OpenCode attempts for multiline distillation rows."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile

from pathlib import Path

from distillation_common import append_jsonl, done_keys, extract_last_fenced_code, make_sorry_question, read_jsonl, row_key


OPENCODE_BIN = "/home/me/.opencode/bin/opencode"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--input", type=Path, default=here / "01_multiline_distillation.jsonl")
    parser.add_argument("--output", type=Path, default=here / "02_oneshot_rollouts.jsonl")
    parser.add_argument("--limit", type=int, help="Maximum new rows to process.")
    parser.add_argument("--model", default=os.environ.get("OPENCODE_MODEL", ""))
    parser.add_argument("--opencode-bin", default=OPENCODE_BIN)
    return parser.parse_args()


def prompt_for(row: dict) -> str:
    return f"""You are completing an Isabelle/HOL proof.

Rules:
- Do not use tools, search, shell commands, MCP, or external resources.
- Reason from the provided Isabelle theory prefix only.
- Replace the final `sorry` with a complete proof.
- If the missing proof follows a theorem/lemma statement, start with a proof
  command such as `proof`, `proof -`, or `by ...` before using proof-local
  commands like `let`, `fix`, `assume`, or `have`.
- End your answer with exactly one fenced code block containing only the replacement proof text.

Theory: {row.get("theory")}
Line: {row.get("line")}
Offset: {row.get("offset")}

Isabelle theory prefix with the missing proof marked by sorry:
```isabelle
{make_sorry_question(str(row.get("question", "")))}
```
"""


def final_message_from_opencode_events(events: str) -> str:
    text_parts: list[str] = []
    fallback_lines: list[str] = []
    for line in events.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            if line.strip():
                fallback_lines.append(line)
            continue
        candidates = [event, event.get("part"), event.get("message")]
        for candidate in candidates:
            if not isinstance(candidate, dict):
                continue
            if candidate.get("role") == "assistant" and isinstance(candidate.get("content"), str):
                text_parts.append(candidate["content"])
            if candidate.get("type") in {"text", "message"} and isinstance(candidate.get("text"), str):
                text_parts.append(candidate["text"])
    return "\n".join(text_parts).strip() or "\n".join(fallback_lines).strip()


def run_opencode(opencode_bin: str, model: str, prompt: str) -> tuple[int, str, str]:
    with tempfile.TemporaryDirectory(prefix="opencode-oneshot-") as tmp:
        cmd = [
            opencode_bin,
            "run",
            "--pure",
            "--format",
            "json",
            "--dir",
            tmp,
        ]
        if model:
            cmd.extend(["--model", model])
        cmd.append(prompt)
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        return proc.returncode, final_message_from_opencode_events(proc.stdout), proc.stdout


def main() -> None:
    args = parse_args()
    rows = read_jsonl(args.input)
    completed = done_keys(args.output)
    processed = 0
    for row in rows:
        if row_key(row) in completed:
            continue
        prompt = prompt_for(row)
        returncode, final, events = run_opencode(args.opencode_bin, args.model, prompt)
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
