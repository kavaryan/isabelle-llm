# goals — theory-goal tools (extract / filter / bench / run)

One self-contained component on stock Isabelle. Ingest a set of theories into one
headless session, select their proof goals, and act on each goal through a `Probe`
(goal-level analogue of a stock `Dump.Aspect`). Four tools ship as probes:
`goals_extract` (proof-pair data), `goals_filter` (hard-set whitelist), `goals_bench`
(stock + LLM pass@k arms), `goals_run` (any registered `Probe`).

The spine: stock `Headless` → `Goals.with_theories` (build + headless loop, the goals
analogue of `Dump.Context`) → `Goals_Query` (install an ML overlay, block for its
result) → `Goals_Run.run[A]` (select goals, apply a `Probe`). ML is only the registered
query ops (`Goals_Queries.thy`, loaded at runtime via `$GOALS_HOME`); selection, LLM
calls (`goals_http`) and output (`goals_output`) are Scala. See README.md to add a probe.

## Coding guidelines

- **Stock Isabelle only.** Depend on nothing but `ISABELLE_SCALA_JAR`. Do not reuse
  the MCP/`prove` stack. Reuse stock Pure abstractions (`Headless`, `Document`,
  `Query_Operation`, `Sessions`, `Build`, `XML`, `Synchronized`, `Exn`); take
  inspiration from the Isabelle codebase and match its style. No hacks.
- **Thin ML, Scala drives.** ML is only the registered query operations
  (`Goals_Queries.thy`). Selection, LLM calls, candidate checking, and output are
  Scala. Ship a component — never patch Isabelle.
- **Simplest code that works.** Minimal code, minimal documentation. Prefer small,
  obvious functions over abstraction.
- **Comments describe what the code does, never its history.** No "lifted from",
  "cf.", or provenance notes.
- **No `unsafeNulls`.** Do not `import scala.language.unsafeNulls`; write null-safe
  Scala and handle Java-interop nulls explicitly.
- **No catch-all `handle exn`/`handle _`.** It swallows interrupts and is reported as
  an ML error (so the query op silently fails to register). Catch specific exceptions,
  or let them propagate to the query-op machinery, which surfaces them as errors.
- **Test ML with the PIDE MCP, not full rebuilds.** Drop ML into a `create_scratch`
  theory and `get_state` to see compile errors / values in seconds. `Goals_Queries.thy`
  is loaded by `use_theories`, whose result is checked — load errors abort the tool.
- **Select everything.** Goal selection has no default command-name set — every
  proof step is a candidate; `Goals.selectable` (Proof.assert_backward) decides what
  is a real goal.
- **Big-O / dataset conventions** live with the benchmark datasets, not here.

## Build

Targets official Isabelle2025-2 (see `Dockerfile`). Register the component under
`etc/components`; a tool invocation triggers the Scala build. `Goals_Queries.thy`
(in `src/`) is loaded at runtime via `$GOALS_HOME`, not compiled.
