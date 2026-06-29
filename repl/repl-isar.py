#!/usr/bin/env python3
"""Friendly Isar prompt for a running AutoCorrode I/R repl.py server.

This is only a client wrapper. Start repl.py first, then connect with the
printed IR_Repl.token:

  python3 repl.py
  python3 repl-isar.py --token TOKEN

Normal input is sent as one Isar step. The wrapper prints the latest proof
state after each successful step.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import socket
import sys
import time
from pathlib import Path

SENTINEL = "<<DONE>>"


try:
    from prompt_toolkit import PromptSession
    from prompt_toolkit.formatted_text import HTML
    from prompt_toolkit.history import FileHistory
    from prompt_toolkit.patch_stdout import patch_stdout
    from prompt_toolkit.shortcuts import print_formatted_text

    HAVE_PROMPT_TOOLKIT = True
except ImportError:
    HAVE_PROMPT_TOOLKIT = False


USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


RST = ""
BOLD = ""
DIM = ""
RED = ""
GREEN = ""
YELLOW = ""
BLUE = ""
CYAN = ""


def print_status(text: str, style: str = "ansibrightblack") -> None:
    if HAVE_PROMPT_TOOLKIT and USE_COLOR:
        print_formatted_text(HTML(f"<{style}>{html_escape(text)}</{style}>"))
    else:
        print(text)


def print_header(text: str, style: str = "ansiblue") -> None:
    if HAVE_PROMPT_TOOLKIT and USE_COLOR:
        print_formatted_text(HTML(f"<b><{style}>{html_escape(text)}</{style}></b>"))
    else:
        print(text)


def html_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


class ReplError(RuntimeError):
    pass


def ml_str(text: str) -> str:
    """Escape a Python string as an Isabelle/ML string literal."""
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def ml_int(value: int) -> str:
    return f"~{-value}" if value < 0 else str(value)


class IrTcpClient:
    def __init__(self, host: str, port: int, token: str, timeout: float):
        self.host = host
        self.port = port
        self.token = token
        self.timeout = timeout

    def send(self, command: str) -> tuple[str, bool]:
        command = command.strip()
        if not command.startswith("/") and not command.endswith(";"):
            command += ";"

        with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
            sock.settimeout(self.timeout)
            sock.sendall((self.token + "\n").encode("utf-8"))
            auth = self._read_line(sock)
            if auth.strip() != "OK":
                raise ReplError("authentication failed")

            sock.sendall((command + "\n").encode("utf-8"))
            response = self._read_until_sentinel(sock).strip()

        had_error = response.startswith("ERR\n")
        if had_error:
            response = response[4:].strip()
        return response, had_error

    @staticmethod
    def _read_line(sock: socket.socket) -> str:
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(1024)
            if not chunk:
                raise ReplError("connection closed during authentication")
            data += chunk
        line, _rest = data.split(b"\n", 1)
        return line.decode("utf-8", errors="replace")

    @staticmethod
    def _read_until_sentinel(sock: socket.socket) -> str:
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                raise ReplError("connection closed before command completed")
            data += chunk
            text = data.decode("utf-8", errors="replace")
            if SENTINEL in text:
                return text[: text.index(SENTINEL)]


class IsarRepl:
    def __init__(
        self,
        client: IrTcpClient,
        repl_id: str,
        theories: list[str],
        show_state: bool,
    ):
        self.client = client
        self.repl_id = repl_id
        self.theories = theories
        self.show_state = show_state

    def start(self) -> None:
        theories = "[" + ", ".join(ml_str(t) for t in self.theories) + "]"
        self.print_result("init", *self.client.send(f"Ir.init {ml_str(self.repl_id)} {theories};"))

    def step(self, isar_text: str) -> None:
        output, had_error = self.client.send(
            f"Ir.step {ml_str(self.repl_id)} {ml_str(isar_text)};"
        )
        self.print_result("step", output, had_error)
        if not had_error and self.show_state:
            state, state_error = self.client.send(f"Ir.state {ml_str(self.repl_id)} ~1;")
            if state.strip():
                self.print_result("state", state, state_error)

    def state(self, idx: int = -1) -> None:
        self.print_result(
            f"state {idx}",
            *self.client.send(f"Ir.state {ml_str(self.repl_id)} {ml_int(idx)};"),
        )

    def show(self) -> None:
        self.print_result("show", *self.client.send(f"Ir.show {ml_str(self.repl_id)};"))

    def text(self) -> None:
        self.print_result("text", *self.client.send(f"Ir.text {ml_str(self.repl_id)};"))

    def back(self) -> None:
        self.print_result("back", *self.client.send(f"Ir.back {ml_str(self.repl_id)};"))
        if self.show_state:
            self.state()

    def reset(self) -> None:
        self.client.send(f"Ir.remove {ml_str(self.repl_id)};")
        self.start()

    def theories_cmd(self) -> None:
        self.print_result("theories", *self.client.send("Ir.theories ();"))

    def load_theory(self, name: str) -> None:
        self.print_result("load", *self.client.send(f"Ir.load_theory {ml_str(name)};"))

    def sledgehammer(self, seconds: int) -> None:
        self.print_result(
            "sledgehammer",
            *self.client.send(f"Ir.sledgehammer {ml_str(self.repl_id)} {ml_int(seconds)};"),
        )

    def find_theorems(self, query: str, limit: int) -> None:
        self.print_result(
            "find",
            *self.client.send(
                f"Ir.find_theorems {ml_str(self.repl_id)} {ml_int(limit)} {ml_str(query)};"
            ),
        )

    @staticmethod
    def print_result(label: str, output: str, had_error: bool) -> None:
        marker = "error" if had_error else label
        print_header(f"-- {marker} --", "ansired" if had_error else "ansiblue")
        if output.strip():
            print(output.rstrip())


def print_help() -> None:
    print(
        f"""{BOLD}Commands{RST}
  {CYAN}:step ISAR_TEXT{RST}       execute one Isar step
  {CYAN}:back{RST}                 undo the last successful step
  {CYAN}:reset{RST}                recreate this REPL from the initial theories
  {CYAN}:find_theorems QUERY{RST}  find theorems, default limit 20
  {CYAN}:help{RST}                 show this help
  {CYAN}:quit{RST}                 exit

