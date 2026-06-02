# Programmatic Isabelle Proof Pair Exporter

This tool is a programmatic data-extraction pipeline built in **Isabelle/Scala** and **Isabelle/ML**. It hooks into Isabelle's native PIDE (Prover IDE) runtime and the Mirabelle batch execution system to extract detailed syntactic and semantic data from proof states.

The generated dataset is structured specifically for training machine learning models (like Large Language Models) for interactive theorem proving tasks.

---

## Features

*   **Syntax-Aware Proof Slices:** Leverages Isabelle's parser (`Outer_Syntax.parse_spans`) and symbol offsets to slice out exact tactics and history context.
*   **Proof Block Extraction:** Recursively tracks opening and closing proof commands using Isabelle's native `Keyword` kinds to output complete remaining proof steps (`proof_block` and `proof_commands`).
*   **Leaf Proof Filtering:** Includes an option to discard top-level or parent proof blocks, exporting only "Leaf" proofs (blocks containing no subproofs).
*   **Sledgehammer Integration:** Performs MePo fact selection at each proof step to supply suggested facts.
*   **Valid JSON Arrays:** Generates theory-specific valid JSON arrays (`<Theory_Name>.json`) for direct parsing in external tools.
*   **Clean Status Logging:** Redirects execution progress and system warning logs to a unified `mirabelle.log`.

---

## Files

*   `extract_mirabelle.scala`: The main Scala entrypoint script that compiles heaps, initiates the Mirabelle driver, consumes prover messages, runs syntactic analysis, and writes JSON files.
*   `mirabelle_custom.ML`: The ML-side registration of the custom Mirabelle actions (`goal_state_export` and `sledgehammer_export`).
*   `proof_context_exporter.ML`: Modular ML functions to print the goal state, resolve facts, and format standard XML/YXML payloads.
*   `proof_context_parser.scala`: Shared XML parser utility to decode the custom tags.

---

## Usage

Run the exporter from the command line using the Isabelle Scala compiler:

```bash
isabelle scala extract_mirabelle.scala <session> [output_dir] [max_facts] [leaf_only]
```

### Arguments:
1.  **`<session>`** *(Required)*: The name of the Isabelle session to process (e.g. `Dataset`).
2.  **`[output_dir]`** *(Optional, default: `out_custom_scala`)*: The directory where logs and JSON databases will be saved.
3.  **`[max_facts]`** *(Optional, default: `32`)*: Maximum number of Sledgehammer suggested facts to export per goal state. If set to `0`, Sledgehammer is bypassed completely for faster execution.
4.  **`[leaf_only]`** *(Optional, default: `false`)*: Set to `true` (or `1`) to export only leaf proofs (i.e. discard proof steps belonging to blocks containing nested subproofs).

### Example Commands:
```bash
# Export all proof pairs and up to 3 sledgehammer facts:
isabelle scala extract_mirabelle.scala Dataset out_custom_scala 3 false

# Export only leaf proof steps (e.g., discard outer theorem proof blocks):
isabelle scala extract_mirabelle.scala Dataset out_custom_scala 3 true
```

---

## Output Structure

The output directory contains:

1.  **`<Theory_Name>.json`**: A valid JSON array file for each processed theory.
2.  **`mirabelle.log`**: Standard stdout/stderr build logs, warning warnings, and progress indicators from the Isabelle build system.

### Database JSON Schema (`<Theory_Name>.json`)

Each entry in the array corresponds to an intercepted tactic state and contains:

| Field Name | Type | Description |
| :--- | :--- | :--- |
| `theory` | `string` | Full name of the theory (e.g., `Dataset.Simple`). |
| `line` | `integer` | 1-indexed line number of the command transition. |
| `offset` | `integer` | 1-based character/symbol offset of the command. |
| `command` | `string` | The active goal command type (e.g. `proof`, `by`, `apply`). |
| `cpu_ms` | `integer` | Time elapsed in milliseconds during this step. |
| `proof_text_before` | `string` | Raw theory source file content up to the current command. |
| `state_before` | `string` | The Isabelle proof context/goal state before executing the tactic. |
| `tactic_source` | `string` | The raw text of the tactic/command executed at this step (e.g., `by auto`). |
| `suggested_facts` | `array` | A list of objects containing `name` and `statement` for Sledgehammer suggestions. |
| `proof_block` | `string` | Concatenated text of the remaining proof block until it is finished. |
| `proof_commands` | `array[string]` | Clean list of trimmed individual commands in the remaining proof block. |

---

## Proof Block Nesting and Leaf Proofs

### Structural Keywords:
*   **Openers:** `Keyword.theory_goal` (e.g. `theorem`, `lemma`) and `Keyword.proof_open` (e.g. `have`, `show`).
*   **Closers:** `Keyword.proof_close` (e.g. `qed`, `by`, `done`, `sorry`, `.`, `..`) and `Keyword.qed_global` (e.g. `oops`).

### Leaf Proofs:
A proof block is classified as a **Leaf Proof** if there are no subproofs (other proof blocks) nested inside its span boundaries. Under `leaf_only = true` mode, the exporter filters out all non-leaf proof steps, keeping only the final atomic proof steps and simple proofs.

---

## Isabelle/jEdit LLM Suggestions Subfolder (`llm_suggestions/`)

The [llm_suggestions](llm_suggestions) subfolder contains a companion **Isabelle/jEdit IDE plugin** designed to provide real-time, interactive LLM-based tactic suggestions to the user as they write proofs in the IDE.

### Structure:
*   [llm_suggestions_plugin.scala](llm_suggestions/src/llm_suggestions_plugin.scala): Lifecycle manager and entry point for registering the jEdit plugin.
*   [llm_suggestions_dockable.scala](llm_suggestions/src/llm_suggestions_dockable.scala): The Swing-based IDE dockable panel UI that displays suggestions and allows the user to insert or apply suggested tactics.
*   [llm_providers.scala](llm_suggestions/src/llm_providers.scala): The LLM client layer that queries providers (such as OpenAI, Gemini, or local models) using standard HTTP POST payloads.
*   [llm_verify.ML](llm_suggestions/llm_verify.ML) / [LLM_Verify.thy](llm_suggestions/LLM_Verify.thy): Underlying proof kernel verification utilities to dry-run/check LLM-suggested tactics before applying them.
*   [plugin.props](llm_suggestions/plugin.props) / [dockables.xml](llm_suggestions/dockables.xml): Configuration and properties descriptors used by jEdit to initialize the panel.
