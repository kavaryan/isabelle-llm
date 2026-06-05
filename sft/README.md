# Supervised Fine-Tuning (SFT) Resources

This directory contains resources for formatting extracted Isabelle proof-step datasets into prompt/completion pairs for training or fine-tuning Large Language Models.

## Contents

*   [prompt_jinja2_template.py](prompt_jinja2_template.py) — Defines `PROMPT_TEMPLATE` and `COMPLETION_TEMPLATE` Jinja2 strings used to format exported proof-pair JSON objects.

## Template Variables

The extractor outputs JSON files where each proof record contains the following variables used by the template:

*   `proof_text_before`: The raw Isabelle theory text leading up to the targeted proof step.
*   `state_before`: The exact goal state output from the Isabelle compiler right before the proof step is executed.
*   `suggested_facts` (Optional): A list of relevant facts/lemmas suggested by Isabelle's relevance filter (MePo).
*   `proof_block`: The target Isabelle proof text for the completion side.

## Dataset Application

For downstream fine-tuning, render the raw prompt/completion split first. The model-specific tokenizer chat template should be applied by the training script for the exact base model being fine-tuned.


## TODO
- [ ] update montior script shows a better summary with -f on out and err files
- [ ] pretraining (i.e., before training) loss and vllm?

- [x] use ssh multiplexing to speed up interacting with HPC
For Host:
Host create-mx
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m

Openning: ssh -Nf create-mx
Closing : ssh -O exit create-mx
Commands: ssh create-mx 'for i in {1..10}; do echo $i; done'

- [x] smoke test
`./submit_finetune_model.sh --smoke-test --gpu-profile l40s --monitor`

- [x] truncation, max-seq-len statistics script
./submit_sft_token_stats.sh --gpu-profile l40s --monitor
then ssh create and look at scratch/...-<job-id>.out:
train token stats after chat template: count=1986 mean=2129.00 std=278.92 min=624 q1=2048 median=2163 q3=2280 max=2719 <=max_seq_length(3072)=1986 >3072=0
test token stats after chat template: count=497 mean=2114.05 std=290.67 min=830 q1=2028 median=2144 q3=2269 max=2859 <=max_seq_length(3072)=497 >3072=0

- [x] calculate and show eval loss in wandb
- [x] make sure script copies new code, data etc to the remote:
Then submit_slurm_job.sh runs:
`rsync -avz "$SOURCE_DIR/" "$CREATE_HOST:$remote_dir/"`
with `REMOTE_DIR=~/$(basename "$SOURCE_DIR")`
Since `SOURCE_DIR` is `.../sft`, the default remote destination is:
`create:~/sft/`

- [x] where script logs and models are saved?
    o logs in /scratch/users/<k-number>/<job-id>.{err,out}
    o models in ~/ai4math/finetunes