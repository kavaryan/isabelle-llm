#!/usr/bin/env python3
"""Serve a browser UI for old rollout JSONL or process_goals joined JSON."""

from __future__ import annotations

import argparse
import html
import json
import re
import socketserver
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jsonl", type=Path, help="rollout JSONL or 05_joined.json")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8769)
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--check", action="store_true", help="parse and render every row, then exit")
    return parser.parse_args()


def read_rows(path: Path) -> list[dict]:
    text = path.read_text(encoding="utf-8")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = None
    if isinstance(payload, list):
        if not all(isinstance(row, dict) for row in payload):
            raise ValueError(f"{path} JSON array must contain objects")
        return [dict(row, _line_no=index) for index, row in enumerate(payload, start=1)]
    rows: list[dict] = []
    for line_no, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        row["_line_no"] = line_no
        rows.append(row)
    return rows


def parse_events(text: str) -> list[dict]:
    events: list[dict] = []
    for line_no, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            event = {"type": "raw", "line_no": line_no, "text": line}
        events.append(event)
    return events


def esc(value) -> str:
    return html.escape("" if value is None else str(value))


def visible_whitespace(text: str) -> str:
    parts: list[str] = []
    for char in text:
        if char == " ":
            parts.append('<span class="ws-space">·</span>')
        elif char == "\t":
            parts.append('<span class="ws-tab">⇥</span>')
        elif char == "\r":
            parts.append('<span class="ws-cr">␍</span>')
        elif char == "\n":
            parts.append("\n")
        else:
            parts.append(esc(char))
    return "".join(parts)


def code_block(label: str, text: str, lang: str = "text", show_ws: bool = False) -> str:
    body = visible_whitespace(text) if show_ws else esc(text)
    classes = f"language-{esc(lang)}" + (" show-ws" if show_ws else "")
    return f"""
    <div class="code-label">{esc(label)}</div>
    <pre class="{classes}">{body}</pre>
    """


def strip_fenced_text(text: str) -> str:
    stripped = text.strip()
    if not stripped.startswith("```"):
        return stripped
    lines = stripped.splitlines()
    if lines and lines[0].startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    return "\n".join(lines).strip()


def parse_tool_chunks(body: str) -> dict[str, str]:
    text = strip_fenced_text(body)
    matches = list(re.finditer(r"(?m)^(input|output|error):\s*$", text))
    chunks: dict[str, str] = {}
    for idx, match in enumerate(matches):
        start = match.end()
        stop = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
        chunks[match.group(1)] = text[start:stop].strip()
    return chunks


def maybe_json(text: str):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def render_tool_input(tool: str, text: str) -> str:
    parsed = maybe_json(text)
    if isinstance(parsed, dict):
        if "step" in tool and isinstance(parsed.get("isar_text"), str):
            return code_block("input · isar_text", parsed["isar_text"], "isabelle")
        if "find_theorems" in tool and isinstance(parsed.get("query"), str):
            bits = [f"query: {parsed['query']}"]
            if "limit" in parsed:
                bits.append(f"limit: {parsed['limit']}")
            return code_block("input", "\n".join(bits))
        if "back" in tool and not parsed:
            return code_block("input", "(no arguments)")
        return code_block("input", json.dumps(parsed, ensure_ascii=False, indent=2), "json")
    return code_block("input", text)


def render_tool_output(label: str, text: str) -> str:
    parsed = maybe_json(text)
    if isinstance(parsed, dict) and isinstance(parsed.get("result"), str):
        return code_block(label, parsed["result"], show_ws=True)
    if parsed is not None:
        return code_block(label, json.dumps(parsed, ensure_ascii=False, indent=2), "json", show_ws=True)
    return code_block(label, text, show_ws=True)


def render_tool_markdown_body(title: str, body: str) -> str:
    tool = title.removeprefix("Tool:").strip().lower()
    chunks = parse_tool_chunks(body)
    if not chunks:
        return code_block("body", strip_fenced_text(body))
    rendered = []
    if "input" in chunks:
        rendered.append(render_tool_input(tool, chunks["input"]))
    if "output" in chunks:
        rendered.append(render_tool_output("output", chunks["output"]))
    if "error" in chunks:
        rendered.append(render_tool_output("error", chunks["error"]))
    return "\n".join(rendered)


