# goals — theory-goal tools (extract / filter / bench / run)

A self-contained Isabelle component, built on stock Pure only (`ISABELLE_SCALA_JAR`).
It ingests a set of theories into one headless session, selects their proof goals,
and acts on each goal through a **Probe** — the goal-level analogue of a stock
`Dump.Aspect`. Four command-line tools ship as probes:

| Tool            | Purpose |
|-----------------|---------|
| `goals_extract` | Proof-pair training data (state, preceding theory text, MePo facts) as JSON. |
| `goals_filter`  | The goals `try0` (optionally sledgehammer) **cannot** close — a "hard" whitelist. |
| `goals_bench`   | Single-step benchmark: stock arms (`try0`/sledgehammer) and LLM arms (pass@1 / pass@k). |
| `goals_run`     | Run any registered Probe (your own Scala) over the goals. |

## Build & install

Targets the official **Isabelle2025-2** release. Register the component once by
adding its path to `etc/components`:

```
echo "$PWD" >> "$(isabelle getenv -b ISABELLE_HOME_USER)/etc/components"
```

The Scala sources compile on the first tool invocation (driven by `etc/build.props`);
no manual build. Simplest way to get a matching Isabelle: `docker build -t
goals .` (see `Dockerfile`) -- it starts from the official
`makarius/isabelle:Isabelle2025-2` image, which already ships a prebuilt HOL heap.

## Usage

Theories are arguments (session-qualified like `HOL-Data_Structures.Tree_Set`, or a
file path without `.thy`), or via `-T FILE` (one per line, `#` comments). Common
options: `-d DIR` (session/AFP dir — AFP theories need `-d <afp>/thys`), `-l NAME`
(logic, default `HOL`), `-s N` / `-m N` (keep every Nth goal / at most N per theory),
`-t SECONDS` (per-goal timeout), `-v`.

```
# proof-pair data, 16 MePo facts/goal, leaf one-liner proofs only (-L -A):
isabelle goals_extract -L -A -F 16 -O out/extract  HOL-Data_Structures.Tree_Set

# hard one-liners try0 and sledgehammer-methods cannot close:
isabelle goals_filter -L -A -H -M -t 5 -O out/hard.json  -T datasets/fdsa.txt

# benchmark stock arms over the hard set:
isabelle goals_bench -A try0 -A sledgehammer:methods -W out/hard.json -O out/bench  -T datasets/fdsa.txt
```

`-L` keeps leaf proofs (no nested sub-proof), `-A` excludes `apply` scripts — together
they select one-liner goals. `goals_filter` and `goals_bench` agree on goal identity
(theory + line + offset), so `goals_filter -O hard.json` then `goals_bench -W hard.json`
benchmarks exactly the hard set.

## LLM benchmark

The LLM arm `-L LABEL,URL,PROMPT_FILE` samples `k` candidates per goal from an
OpenAI-compatible `/v1/chat/completions` endpoint and checks each with the
`speculate_check_many` query op (pass@k = any candidate closes the goal).

```
# 1. serve the model (any /v1/chat/completions server works; bundled shim here):
#    needs torch+transformers: python3 -m venv .venv && source .venv/bin/activate && pip install torch transformers
python3 serve/serve_openai.py --model kavaryan/Qwen3-0.6B_sft-ds --port 8000 &

# 2. run, restricting to the hard set:
isabelle goals_bench \
  -A try0 -A sledgehammer:methods \
  -L ds,http://localhost:8000/v1/chat/completions,prompts/sft_prompt.txt \
  -F 16 -k 8 -c 2000 -t 30 -W out/hard.json -O out/bench  -T datasets/fdsa.txt
```

