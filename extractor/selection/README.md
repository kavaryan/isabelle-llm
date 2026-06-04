# Theory selection

How `../theories.txt` (the 41 curated theories) was produced — heuristic,
source-text based, no prover needed.

## Pipeline

1. **`score_theories.py`** — scans every `.thy` in the HOL distribution and
   scores it by proof style (structured-Isar vs apply-script density, `sorry`
   count). Writes the full table.

   ```bash
   python3 score_theories.py /opt/Isabelle2025-2/src/HOL --csv theory_scores.csv
   ```
   → `theory_scores.csv`

2. **`select_by_steps.py`** — from the scored theories, builds a
   domain-diverse selection of terminal `by`-step targets, capping each theory's
   contribution and round-robining across sessions so no single area dominates.

   ```bash
   python3 select_by_steps.py theory_scores.csv --budget 2000 --whitelist selection_2k.txt
   ```
   → `selection_2k.txt` (per-theory budget), grouped by session into
   `selection_by_session.tsv`.

3. **`../theories.txt`** — the qualified theory names (`Session.Theory`),
   derived from `selection_by_session.tsv`:

   ```bash
   awk -F'\t' '!/^#/ && NF==2 {n=split($2,a,","); for(i=1;i<=n;i++) print $1"."a[i]}' \
     selection_by_session.tsv > ../theories.txt
   ```

## Files

- `score_theories.py`, `theory_scores.csv` — scoring step + its output
- `select_by_steps.py`, `selection_2k.txt`, `selection_by_session.tsv` — selection step + outputs
- `select_oneliners.py`, `oneliner_counts.csv` — alternative variant counting
  only *top-level* one-liner proofs (superseded by `select_by_steps.py`, which
  also counts structured-proof leaves)