def event_title(event: dict) -> str:
    part = event.get("part")
    if isinstance(part, dict) and part.get("type") == "tool":
        tool = part.get("tool", "tool")
        state = part.get("state")
        status = state.get("status") if isinstance(state, dict) else ""
        return f"{tool} {status}".strip()
    return str(event.get("type", "event"))


def event_body(event: dict) -> str:
    part = event.get("part")
    if isinstance(part, dict) and part.get("type") == "tool":
        state = part.get("state")
        if isinstance(state, dict):
            chunks = []
            if "input" in state:
                chunks.append(("input", json.dumps(state["input"], ensure_ascii=False, indent=2)))
            if state.get("output"):
                chunks.append(("output", str(state["output"])))
            if state.get("error"):
                chunks.append(("error", str(state["error"])))
            if chunks:
                return "\n\n".join(f"{name}:\n{text}" for name, text in chunks)
    if event.get("type") == "raw":
        return str(event.get("text", ""))
    return json.dumps(event, ensure_ascii=False, indent=2)


def render_event_cards(events: list[dict]) -> str:
    cards = []
    for event in events:
        title = event_title(event)
        body = event_body(event)
        kind = "tool" if "mini_ir" in title or title.startswith("tool") else "event"
        if "error" in body.lower() or title.endswith("error"):
            kind += " error"
        cards.append(
            f"""
            <section class="event {kind}">
              <div class="event-title">{esc(title)}</div>
              <pre>{esc(body)}</pre>
            </section>
            """
        )
    if not cards:
        return '<section class="event"><div class="event-title">none</div><pre>No events</pre></section>'
    return "".join(cards)


def visible_text(event: dict) -> str:
    part = event.get("part")
    if isinstance(part, dict) and part.get("type") == "text":
        return str(part.get("text", ""))
    if event.get("type") == "text" and isinstance(event.get("text"), str):
        return str(event.get("text", ""))
    return ""


def finish_summary(event: dict) -> str:
    part = event.get("part")
    if not isinstance(part, dict) or part.get("type") != "step-finish":
        return ""
    tokens = part.get("tokens")
    fields = []
    if isinstance(tokens, dict):
        for key in ("input", "output", "reasoning", "total"):
            if key in tokens:
                fields.append(f"{key}: {tokens[key]}")
    reason = part.get("reason")
    if reason:
        fields.insert(0, f"reason: {reason}")
    return "\n".join(fields)


def render_transcript(events: list[dict]) -> str:
    blocks = []
    pending_text: list[str] = []
    step_no = 0
    for event in events:
        part = event.get("part")
        text = visible_text(event)
        if text:
            pending_text.append(text)
            blocks.append(
                f"""
                <section class="event assistant">
                  <div class="event-title">assistant text</div>
                  <pre>{esc(text)}</pre>
                </section>
                """
            )
            continue
        if isinstance(part, dict) and part.get("type") == "tool":
            step_no += 1
            title = event_title(event)
            body = event_body(event)
            preface = ""
            if not pending_text:
                preface = (
                    '<div class="event-note">'
                    "No visible assistant text was emitted before this tool call. "
                    "OpenCode reports hidden reasoning only as token counts."
                    "</div>"
                )
            pending_text.clear()
            kind = "tool"
            if "error" in body.lower() or title.endswith("error"):
                kind += " error"
            blocks.append(
                f"""
                <section class="event {kind}">
                  <div class="event-title">{step_no}. {esc(title)}</div>
                  {preface}
                  <pre>{esc(body)}</pre>
                </section>
                """
            )
            continue
        summary = finish_summary(event)
        if summary:
            blocks.append(
                f"""
                <section class="event meta">
                  <div class="event-title">step summary</div>
                  <pre>{esc(summary)}</pre>
                </section>
                """
            )
    if not blocks:
        return '<section class="event"><div class="event-title">none</div><pre>No events</pre></section>'
    return "".join(blocks)