Everything else is sent as one Isar step. Do not type theory headers; choose
the starting theory with --theory/--theories."""
    )


def handle_command(repl: IsarRepl, line: str) -> bool:
    parts = line.split(maxsplit=1)
    command = parts[0]
    rest = parts[1] if len(parts) > 1 else ""

    if command == ":quit":
        return False
    if command in (":help", ":h"):
        print_help()
    elif command == ":step":
        if not rest:
            print(f"{RED}usage: :step ISAR_TEXT{RST}", file=sys.stderr)
        else:
            repl.step(rest)
    elif command == ":back":
        repl.back()
    elif command == ":reset":
        repl.reset()
    elif command == ":find_theorems":
        if not rest:
            print(f"{RED}usage: :find_theorems QUERY{RST}", file=sys.stderr)
        else:
            repl.find_theorems(rest, 20)
    else:
        print(f"{RED}unknown command: {command}{RST}", file=sys.stderr)
    return True


def selected_theories(args: argparse.Namespace) -> list[str]:
    theories: list[str] = []
    if args.theories:
        theories.extend(t.strip() for t in args.theories.split(",") if t.strip())
    theories.extend(args.theory or [])
    return theories or ["Main"]


def prompt_text(repl_id: str, multiline: bool = False):
    suffix = "..." if multiline else "isar"
    if HAVE_PROMPT_TOOLKIT:
        if USE_COLOR:
            return HTML(f"<b><ansicyan>{suffix}</ansicyan></b>[{repl_id}]&gt; ")
        return f"{suffix}[{repl_id}]> "
    return f"{suffix}[{repl_id}]> "


def input_loop(repl: IsarRepl, history_file: str) -> int:
    multiline: list[str] | None = None

    if HAVE_PROMPT_TOOLKIT and sys.stdin.isatty():
        session = PromptSession(history=FileHistory(history_file))

        def read_line() -> str:
            return session.prompt(prompt_text(repl.repl_id, multiline is not None))

        ctx = patch_stdout()
    else:
        session = None

        def read_line() -> str:
            return input(prompt_text(repl.repl_id, multiline is not None))

        class NullContext:
            def __enter__(self):
                return None

            def __exit__(self, *_exc):
                return False

        ctx = NullContext()

    with ctx:
        while True:
            try:
                line = read_line()
            except EOFError:
                print()
                return 0
            except KeyboardInterrupt:
                print()
                print_status("cancelled input; use :quit or Ctrl-D to exit")
                multiline = None
                continue

            stripped = line.strip()
            try:
                if multiline is not None:
                    if stripped == ":}":
                        block = "\n".join(multiline).strip()
                        multiline = None
                        if block:
                            repl.step(block)
                        continue
                    multiline.append(line)
                    continue

                if stripped.startswith(":"):
                    if not handle_command(repl, stripped):
                        return 0
                    continue
                if stripped:
                    repl.step(line)
            except (OSError, ReplError, ValueError) as exc:
                print(f"error: {exc}", file=sys.stderr)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="True Isar prompt for a running AutoCorrode I/R repl.py server."
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=int(os.environ.get("IR_REPL_PORT", "9147")))
    parser.add_argument("--token", default=os.environ.get("IR_AUTH_TOKEN", ""))
    parser.add_argument(
        "--repl",
        default=os.environ.get("IR_ISAR_REPL_ID", f"R_{os.getpid()}_{int(time.time())}"),
    )
    parser.add_argument("--theory", action="append", help="Theory to import; may be repeated.")
    parser.add_argument("--theories", help="Comma-separated theories to import.")
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--no-auto-state", action="store_true")
    parser.add_argument(
        "--mcp",
        action="store_true",
        help="Run a stdio MCP server instead of the interactive Isar prompt.",
    )
    parser.add_argument(
        "--history",
        default=str(Path.home() / ".cache" / "ir-repl-isar-history"),
    )
    return parser.parse_args()


def run_mcp(args: argparse.Namespace) -> int:
    try:
        from mcp.server.fastmcp import FastMCP
    except ImportError:
        print(
            "error: Python package 'mcp' is required for --mcp. "
            "Install it with: python3 -m pip install mcp",
            file=sys.stderr,
        )
        return 2

    client = IrTcpClient(args.host, args.port, args.token, args.timeout)
    repl_state = {
        "id": args.repl,
        "theories": selected_theories(args),
        "initialized": False,
    }
    mcp = FastMCP(
        "mini_ir",
        instructions=(
            "Small Isar-facing MCP wrapper for AutoCorrode I/R. "
            "Use step with Isar text such as 'lemma smoke: True' and 'by simp'. "
            "The wrapper creates an I/R REPL from the configured theories on first use."
        ),
    )

    def send_sync(command: str) -> str:
        output, had_error = client.send(command)
        if had_error:
            raise RuntimeError(output)
        return output

    def ensure_init_sync() -> str:
        if repl_state["initialized"]:
            return ""
        theories = "[" + ", ".join(ml_str(t) for t in repl_state["theories"]) + "]"
        output = send_sync(f"Ir.init {ml_str(repl_state['id'])} {theories};")
        repl_state["initialized"] = True
        return output

    @mcp.tool(description="Execute one Isar step and return the step output plus latest proof state.")
    async def step(isar_text: str) -> str:
        def work() -> str:
            init_output = ensure_init_sync()
            step_output = send_sync(
                f"Ir.step {ml_str(repl_state['id'])} {ml_str(isar_text)};"
            )
            state_output = send_sync(f"Ir.state {ml_str(repl_state['id'])} ~1;")
            parts = []
            if init_output.strip():
                parts.append("-- init --\n" + init_output.strip())
            if step_output.strip():
                parts.append("-- step --\n" + step_output.strip())
            if state_output.strip():
                parts.append("-- state --\n" + state_output.strip())
            return "\n\n".join(parts) if parts else "ok"

        return await asyncio.to_thread(work)

    @mcp.tool(description="Undo the last successful Isar step.")
    async def back() -> str:
        def work() -> str:
            ensure_init_sync()
            back_output = send_sync(f"Ir.back {ml_str(repl_state['id'])};")
            state_output = send_sync(f"Ir.state {ml_str(repl_state['id'])} ~1;")
            parts = []
            if back_output.strip():
                parts.append("-- back --\n" + back_output.strip())
            if state_output.strip():
                parts.append("-- state --\n" + state_output.strip())
            return "\n\n".join(parts) if parts else "ok"

        return await asyncio.to_thread(work)

    @mcp.tool(description="Remove and recreate the current REPL from the configured theories.")
    async def reset() -> str:
        def work() -> str:
            if repl_state["initialized"]:
                try:
                    send_sync(f"Ir.remove {ml_str(repl_state['id'])};")
                except Exception:
                    pass
            repl_state["initialized"] = False
            return ensure_init_sync()

        return await asyncio.to_thread(work)

    @mcp.tool(description="Search for Isabelle theorems in the current proof context.")
    async def find_theorems(query: str, limit: int = 20) -> str:
        def work() -> str:
            ensure_init_sync()
            return send_sync(
                f"Ir.find_theorems {ml_str(repl_state['id'])} {ml_int(limit)} {ml_str(query)};"
            )

        return await asyncio.to_thread(work)

    mcp.run()
    return 0


def main() -> int:
    args = parse_args()
    if not args.token:
        print(
            "error: pass --token TOKEN, or set IR_AUTH_TOKEN to the token printed by repl.py",
            file=sys.stderr,
        )
        return 2

    if args.mcp:
        return run_mcp(args)

    history = Path(args.history)
    history.parent.mkdir(parents=True, exist_ok=True)

    client = IrTcpClient(args.host, args.port, args.token, args.timeout)
    repl = IsarRepl(
        client,
        args.repl,
        selected_theories(args),
        show_state=not args.no_auto_state,
    )
    try:
        repl.start()
    except (OSError, ReplError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print_header("Isar REPL ready", "ansigreen")
    print_status("(:help for commands)")
    return input_loop(repl, str(history))


if __name__ == "__main__":
    raise SystemExit(main())