`-F` facts in the prompt, `-k` candidates/goal, `-c` symbols of preceding theory text
(default 2000). The prompt template (`-L`'s third field) substitutes `{theory}`,
`{goal}`, `{facts}`; `prompts/sft_prompt.txt` matches the model's training format.

## Distillation pipeline (discover / oneshot / check / repair)

Four probes chain into a pipeline that turns existing proofs into distillation data:
an LLM attempts each goal one-shot; what it gets wrong is handed to a second LLM to
repair interactively, through the same AutoCorrode I/R REPL `goals_repl` opens for
manual exploration. Each phase reads the previous phase's output as its whitelist
(`-W`) and writes goal-keyed JSON records (theory + line + offset) that the next
phase looks up by position, verifying the source hasn't changed underneath it.

| Probe      | Phase | Reads (`-W`)  | Does |
|------------|-------|---------------|------|
| `discover` | 1     | --            | Records goal positions + a source hash. |
| `oneshot`  | 2     | phase 1       | One-shot proof attempt via an external adapter (any command that reads a prompt on stdin, writes a completion to stdout). |
| `check`    | 3     | phase 2       | Verifies phase-2 proofs with `speculate_check_many`; keeps only the faulty ones. |
| `repair`   | 4     | phase 3       | Opens an I/R REPL at each faulty goal and drives an external agent adapter with mini_ir MCP tools until it closes or gives up. |

`repl` (no phase number) is the standalone building block behind `repair`: it opens
one I/R REPL and waits for the goal to close, for interactive/manual use.

Run the whole chain with `./run_pipeline.sh`:

```
IR_DIR=/path/to/AutoCorrode/ir ./run_pipeline.sh -m 3 HOL-Data_Structures.Sorted_Less
```

All configuration is via env vars (`ISABELLE`, `OUT_DIR`, `IR_DIR`, `ADAPTER_ONESHOT`,
`ADAPTER_REPAIR`, `PROMPT_ONESHOT`, `PROMPT_REPAIR`, `MAX_SYMBOLS`,
`CHECK_TIMEOUT_SECS`, `REPAIR_TIMEOUT_SECS`, `FORCE`) -- see the script header. Any
positional args (theories, `-m`/`-s`/`-l`/`-d`/`-v`/...) are forwarded to every phase.
Each phase's output file is reused if it already exists; set `FORCE=1` to rerun.
Omit `IR_DIR` to run just phases 1-3 (no repair).

`oneshot`/`repair`'s adapters are `adapters/opencode_adapter.sh` /
`adapters/opencode_repair_adapter.sh` by default -- thin wrappers around the
`opencode` CLI (see the scripts for the env vars they expect); swap in any adapter
that reads a prompt on stdin and prints a completion on stdout. `repair`'s adapter
gets an MCP server, `adapters/mini_ir_mcp.py` (tools: `step`, `back`, `text`,
`find_theorems`, `sledgehammer`), pre-connected to the REPL opened for that goal.

`IR_DIR` must point at [AutoCorrode](https://github.com/awslabs/AutoCorrode)'s `ir/`
directory (`ir.ML`/`tcp_handler.ML`/`ml_repl.ML`/`repl.py`).

## Architecture

```
stock Headless                          (Resources / start_session / use_theories)
  └─ Goals.with_theories                build + headless loop  (≈ Dump.Context)
       └─ Goals_Query                   install ML overlay, block for result
            └─ Goals_Run.run[A]         select goals, apply a Probe per goal
```

ML is only the registered query operations in `Goals_Queries.thy` (loaded at runtime
via `$GOALS_HOME`): `selectable`, `suggested_facts_rich`, `try0_closes`,
`sledgehammer_closes`, `speculate_check_many`. Everything else is Scala.

## Extending: write a Probe

A Probe is the only thing you write. It sees one goal at a time via a `Context` (the
live session plus helpers `query`, `closes`, `goal_state`, `facts`, `text_before`,
`block`, `ref`), returns a record, and the runner collects them:

```scala
package isabelle.goals
import isabelle._

// records, per goal, whether `auto` closes it and the goal's MePo facts
class Auto_Probe extends JSON_Probe {
  def name = "auto"
  override def description = "whether a single try0 method closes each goal"
  def apply(c: Probe.Context): Option[JSON.T] =
    Some(JSON.Object(
      "theory" -> c.theory, "line" -> c.site.line,
      "closes" -> c.closes("try0_closes", List(c.secs)),
      "facts" -> c.facts))
}

class My_Probes extends Goals_Probes(new Auto_Probe)
```

1. add `src/my_probe.scala` to `sources` and `isabelle.goals.My_Probes` to `services`
   in `etc/build.props`;
2. `isabelle goals_run -P list` (confirm it appears), then
   `isabelle goals_run -P auto -F 16 -O out.json  HOL-Data_Structures.Tree_Set`.

For richer output, extend `Probe[A]` directly (typed records) and override `finish`
(final output / summary) and `checkpoint` (incremental write after each theory) — that
is exactly how `Filter_Probe`, `Extract_Probe` and `Bench_Probe` are built; read them
as templates.