def transcript_sections(markdown: str) -> list[tuple[str, str, str]]:
    sections: list[tuple[str, str, str]] = []
    title = "Transcript"
    body: list[str] = []
    section_no = 0
    reasoning_no = 0

    def add_section(raw_title: str, raw_body: list[str]) -> None:
        nonlocal section_no, reasoning_no
        clean_title = raw_title.strip() or "Transcript"
        if clean_title.lower() == "step summary":
            return
        if clean_title.lower() == "reasoning":
            reasoning_no += 1
            clean_title = f"Reasoning {reasoning_no}"
        section_no += 1
        sections.append((f"step4-transcript-{section_no}", clean_title, "\n".join(raw_body).strip()))

    for line in markdown.splitlines():
        if line.startswith("## "):
            if body or section_no:
                add_section(title, body)
            title = line[3:].strip() or f"Section {section_no}"
            body = []
        else:
            body.append(line)
    if body or section_no:
        add_section(title, body)
    return sections


def render_transcript_markdown(markdown: str) -> str:
    sections = transcript_sections(markdown)
    if not sections:
        return "<pre></pre>"
    blocks = []
    for section_id, title, body in sections:
        kind = "transcript-section"
        lowered_title = title.lower()
        if lowered_title.startswith("tool:"):
            kind += " tool"
            if lowered_title.endswith(" error") or " error" in lowered_title:
                kind += " error"
            elif lowered_title.endswith(" completed") or " completed" in lowered_title:
                kind += " completed"
        body_html = (
            render_tool_markdown_body(title, body)
            if title.startswith("Tool:")
            else f"<pre>{esc(body)}</pre>"
        )
        blocks.append(
            f"""
            <section class="event {esc(kind)}" id="{esc(section_id)}">
              <div class="event-title">{esc(title)}</div>
              {body_html}
            </section>
            """
        )
    return "".join(blocks)


def render_transcript_toc(markdown: str) -> str:
    links = []
    for section_id, title, _body in transcript_sections(markdown):
        links.append(f'<a class="sub sub2" href="#{esc(section_id)}">{esc(title)}</a>')
    return "\n".join(links)


