# Isabelle Proof SFT Data

This directory contains JSONL splits generated from `extractor/proof_extractor_out/json`
with `../prompt_jinja2_template.py`.

Regenerate the split with:

```bash
python3 isabelle-llm/sft/sft-data/prepare_sft_data.py
```

The split is deterministic with seed `42` and a `20/80` test/train ratio.
The generator targets `max_seq_length=2048`; when an example is too long, it
truncates the beginning of `proof_text_before` and keeps the local tail nearest
to the proof state and target proof.

* `train.jsonl`
* `test.jsonl`
* `dataset_info.json`

Each row includes `prompt`, `completion`, and `text`. `prompt` is rendered from
`PROMPT_TEMPLATE`; `completion` is rendered from `COMPLETION_TEMPLATE`, which
defaults to the extractor record's raw `proof_block`. `text` is an inspection
field equal to `prompt + "\n" + completion`.

The split is model-agnostic. Model-specific chat formatting is applied by the
training script with the selected tokenizer's `apply_chat_template()`.

`sft/slurm/train_model_trl.py` prefers `prompt`/`completion` for local JSONL
datasets, applies the selected tokenizer chat template, and enables
completion-only loss by default, so training loss is applied only to the
assistant proof tokens. `text` remains available for inspection and backward
compatibility.

Example:

```bash
python isabelle-llm/sft/slurm/train_model_trl.py \
  --model Qwen/Qwen3-0.6B \
  --dataset isabelle-llm/sft/sft-data \
  --split train \
  --output-dir /tmp/isabelle-sft/out \
  --merged-output-dir /tmp/isabelle-sft/merged
```
