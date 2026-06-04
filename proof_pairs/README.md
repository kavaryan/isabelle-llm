# Proof Pairs (adhoc extraction)

An alternative proof-pair extractor built on the official **`isabelle
process_theories`** tool instead of a full Mirabelle session run. It extracts,
for every proof step of a chosen set of theories, the **goal state**, the
**tactic**, the surrounding **proof block**, and optionally the
**MePo/sledgehammer-suggested facts** — emitting one JSON array per theory.

It is registered as an Isabelle component exposing the tool `isabelle
proof_pairs`.

## Installation

To install the tool, register this directory as an Isabelle component:

```bash
isabelle components -u /path/to/isabelle-llm/proof_pairs
```

Verify the component is registered and compiled:

```bash
isabelle scala_build
isabelle proof_pairs -?
```

## Architecture

The tool operates in two phases:
1. **Extraction (Phase 1)**: Uses `isabelle process_theories` to compose a temporary ad-hoc session ("Draft") that re-elaborates the target theories on top of their parent session. A custom presentation hook (`ml/proof_pairs_hook.ML`) intercepts the compilation to export proof steps (goal states and Sledgehammer/MePo facts) using the `Proof_Context_Exporter` as PIDE exports.
2. **Parsing (Phase 2)**: Scans the exported data and the original theory sources to reconstruct the surrounding proof blocks and emit a structured JSON file per theory.

```
isabelle process_theories                 (adhoc session driver)
  └─ Proof_Pairs_Hook.thy + exporter       (registers custom hook)
       └─ Build.add_hook                   (intercepts proof steps)
            └─ Proof_Context_Exporter      (exports goal state + MePo facts)
  └─ PIDE exports on disk
        └─ Phase 2 Parser                  (merges exports + source into JSON)
```

## Per-session grouping (automatic base)

Theories are grouped by their session, and each group is re-elaborated on **that
session's parent** (looked up from the session structure). So everything below
the session loads prebuilt and only the session's own theories re-run:

- `HOL-Lattice.*` → base `HOL`
- `HOL-Number_Theory.*` → base `HOL-Computational_Algebra`
- `HOL.{List,Transcendental,Bit_Operations}` → base `Pure`

No manual `-l` and no split theory files — one list works for all sessions,
including the core-HOL theories. (`-l NAME` overrides the base for every group.)

A proof *state* never exists in a prebuilt heap — it only exists while a proof
runs — so the target theory (and any same-session neighbour it imports) must be
re-elaborated; only *lower* sessions are supplied prebuilt.

## Usage

```bash
# a couple of theories, no facts (fast):
isabelle proof_pairs HOL-Lattice.CompleteLattice HOL-Lattice.Lattice

# all selected theories, 32 MePo facts per goal:
isabelle proof_pairs -m 32 -T theories.txt -d out

# leaf proofs only (atomic terminal steps, no structural `proof` wrappers):
isabelle proof_pairs -L -m 32 -T theories.txt -d out_leaf

# exclude proofs containing any 'apply' command:
isabelle proof_pairs -A -T theories.txt -d out_no_apply
```

Output: `<out>/json/<Theory>.json`, plus the raw PIDE exports under
`<out>/export/`.

Options: `-L` leaf proofs only, `-A` exclude proofs containing any 'apply'
command, `-c N` cap `proof_text_before` to its last N
Isabelle symbols (`0` = full), `-l` base override (default: each session's
parent), `-m` facts per goal (`0` = skip sledgehammer), `-T` theory-list file
(qualified names, `#` comments), `-d` output dir, `-o` system option override,
`-v` verbose.

`-c` truncates on a symbol boundary (counting Isabelle symbols like
`\<forall>` as one), keeping the most recent context before the step, so symbol
sequences are never cut mid-way.

A step is a **leaf** if its innermost enclosing proof block has no nested
sub-proofs — i.e. the atomic terminal steps (`by …`, `.`, `..`), not the
structural `proof` commands that wrap sub-proofs. With `-L`, non-leaf steps are
skipped **inside the hook, before MePo runs**, so leaf-only extraction with
facts costs about half as much (MePo only fires on the leaves). Every record
still carries an `is_leaf` field.

## Recommended defaults (Qwen 7/8B fine-tuning)

Calibrated against a ~4096-token training sequence (`tiktoken` proxy):
`suggested_facts` ≈ 0.32 tok/symbol, facts(16) ≈ 500 tok, `state_before` ≈ 80 tok.

- **`-m 16`** — ~500 tokens of relevance-filtered facts per goal.
- **`-c 4000`** — caps `proof_text_before` at ~1300 tokens, keeping full
  examples ≈ 1900 tok median / 2300 p90, comfortably within a 4K window.

```bash
isabelle proof_pairs -L -m 16 -c 4000 -T theories.txt -d out
```

Scale: ~25k leaf records across the 41 theories, ≈ 6 h wall-clock (MePo on
leaves only).

## Theory lists

- `theories.txt` — list of all 41 selected theories.
- `theories_2k.txt` — curated subset of high-quality theories targeting ~2,000 goals.

## Output schema (per record)

| field | meaning |
| :-- | :-- |
| `theory`, `line`, `offset` | location of the proof step |
| `command` | command keyword (`by`, `proof`, `apply`, …) |
| `state_before` | goal state the step is applied to |
| `proof_text_before` | theory source up to the step |
| `proof_block`, `proof_commands` | the enclosing proof block / its commands |
| `suggested_facts` | MePo-selected facts (`name`, `statement`); empty if `-m 0` |
| `is_leaf` | whether the step's innermost proof block has no sub-proofs |

> [!NOTE]
> All output string fields are automatically decoded from Isabelle symbol escape syntax (e.g. `\<Longrightarrow>`) into clean UTF-8 Unicode characters (e.g. `⟹`). This saves up to 40% in token count and is optimal for LLM fine-tuning.

## Files

- `etc/build.props`, `etc/settings`, `etc/options` — component definition
- `src/proof_pairs.scala` — extract (phase 1) + parse (phase 2)
- `src/proof_context_parser.scala` — XML parser for the exporter's output
- `src/tools.scala` — `isabelle proof_pairs` tool wrapper
- `ml/proof_pairs_hook.ML` — the custom `Build.add_hook` (+ leaf detection)
- `ml/proof_context_exporter.ML` — goal-state + MePo-facts exporter
- `ml/Proof_Pairs_Hook.thy` — loads the exporter + hook into the Draft session