def render_row(row: dict, idx: int, total: int, filename: str) -> str:
    oneshot_events = parse_events(str(row.get("oneshot_events_jsonl", "")))
    repair_events = parse_events(str(row.get("mini_ir_events_jsonl", "")))
    oneshot_cards = render_event_cards(oneshot_events)
    repair_cards = render_transcript(repair_events)
    repair_transcript = row.get("mini_ir_transcript_markdown")
    repair_transcript_toc = render_transcript_toc(str(repair_transcript or ""))
    repair_transcript_html = render_transcript_markdown(str(repair_transcript or ""))
    answer = str(row.get("answer") or "")
    answer_check = "\n".join(
        str(value) for value in (
            row.get("answer_check_output"), row.get("answer_isabelle_error"), row.get("answer_isabelle_notes")
        ) if value
    )
    oneshot_check = "\n".join(
        str(value) for value in (row.get("oneshot_isabelle_error"), row.get("oneshot_isabelle_notes")) if value
    )
    if row.get("oneshot_isabelle_ok") is True and not row.get("oneshot_isabelle_error"):
        oneshot_check = "Accepted by live speculate_check_many."

    repair_attempted = isinstance(row.get("repair"), dict) or any(
        row.get(name) not in (None, "") for name in (
            "mini_ir_prompt", "mini_ir_response", "mini_ir_extracted_proof",
            "mini_ir_events_jsonl", "mini_ir_transcript_markdown",
        )
    )
    answer_html = (
        f"<pre>{esc(answer)}</pre>" if answer
        else '<div class="empty-state">Original proof was not captured in this older rollout.</div>'
    )
    answer_check_html = (
        f"<pre>{esc(answer_check)}</pre>" if answer_check
        else '<div class="empty-state">Not run by the goal-native pipeline.</div>'
    )
    oneshot_check_html = (
        f"<pre>{esc(oneshot_check)}</pre>" if oneshot_check
        else '<div class="empty-state">No checker output was recorded.</div>'
    )

    if repair_attempted:
        repair_check = "\n".join(
            str(value) for value in (row.get("mini_ir_check_output"), row.get("mini_ir_isabelle_error"),
                                     row.get("mini_ir_isabelle_notes")) if value
        )
        if row.get("mini_ir_isabelle_ok") is True and not row.get("mini_ir_isabelle_error"):
            repair_check = "Accepted by live speculate_check_many."
        repair_toc = f"""
        <a href="#step4">Step 4 · Repair</a>
        <a class="sub" href="#step4-prompt">Prompt</a>
        <a class="sub" href="#step4-response">Final response</a>
        <a class="sub" href="#step4-proof">Extracted proof</a>
        <a class="sub" href="#step4-events">Transcript</a>
        {repair_transcript_toc}
        <a href="#step5">Step 5 · Repair check</a>
        <a class="sub" href="#step5-output">Isabelle output</a>
        <a class="sub" href="#step5-theory">Checked theory</a>
        """
        repair_sections = f"""
      <section id="step4" class="block">
        <h2>Step 4 · Repair</h2>
        <h2 id="step4-prompt">Prompt</h2>
        <pre>{esc(row.get("mini_ir_prompt", ""))}</pre>
        <h2 id="step4-response">Final Response</h2>
        <pre>{esc(row.get("mini_ir_response", ""))}</pre>
        <h2 id="step4-proof">Extracted Proof</h2>
        <pre>{esc(row.get("mini_ir_extracted_proof", ""))}</pre>
      </section>
      <section id="step4-events" class="block">
        <h2>Step 4 · Transcript</h2>
        {repair_transcript_html if repair_transcript else repair_cards}
      </section>
      <section id="step5" class="block">
        <h2>Step 5 · Repair Check</h2>
        <h2 id="step5-output">Isabelle Output</h2>
        <pre>{esc(repair_check)}</pre>
        <h2 id="step5-theory">Checked Theory</h2>
        <pre>{esc(row.get("mini_ir_checked_theory_text", ""))}</pre>
      </section>
        """
    else:
        repair_toc = '<a href="#step4">Step 4 · Repair not attempted</a>'
        repair_sections = """
      <section id="step4" class="block">
        <h2>Step 4 · Repair not attempted</h2>
        <div class="empty-state success">The one-shot proof passed Isabelle, so no repair session was opened.</div>
      </section>
        """

    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Distillation pipeline · row {idx + 1}</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg: #0d1117;
      --panel: #151b23;
      --panel-2: #0f1720;
      --text: #e6edf3;
      --muted: #8b949e;
      --line: #30363d;
      --accent: #58a6ff;
      --ok: #3fb950;
      --bad: #f85149;
      --code: #02040a;
    }}
    * {{ box-sizing: border-box; }}
    html {{ scroll-behavior: smooth; }}
    [id] {{ scroll-margin-top: 76px; }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 14px/1.45 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    header {{
      position: sticky;
      top: 0;
      z-index: 2;
      background: rgba(13, 17, 23, .94);
      border-bottom: 1px solid var(--line);
      backdrop-filter: blur(8px);
    }}
    .bar {{
      max-width: 1320px;
      margin: 0 auto;
      padding: 14px 20px;
      display: flex;
      gap: 14px;
      align-items: center;
      justify-content: space-between;
    }}
    h1 {{
      margin: 0;
      font-size: 16px;
      font-weight: 650;
      letter-spacing: 0;
    }}
    .nav a {{
      color: var(--text);
      text-decoration: none;
      border: 1px solid var(--line);
      padding: 6px 10px;
      border-radius: 6px;
      margin-left: 6px;
    }}
    .nav a:hover {{ border-color: var(--accent); }}
    main {{
      max-width: 1320px;
      margin: 0 auto;
      padding: 18px 20px 48px;
      display: grid;
      grid-template-columns: minmax(260px, 360px) minmax(0, 1fr);
      gap: 18px;
    }}
    aside, .content > section {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
    }}
    aside {{
      align-self: start;
      position: sticky;
      top: 70px;
      max-height: calc(100vh - 88px);
      overflow-y: auto;
      padding: 14px;
    }}
    .toc {{
      display: grid;
      gap: 6px;
      margin: 14px 0 16px;
    }}
    .toc a {{
      color: var(--text);
      text-decoration: none;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 7px 9px;
      background: rgba(255,255,255,.02);
    }}
    .toc a:hover {{
      border-color: var(--accent);
      color: var(--accent);
    }}
    .toc a.sub {{
      margin-left: 14px;
      color: var(--muted);
      font-size: 13px;
      padding: 5px 8px;
      border-color: transparent;
      background: transparent;
    }}
    .toc a.sub:hover {{
      color: var(--accent);
      border-color: var(--line);
    }}
    .toc a.sub2 {{
      margin-left: 28px;
      font-size: 12px;
      padding: 4px 8px;
    }}
    .kv {{
      display: grid;
      grid-template-columns: 86px minmax(0, 1fr);
      gap: 6px 10px;
      margin: 10px 0 16px;
    }}
    .k {{ color: var(--muted); }}
    .v {{
      min-width: 0;
      overflow-wrap: anywhere;
      word-break: break-word;
    }}
    .content {{
      min-width: 0;
      display: grid;
      gap: 14px;
    }}
    section.block {{ padding: 14px; }}
    h2 {{
      margin: 0 0 10px;
      font-size: 14px;
      color: var(--accent);
    }}
    pre {{
      margin: 0;
      overflow: auto;
      white-space: pre-wrap;
      word-break: break-word;
      background: var(--code);
      color: #d6deeb;
      border: 1px solid #1f2937;
      border-radius: 7px;
      padding: 12px;
      font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
    }}
    .event {{
      background: var(--panel-2);
      border: 1px solid var(--line);
      border-radius: 8px;
      overflow: hidden;
    }}
    .event.completed {{
      border-color: rgba(63, 185, 80, .75);
    }}
    .event.error {{
      border-color: rgba(248, 81, 73, .8);
    }}
    .event-title {{
      padding: 9px 12px;
      color: var(--muted);
      border-bottom: 1px solid var(--line);
      font: 12px/1.3 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      text-transform: uppercase;
    }}
    .event.tool .event-title {{ color: var(--accent); }}
    .event.completed .event-title {{ color: var(--ok); }}
    .event.assistant .event-title {{ color: var(--ok); }}
    .event.meta .event-title {{ color: var(--muted); }}
    .event.error .event-title {{ color: var(--bad); }}
    .event-note {{
      padding: 9px 12px;
      color: var(--muted);
      border-bottom: 1px solid var(--line);
      background: rgba(255,255,255,.02);
      font-size: 12px;
    }}
    .empty-state {{
      padding: 12px;
      color: var(--muted);
      background: var(--panel-2);
      border: 1px solid var(--line);
      border-radius: 7px;
    }}
    .empty-state.success {{ color: var(--ok); border-color: rgba(63, 185, 80, .5); }}
    .code-label {{
      padding: 10px 12px 6px;
      color: var(--muted);
      background: #05070d;
      font: 11px/1.2 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      text-transform: uppercase;
      letter-spacing: .04em;
    }}
    .code-label + pre {{
      border-top: 1px solid #1f2937;
    }}
    .show-ws .ws-space {{
      color: #6e7681;
    }}
    .show-ws .ws-tab,
    .show-ws .ws-cr {{
      color: #ffa657;
      font-weight: 700;
    }}
    .event pre {{
      border: 0;
      border-radius: 0;
      background: #05070d;
    }}
    @media (max-width: 900px) {{
      main {{ grid-template-columns: 1fr; }}
      aside {{ position: static; }}
    }}
  </style>
