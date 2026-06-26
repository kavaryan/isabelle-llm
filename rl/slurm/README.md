# Isabelle GRPO on Slurm

This directory runs TRL `GRPOTrainer` on the Isabelle proof split, defaulting to
`Qwen/Qwen3-0.6B`. The reward is verifier based: each generated trajectory is
checked by `check_isabelle_reward.py`, which reconstructs the extracted
`proof_text_before`, inserts the sampled completion, and runs `isabelle build`
on a temporary session. Exit code `0` means reward `1.0`.

Example:

```bash
./install_isabelle_hpc.sh

./submit_grpo_model.sh \
  --gpu-profile l40s \
  --max-steps 200 \
  --num-generations 4 \
  --monitor
```

The checker uses `source_file` and `source_index` from each training row to load
the corresponding extractor record from `extractor/proof_extractor_out/json`.
On CREATE, `install_isabelle_hpc.sh` installs Isabelle and AFP under
`/scratch/users/$USER/ai4math`, then edits Isabelle's `etc/settings` so
`ISABELLE_HOME_USER` points at
`/scratch/users/$USER/ai4math/isabelle-home-user/Isabelle2025-2`. Isabelle uses
that directory for user settings and heap images; leaving it at the upstream
default would write heap files under `$HOME/.isabelle`, which can exceed the
home quota.

Set `--isabelle /path/to/isabelle` or export `ISABELLE` if using a different
install. Set `--reward-extra-dirs` so the temporary session can resolve AFP
imports, and set `--theory-session-map` if using a different extractor corpus.

Useful smoke run:

```bash
./install_isabelle_hpc.sh --reward-smoke
./submit_grpo_model.sh --smoke-test --monitor
```

## SQLite hotel-tool agent

`grpo-tools.py` reproduces the hotel-booking tool-agent example with a real
SQLite database instead of PostgreSQL. It exposes name/location search,
booking, date update, and cancellation functions directly to `GRPOTrainer`.

Submit it to CREATE with W&B logging:

```bash
./submit_grpo_tools.sh --smoke-test --monitor
./submit_grpo_tools.sh --gpu-profile l40s --wandb-run-name hotel-sqlite-grpo --monitor
```

The job reads W&B credentials from `../../sft/slurm/wandb.conf.sh`, following
the existing SFT/GRPO convention. Outputs are written below
`$HOME/ai4math/grpo-tools/<run-name>/`, including `hotels.sqlite3`, the LoRA
adapter, and a merged checkpoint.
