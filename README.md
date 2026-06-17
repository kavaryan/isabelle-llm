# Isabelle/HOL LLM Integration

This repository provides tools and plugins to integrate Large Language Models (LLMs) with the Isabelle/HOL interactive theorem prover. It supports both offline training data extraction and online interactive proof assistance.

## Directory Structure

*   [extractor/](extractor): A custom Isabelle component and Scala/ML CLI tool (`isabelle proof_extractor`) to extract proof-step datasets (enclosing proof blocks, goal states, tactics, and relevance-filtered sledgehammer facts) from Isabelle theories into structured JSON files.
*   [jedit-plugin/](jedit-plugin): An Isabelle/jEdit IDE plugin that adds a panel to suggest real-time tactics and proofs using local or remote LLM backends.
*   [sft/](sft): Supervised Fine-Tuning (SFT) resources, including prompt templates for formatting extracted proof pairs into LLM instruction-following datasets.

---

## Supervised Fine-Tuning (SFT) Template

Prompt templates format extracted proof pairs for training. The standard non-thinking template is located at [sft/non_thinking_prompt.py](sft/non_thinking_prompt.py) and defines `PROMPT_TEMPLATE` plus `COMPLETION_TEMPLATE`:

```jinja2
You are an expert Isabelle/HOL proof assistant. Complete the current subgoal in the unfinished proof using a single one-liner command sequence.

CRITICAL RULES:
1. The completion MUST be a single line containing at most one `by` invocation, optionally preceded by `using` or `unfolding` clauses.
2. Allowed formats:
   - `by <method>`
   - `using <facts> by <method>`
   - `unfolding <definitions> by <method>`
   - `using <facts> unfolding <definitions> by <method>`
3. Do NOT use multi-step or structural proof commands (e.g., `proof`, `qed`, `have`, `show`, `fix`, `assume`, `next`, `obtain`).
4. Do NOT use interactive, diagnostic, or unfinished commands (e.g., `apply`, `sledgehammer`, `sorry`, `oops`, `try0`).
5. Output ONLY the raw Isabelle proof text to complete the proof. Do not include any explanations, markdown code blocks, comments, or preamble.

<context_theory>
{{ proof_text_before }}
</context_theory>

<proof_state>
{{ state_before }}
</proof_state>

{% if suggested_facts -%}
<suggested_facts>
{{ suggested_facts }}
</suggested_facts>
{%- endif %}

<unfinished_proof>
{{ proof_block }}
</unfinished_proof>

Complete the proof:
```

---

## Getting Started

### 1. Proof Step Extraction
To extract datasets from your Isabelle theories:
```bash
# Register the extractor component
isabelle components -u /path/to/isabelle-llm/extractor

# Rebuild Scala tools
isabelle scala_build

# Run the extractor
isabelle proof_extractor -m 16 -c 4000 -T theories.txt -d out
```
See the [extractor README](extractor/README.md) for usage options and output schemas.

### 2. IDE Suggestions Plugin
To use interactive LLM recommendations in Isabelle/jEdit:
```bash
# Register the plugin component
isabelle components -u /path/to/isabelle-llm/jedit-plugin
```
Once registered, the plugin will load on Isabelle startup and expose the **LLM Suggestions** dockable panel in jEdit.


## SFT steps
0. `cd isabelle-llm`
1. Put extracted json pairs in `extractor/proof_extractor_out/json/*.json`
2. Run `sft/sft-data$ ./prepare_sft_data.py` to generare train.json and test.json
3. Run `sft/slurm/submit_finetune_model.sh` to submit an SFT job on HPC and get a job id
4. Run `sft/slurm//monitor_slurm_job.sh <job-id>` to monitor the job 