# Isabelle LLM

Research tooling for LLM-assisted proof development in Isabelle/HOL. The
repository covers proof-data extraction, goal processing and evaluation,
supervised and verifier-guided training, semantic retrieval, and interactive
proof assistance.

The modules can be used independently; there is no single repository-wide
build or runtime.

## Components

| Path | Purpose |
| --- | --- |
| [`extractor/`](extractor/) | Isabelle component exposing `isabelle proof_extractor` for exporting proof steps, goal states, enclosing proof blocks, and relevance-filtered facts as JSON. |
| [`process_goals/`](process_goals/) | Isabelle2025-2 tools for goal extraction, filtering, benchmarking, distillation, checking, and repair. |
| [`thm_export/`](thm_export/) | Scala utility for exporting theorem names, source statements, and source locations from a built Isabelle session. |
| [`sft/`](sft/) | Dataset preparation, prompt-template modules, and Slurm jobs for supervised fine-tuning and evaluation. |
| [`rl/`](rl/) | Verifier-reward GRPO experiments and Slurm training utilities. |
| [`repl/`](repl/) | Interactive Isar frontend and `mini_ir` MCP bridge for the AutoCorrode I/R backend. |
| [`semantic-search/`](semantic-search/) | Prototype theorem-embedding and proof-dependency retrieval benchmark. |
| [`jedit-plugin/`](jedit-plugin/) | Isabelle/jEdit panel for requesting and optionally verifying LLM proof suggestions. |

## Proof extraction quick start

The extractor's Docker image and the `process_goals` Docker environment target
Isabelle2025-2. With a local Isabelle installation, register and build the
extractor from the repository root:

```bash
isabelle components -u "$PWD/extractor"
isabelle scala_build
isabelle proof_extractor -?
```

For a small extraction without relevance filtering:

```bash
isabelle proof_extractor -m 0 -d out \
  HOL-Lattice.CompleteLattice HOL-Lattice.Lattice
```

The command writes parsed records below `out/json/` and raw PIDE exports below
`out/export/`. See the [extractor documentation](extractor/README.md) for theory
lists, filtering options, output fields, and Docker usage.

## Other workflows

- [Goal processing and distillation](process_goals/README.md)
- [Isabelle/jEdit integration](jedit-plugin/README.md)
- [Isar REPL and MCP integration](repl/README.md)
- [Supervised fine-tuning](sft/README.md)
- [Verifier-guided reinforcement learning](rl/slurm/README.md)
- [Semantic-search experiments](semantic-search/README.md)

SFT prompt templates are defined in
[`sft/non_thinking_prompt_leaves.py`](sft/non_thinking_prompt_leaves.py) and
[`sft/non_thinking_prompt_isar.py`](sft/non_thinking_prompt_isar.py).
