# mini_ir / Isar REPL

`repl-isar.py` is a small Isar-facing wrapper around the AutoCorrode I/R backend.
It can run as an interactive CLI or as the `mini_ir` stdio MCP server.

## Context Imports

When `MINI_IR_CONTEXT_TEXT` contains a theory header, the wrapper parses the header
and initializes I/R with the imported theories before replaying the remaining
context text.

Example:

```isabelle
theory CompleteLattice
  imports Lattice
begin
```

I/R stores session theories under qualified names such as
`HOL-Lattice.Lattice`, while Isabelle source headers often use the bare import
name `Lattice`. The wrapper resolves a bare import by asking the backend for
`Ir.theories ()` and matching by unique suffix.

If the imported theory is not loaded yet, the wrapper also looks at a standard
header `Title:` path such as `HOL/Lattice/CompleteLattice.thy`. From that path
it infers the session prefix `HOL-Lattice`, tries to load
`HOL-Lattice.Lattice`, and then initializes I/R with that qualified name.

The rule is intentionally conservative:

- `Lattice` resolves to `HOL-Lattice.Lattice` only if that is the only loaded
  theory whose name ends in `.Lattice`.
- If no loaded suffix match exists, a `Title:` path may provide exactly one
  session-qualified load candidate such as `HOL-Lattice.Lattice`.
- Already-qualified imports are left unchanged.
- If there are zero viable candidates or multiple viable candidates, the wrapper
  leaves the original import unchanged and lets `Ir.init` fail instead of
  guessing.

This avoids silently picking the wrong theory when two sessions expose the same
bare theory name.

Use `test-mini-ir-lattice.sh` to check this behavior against a `HOL-Lattice`
backend.

`MINI_IR_CONTEXT_FILE` may alternatively point at an already-built source
location:

```bash
MINI_IR_CONTEXT_FILE=/home/isabelle/Isabelle/src/HOL/Lattice/CompleteLattice.thy:118
```

In that mode the wrapper asks the backend to resolve the file and line to a
recorded theory segment, then initializes I/R at that segment. The backend must
be running with the session whose recorded heap DB contains that source map.