</head>
<body>
  <header>
    <div class="bar">
      <h1>Distillation pipeline · {esc(Path(filename).name)} · row {idx + 1} / {total}</h1>
      <div class="nav">
        <a href="/?row={max(0, idx - 1)}">Prev</a>
        <a href="/">First</a>
        <a href="/?row={min(total - 1, idx + 1)}">Next</a>
      </div>
    </div>
  </header>
  <main>
    <aside>
      <h2>Steps</h2>
      <nav class="toc" aria-label="Table of contents">
        <a href="#original">Original Row</a>
        <a class="sub" href="#original-question">Question</a>
        <a class="sub" href="#original-answer">Answer</a>
        <a href="#step2">Step 2 · One-shot</a>
        <a class="sub" href="#step2-prompt">Prompt</a>
        <a class="sub" href="#step2-response">Final response</a>
        <a class="sub" href="#step2-proof">Extracted proof</a>
        <a class="sub" href="#step2-events">Events</a>
        <a href="#step3">Step 3 · Check</a>
        <a class="sub" href="#step3-answer">Answer sanity check</a>
        <a class="sub" href="#step3-error">Isabelle output</a>
        {repair_toc}
      </nav>
      <div class="kv">
        <div class="k">theory</div><div class="v">{esc(row.get("theory"))}</div>
        <div class="k">line</div><div class="v">{esc(row.get("line"))}</div>
        <div class="k">file</div><div class="v">{esc(row.get("mini_ir_context_file"))}</div>
        <div class="k">segment</div><div class="v">{esc(row.get("mini_ir_context_file_preflight_spec"))}</div>
      </div>
    </aside>
    <div class="content">
      <section id="original" class="block">
        <h2>Original Row</h2>
        <h2 id="original-question">Question</h2>
        <pre>{esc(row.get("question", ""))}</pre>
        <h2 id="original-answer">Answer</h2>
        {answer_html}
      </section>
      <section id="step2" class="block">
        <h2>Step 2 · One-shot Rollout</h2>
        <h2 id="step2-prompt">Prompt</h2>
        <pre>{esc(row.get("oneshot_prompt", ""))}</pre>
        <h2 id="step2-response">Final Response</h2>
        <pre>{esc(row.get("oneshot_response", ""))}</pre>
        <h2 id="step2-proof">Extracted Proof</h2>
        <pre>{esc(row.get("oneshot_extracted_proof", ""))}</pre>
      </section>
      <section id="step2-events" class="block">
        <h2>Step 2 · Events</h2>
        {oneshot_cards}
      </section>
      <section id="step3" class="block">
        <h2>Step 3 · One-shot Check</h2>
        <h2 id="step3-answer">Answer Sanity Check</h2>
        {answer_check_html}
        <h2 id="step3-error">Isabelle Output</h2>
        {oneshot_check_html}
      </section>
      {repair_sections}
    </div>
  </main>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    rows: list[dict] = []
    filename = ""

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path not in {"/", "/index.html"}:
            self.send_error(404)
            return
        query = parse_qs(parsed.query)
        try:
            idx = int(query.get("row", ["0"])[0])
        except ValueError:
            idx = 0
        idx = max(0, min(len(self.rows) - 1, idx))
        body = render_row(self.rows[idx], idx, len(self.rows), self.filename).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        print(f"{self.address_string()} - {fmt % args}", file=sys.stderr)


class ReusableTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
    if hasattr(socketserver.TCPServer, "allow_reuse_port"):
        allow_reuse_port = True


def main() -> int:
    args = parse_args()
    if not args.jsonl.exists():
        print(f"error: file not found: {args.jsonl}", file=sys.stderr)
        return 2
    rows = read_rows(args.jsonl)
    if not rows:
        print(f"error: no rows in {args.jsonl}", file=sys.stderr)
        return 1

    if args.check:
        for index, row in enumerate(rows):
            render_row(row, index, len(rows), str(args.jsonl))
        print(f"Validated {args.jsonl} ({len(rows)} rows)")
        return 0

    Handler.rows = rows
    Handler.filename = str(args.jsonl)
    with ReusableTCPServer((args.host, args.port), Handler) as httpd:
        url = f"http://{args.host}:{args.port}/"
        print(f"Serving {args.jsonl} ({len(rows)} rows) at {url}")
        if not args.no_open:
            webbrowser.open(url)
        httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
