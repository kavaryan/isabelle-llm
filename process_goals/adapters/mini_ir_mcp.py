#!/usr/bin/env python3
"""Minimal mini_ir MCP server: attaches to an open I/R REPL"""

from __future__ import annotations

import argparse
import asyncio
import re
import socket
import sys

SENTINEL = "<<DONE>>"
_TIMING_LINE = re.compile(r"^\[timing\] ([\d.]+)s\n?", re.MULTILINE)
_SLEDGEHAMMER_NOISE = re.compile(
    r"^(?:SMT: Warning: dropping assumption:.*"
    r"|\w+ found a proof\.\.\."
    r"|don't export proof"
    r"|\w+: Duplicate proof"
    r"|Unification bound exceeded -- see unify trace for details"
    r"|Done)$",
    re.MULTILINE,
)


def ml_str(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def ml_int(value: int) -> str:
    return f"~{-value}" if value < 0 else str(value)


def consolidate_timing(text: str) -> str:
    """Collapse the per-call [timing] lines (step/state each report their
    own) into a single total -- the breakdown is noise, the total is signal."""
    times = [float(m) for m in _TIMING_LINE.findall(text)]
    cleaned = _TIMING_LINE.sub("", text).strip()
    if times:
        cleaned += f"\n[timing] {sum(times):.3f}s"
    return cleaned


def consolidate_sledgehammer(text: str) -> str:
    """Sledgehammer streams live per-prover progress (SMT solver warnings,
    "<prover> found a proof...", export/dedup bookkeeping) over the same
    channel as its result -- jEdit folds it away, a flat REPL transcript
    doesn't. Drop it; keep the per-prover and final "Try this" lines."""
    lines = [l for l in text.split("\n") if not _SLEDGEHAMMER_NOISE.match(l)]
    return "\n".join(l for l in lines if l.strip())


def _read_line(sock: socket.socket) -> str:
    data = b""
    while b"\n" not in data:
        chunk = sock.recv(1024)
        if not chunk:
            raise RuntimeError("connection closed during authentication")
        data += chunk
    return data.split(b"\n", 1)[0].decode("utf-8", errors="replace")


def _read_until_sentinel(sock: socket.socket) -> str:
    data = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("connection closed before command completed")
        data += chunk
        text = data.decode("utf-8", errors="replace")
        if SENTINEL in text:
            return text[: text.index(SENTINEL)]


class IrTcpClient:
    def __init__(self, host: str, port: int, token: str, timeout: float):
        self.host = host
        self.port = port
        self.token = token
        self.timeout = timeout

    def send(self, command: str) -> str:
        with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
            sock.settimeout(self.timeout)
            sock.sendall((self.token + "\n").encode("utf-8"))
            if _read_line(sock).strip() != "OK":
                raise RuntimeError("mini_ir authentication failed")
            sock.sendall((command + "\n").encode("utf-8"))
            response = _read_until_sentinel(sock).strip()
        if response.startswith("ERR\n"):
            raise RuntimeError(consolidate_timing(response[4:].strip()))
        return consolidate_timing(response)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Minimal mini_ir MCP server: attaches to an already-open I/R REPL."
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--repl", required=True, help="id of an already-open REPL")
    parser.add_argument("--timeout", type=float, default=120.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        from mcp.server.fastmcp import FastMCP
    except ImportError:
        print(
            "error: Python package 'mcp' is required. Install it with: python3 -m pip install mcp",
            file=sys.stderr,
        )
        return 2

    client = IrTcpClient(args.host, args.port, args.token, args.timeout)
    repl_id = args.repl

    mcp = FastMCP(
        "mini_ir",
        instructions=(
            "Isar-facing MCP wrapper attached to an I/R REPL already opened at "
            "one goal. Use step with Isar text such as 'by simp'; use back to "
            "undo a misstep."
        ),
    )

    def step_or_back(label: str, command: str) -> str:
        output = client.send(command).strip()
        state = client.send(f"Ir.state {ml_str(repl_id)} ~1;").strip()
        parts = [f"-- {label} --\n{output}"] if output else []
        if state:
            parts.append(f"-- state --\n{state}")
        return "\n\n".join(parts) if parts else "ok"

    @mcp.tool(description="Execute one Isar step and return the step output plus latest proof state.")
    async def step(isar_text: str) -> str:
        return await asyncio.to_thread(
            step_or_back, "step", f"Ir.step {ml_str(repl_id)} {ml_str(isar_text)};"
        )

    @mcp.tool(description="Undo the last successful Isar step.")
    async def back() -> str:
        return await asyncio.to_thread(step_or_back, "back", f"Ir.back {ml_str(repl_id)};")

    @mcp.tool(description="Show the full Isar proof text applied so far, from the original goal to the current point.")
    async def text() -> str:
        return await asyncio.to_thread(client.send, f"Ir.text {ml_str(repl_id)};")

    @mcp.tool(
        description=(
            "Search for Isabelle theorems in the current proof context using "
            "Isabelle Find_Theorems query syntax. Exact fact-name lookup is NOT "
            "a bare word: use name: le_antisym, name: conjI, etc. A bare query "
            "is a statement/content search and can return 0 even when "
            "`step` with `thm le_antisym` succeeds. Criteria combine, e.g. "
            "query='name: order \"_ \\<le> _\"' finds lemmas named like "
            "'order' whose statement contains that pattern."
        )
    )
    async def find_theorems(query: str, limit: int = 20) -> str:
        return await asyncio.to_thread(
            client.send, f"Ir.find_theorems {ml_str(repl_id)} {ml_int(limit)} {ml_str(query)};"
        )

    @mcp.tool(
        description=(
            "Run sledgehammer on the current proof state with the given "
            "timeout in seconds and return any proof it finds."
        )
    )
    async def sledgehammer(seconds: int = 30) -> str:
        raw = await asyncio.to_thread(
            client.send, f"Ir.sledgehammer {ml_str(repl_id)} {ml_int(seconds)};"
        )
        return consolidate_sledgehammer(raw)

    mcp.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
