#!/usr/bin/env python3
"""Repair failed one-shot proofs through OpenCode using mini_ir MCP only."""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from distillation_common import (
    append_jsonl,
    done_keys,
    extract_last_fenced_code,
    read_jsonl,
    row_key,
)


OPENCODE_BIN = "/home/me/.opencode/bin/opencode"
MINI_IR_REPL = "/home/me/wr/ai4math/copilots-isabelle/isabelle-llm/repl/repl-isar.py"
MINI_IR_CONTEXT_FILE_VAR = "MINI_IR_CONTEXT_FILE"
SENTINEL = "<<DONE>>"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--input", type=Path, default=here / "03_oneshot_checked.jsonl")
    parser.add_argument("--output", type=Path, default=here / "04_mini_ir_repair_rollouts.jsonl")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--model", default=os.environ.get("OPENCODE_MODEL", ""))
    parser.add_argument("--opencode-bin", default=OPENCODE_BIN)
    parser.add_argument("--opencode-timeout", type=int, default=int(os.environ.get("OPENCODE_TIMEOUT", "240")))
    return parser.parse_args()


def prompt_for(row: dict) -> str:
    return f"""Repair this Isabelle/HOL proof.

Rules:
- Use only the mini_ir MCP tools.
- Do not use web search.
- Do not use shell commands, filesystem reads, or filesystem writes.
- Do not use IQ/IR tools or MCP servers other than mini_ir.
- The mini_ir session is already initialized at the declaration statement shown below. Start by stepping candidate proof text directly.
- You may step through the proof interactively with mini_ir.
- For mini_ir.find_theorems, exact theorem names require `name: fact_name`.
  A bare query like `le_antisym` is a statement/content search and can return 0
  even when `step` with `thm le_antisym` succeeds. For exact lookup, use
  `step` with `thm fact_name`; for name search, use `find_theorems` with
  `name: le_antisym`, `name: partial_order`, etc.
- Do not repeat the theorem/lemma/corollary/proposition statement in your final code block.
- End your answer with exactly one fenced code block containing only the replacement proof text that comes after the already-loaded statement.

Isabelle source prefix loaded before the proof:
```isabelle
{context_for(row).rstrip()}
```

One-shot proof attempt:
```isabelle
{row.get("oneshot_extracted_proof", "")}
```

One-shot checker error:
```text
{row.get("oneshot_isabelle_error", "")}
{row.get("oneshot_isabelle_notes", "")}
```
"""


def context_for(row: dict) -> str:
    """Return the source prefix ending at the declaration statement before proof."""
    return str(row.get("question", "")).rstrip() + "\n"


def context_file_for(row: dict) -> str:
    source = str(row.get("resolved_source_path") or row.get("source_path") or "").strip()
    question = str(row.get("question", "")).rstrip()
    line = len(question.splitlines()) if question else row.get("line")
    if not source or line in (None, ""):
        raise ValueError("row is missing resolved_source_path/source_path or line")
    return f"{source}:{int(line)}"


def ml_str(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def output_text(value) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return ""


def run_opencode(
    opencode_bin: str,
    model: str,
    prompt: str,
    context_file: str,
    timeout: int,
) -> tuple[int, str, str, str, str, str]:
    with tempfile.TemporaryDirectory(prefix="opencode-mini-ir-") as tmp:
        cmd = [
            opencode_bin,
            "run",
            "--pure",
            "--thinking",
            "--format",
            "json",
            "--dir",
            tmp,
        ]
        if model:
            cmd.extend(["--model", model])
        cmd.append(prompt)
        env = os.environ.copy()
        env.pop("MINI_IR_CONTEXT", None)
        env.pop("MINI_IR_CONTEXT_TEXT", None)
        env[MINI_IR_CONTEXT_FILE_VAR] = context_file
        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                env=env,
                check=False,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            output = output_text(exc.stdout)
            stderr = output_text(exc.stderr)
            if stderr:
                output += "\n" + stderr
            output += f"\nOpenCode repair timed out after {timeout}s\n"
            session_id = opencode_session_id(output)
            return 124, final_message_from_opencode_events(output), output, session_id, "", ""
        session_id = opencode_session_id(proc.stdout)
        export_json = ""
        export_error = ""
        if session_id:
            try:
                export_json = export_opencode_session(opencode_bin, session_id)
            except Exception as exc:
                export_error = str(exc)
        final = final_message_from_opencode_export(export_json) or final_message_from_opencode_events(proc.stdout)
        return proc.returncode, final, proc.stdout, session_id, export_json, export_error


def _recv_line(sock: socket.socket) -> str:
    data = b""
    while b"\n" not in data:
        chunk = sock.recv(1024)
        if not chunk:
            raise RuntimeError("connection closed during authentication")
        data += chunk
    line, _rest = data.split(b"\n", 1)
    return line.decode("utf-8", errors="replace")


def _recv_until_done(sock: socket.socket) -> str:
    data = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("connection closed before command completed")
        data += chunk
        text = data.decode("utf-8", errors="replace")
        if SENTINEL in text:
            return text[: text.index(SENTINEL)].strip()


def ir_send(command: str, timeout: float = 120.0) -> tuple[str, bool]:
    host = os.environ.get("IR_REPL_HOST", "127.0.0.1")
    port = int(os.environ.get("IR_REPL_PORT", "9147"))
    token = os.environ.get("IR_AUTH_TOKEN", "local-dev-token")
    if not command.startswith("/") and not command.endswith(";"):
        command += ";"
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((token + "\n").encode("utf-8"))
        auth = _recv_line(sock)
        if auth.strip() != "OK":
            raise RuntimeError("mini_ir backend authentication failed")
        sock.sendall((command + "\n").encode("utf-8"))
        response = _recv_until_done(sock)
    had_error = response.startswith("ERR\n")
    if had_error:
        response = response[4:].strip()
    return response, had_error


def preflight_context_file(context_file: str) -> tuple[bool, str, str]:
    path, sep, line_text = context_file.rpartition(":")
    if not sep or not path or not line_text.isdigit():
        return False, "", f"bad MINI_IR_CONTEXT_FILE: {context_file}"
    resolved, had_error = ir_send(f'/resolve "{path}" {int(line_text)}')
    if had_error:
        return False, "", resolved
    spec = resolved.strip()
    if (
        not spec
        or spec.startswith("No ")
        or spec.startswith("Cannot ")
        or spec.startswith("Usage")
        or "\n" in spec
    ):
        return False, spec, spec
    repl_id = f"MiniIrPreflight_{os.getpid()}_{int(time.time() * 1000)}"
    init_output, init_error = ir_send(f"Ir.init {ml_str(repl_id)} [{ml_str(spec)}];")
    try:
        ir_send(f"Ir.remove {ml_str(repl_id)};", timeout=30.0)
    except Exception:
        pass
    if init_error:
        return False, spec, init_output
    return True, spec, init_output


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


def opencode_session_id(events: str) -> str:
    for line in events.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        session_id = event.get("sessionID")
        if isinstance(session_id, str) and session_id:
            return session_id
    return ""


def export_opencode_session(opencode_bin: str, session_id: str) -> str:
    proc = subprocess.run(
        [opencode_bin, "export", session_id],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    text = proc.stdout.strip()
    if not text:
        return ""
    json.loads(text)
    return text


def opencode_export_messages(export_json: str) -> list[dict]:
    if not export_json:
        return []
    try:
        data = json.loads(export_json)
    except json.JSONDecodeError:
        return []
    messages = data.get("messages")
    return messages if isinstance(messages, list) else []


def final_message_from_opencode_export(export_json: str) -> str:
    text_parts: list[str] = []
    for message in opencode_export_messages(export_json):
        info = message.get("info") if isinstance(message, dict) else None
        if not isinstance(info, dict) or info.get("role") != "assistant":
            continue
        for part in message.get("parts", []):
            if isinstance(part, dict) and part.get("type") == "text" and not part.get("synthetic"):
                text = part.get("text")
                if isinstance(text, str):
                    text_parts.append(text)
    return "\n".join(text_parts).strip()


def _part_text(event: dict, part_type: str) -> str:
    part = event.get("part")
    if isinstance(part, dict) and part.get("type") == part_type:
        return str(part.get("text", ""))
    return ""


def _tool_block(event: dict) -> tuple[str, str]:
    part = event.get("part")
    if not isinstance(part, dict) or part.get("type") != "tool":
        return "", ""
    title = str(part.get("tool", "tool"))
    state = part.get("state")
    if isinstance(state, dict) and state.get("status"):
        title += f" {state.get('status')}"
    chunks = []
    if isinstance(state, dict):
        if "input" in state:
            chunks.append("input:\n" + json.dumps(state["input"], ensure_ascii=False, indent=2))
        if state.get("output"):
            chunks.append("output:\n" + str(state["output"]))
        if state.get("error"):
            chunks.append("error:\n" + str(state["error"]))
    return title, "\n\n".join(chunks)


def _step_summary(event: dict) -> str:
    part = event.get("part")
    if not isinstance(part, dict) or part.get("type") != "step-finish":
        return ""
    fields = []
    if part.get("reason"):
        fields.append(f"reason: {part.get('reason')}")
    tokens = part.get("tokens")
    if isinstance(tokens, dict):
        for key in ("input", "output", "reasoning", "total"):
            if key in tokens:
                fields.append(f"{key}: {tokens[key]}")
    return "\n".join(fields)


def opencode_transcript_markdown(events: str) -> str:
    sections = []
    for line_no, line in enumerate(events.splitlines(), start=1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            if line.strip():
                sections.append(f"## Raw line {line_no}\n\n```text\n{line}\n```")
            continue
        reasoning = _part_text(event, "reasoning")
        if reasoning:
            sections.append(f"## Reasoning\n\n{reasoning}")
            continue
        text = _part_text(event, "text")
        if text:
            sections.append(f"## Assistant text\n\n{text}")
            continue
        title, body = _tool_block(event)
        if title:
            sections.append(f"## Tool: {title}\n\n```text\n{body}\n```")
            continue
        summary = _step_summary(event)
        if summary:
            sections.append(f"## Step summary\n\n```text\n{summary}\n```")
    return "\n\n".join(sections)


def opencode_export_transcript_markdown(export_json: str) -> str:
    sections = []
    for message_index, message in enumerate(opencode_export_messages(export_json), start=1):
        if not isinstance(message, dict):
            continue
        info = message.get("info") if isinstance(message.get("info"), dict) else {}
        role = info.get("role", "message")
        for part in message.get("parts", []):
            if not isinstance(part, dict):
                continue
            part_type = part.get("type")
            if part_type == "text":
                text = str(part.get("text", ""))
                if text:
                    sections.append(f"## {role} text {message_index}\n\n{text}")
            elif part_type == "reasoning":
                text = str(part.get("text", ""))
                if text:
                    sections.append(f"## Reasoning {message_index}\n\n{text}")
            elif part_type == "tool":
                tool = str(part.get("tool", "tool"))
                state = part.get("state") if isinstance(part.get("state"), dict) else {}
                title = tool
                if state.get("status"):
                    title += f" {state.get('status')}"
                chunks = []
                if "input" in state:
                    chunks.append("input:\n" + json.dumps(state["input"], ensure_ascii=False, indent=2))
                if state.get("output"):
                    chunks.append("output:\n" + str(state["output"]))
                if state.get("error"):
                    chunks.append("error:\n" + str(state["error"]))
                metadata = state.get("metadata")
                if isinstance(metadata, dict):
                    if metadata.get("truncated") is not None:
                        chunks.append("metadata:\n" + json.dumps(metadata, ensure_ascii=False, indent=2))
                sections.append(f"## Tool: {title}\n\n```text\n{chr(10).join(chunks)}\n```")
            elif part_type == "step-finish":
                tokens = part.get("tokens") if isinstance(part.get("tokens"), dict) else {}
                fields = []
                if part.get("reason"):
                    fields.append(f"reason: {part.get('reason')}")
                for key in ("input", "output", "reasoning", "total"):
                    if key in tokens:
                        fields.append(f"{key}: {tokens[key]}")
                if fields:
                    sections.append(f"## Step summary {message_index}\n\n```text\n{chr(10).join(fields)}\n```")
    return "\n\n".join(sections)


def normalize_replacement_proof(proof: str) -> str:
    proof = proof.strip()
    if not proof:
        return ""
    declaration_prefixes = (
        "theorem ",
        "lemma ",
        "corollary ",
        "proposition ",
        "schematic_goal ",
        "interpretation ",
    )
    if not proof.lstrip().startswith(declaration_prefixes):
        return proof
    proof_starters = (
        "proof",
        "by ",
        "using ",
        "unfolding ",
        "apply ",
        "done",
        "sorry",
    )
    lines = proof.splitlines()
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(proof_starters):
            return "\n".join(lines[idx:]).strip()
    return proof


def policy_violations(events: str) -> list[str]:
    violations: list[str] = []
    forbidden_names = {"bash", "read", "write", "edit", "patch", "glob", "grep"}
    for line in events.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        blob = json.dumps(event, ensure_ascii=False)
        if "tool" not in blob.lower():
            continue
        names = {
            str(event.get("tool", "")),
            str(event.get("name", "")),
            str(event.get("server", "")),
        }
        for key in ("tool", "call", "part", "message"):
            value = event.get(key)
            if isinstance(value, dict):
                names.update(str(value.get(name, "")) for name in ("tool", "name", "server"))
        names.discard("")
        if names & forbidden_names:
            violations.append("forbidden OpenCode tool call: " + line[:1000])
        if names and "mini_ir" not in names and not any(name.startswith("mini_ir") for name in names):
            if not (names & forbidden_names):
                violations.append("non-mini_ir tool call: " + line[:1000])
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
        context = context_for(row)
        try:
            context_file = context_file_for(row)
        except Exception as exc:
            context_file = ""
            preflight_ok = False
            preflight_spec = ""
            preflight_message = str(exc)
        else:
            preflight_ok, preflight_spec, preflight_message = preflight_context_file(context_file)
        if not preflight_ok:
            msg = (
                "MINI_IR_CONTEXT_FILE PREFLIGHT FAILED LOUDLY: "
                f"{context_file or '<missing>'}: {preflight_message}"
            )
            print(msg, file=sys.stderr)
            raise SystemExit(1)
        prompt = prompt_for(row)
        returncode, final, events, session_id, export_json, export_error = run_opencode(
            args.opencode_bin,
            args.model,
            prompt,
            context_file,
            args.opencode_timeout,
        )
        transcript = opencode_export_transcript_markdown(export_json) or opencode_transcript_markdown(events)
        raw_proof = extract_last_fenced_code(final)
        proof = normalize_replacement_proof(raw_proof)
        violations = policy_violations(events)
        out = dict(row)
        out.update(
            {
                "mini_ir_prompt": prompt,
                "mini_ir_prompt_context": context,
                "mini_ir_context_file": context_file,
                "mini_ir_context_env_var": "",
                "mini_ir_context_file_env_var": MINI_IR_CONTEXT_FILE_VAR,
                "mini_ir_prompt_context_chars": len(context),
                "mini_ir_context_file_preflight_ok": True,
                "mini_ir_context_file_preflight_spec": preflight_spec,
                "mini_ir_context_file_preflight_output": preflight_message,
                "mini_ir_returncode": returncode,
                "mini_ir_response": final,
                "mini_ir_events_jsonl": events,
                "mini_ir_opencode_session_id": session_id,
                "mini_ir_opencode_export_json": export_json,
                "mini_ir_opencode_export_error": export_error,
                "mini_ir_opencode_transcript_source": "export" if export_json else "run_events",
                "mini_ir_transcript_markdown": transcript,
                "mini_ir_raw_extracted_proof": raw_proof,
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
