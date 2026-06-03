#!/usr/bin/env python3
"""Build a domain-diverse selection of terminal `by`-step training targets
(top-level one-liners AND `have/show ... by ...` leaves inside structured
proofs) targeting a budget (~2000 steps).

Reads theory_scores.csv (produced by score_theories.py); the `by` column is
the count of terminal `by` steps per theory. Selection caps each theory's
contribution and round-robins across domains so vocabulary stays diverse and
no single large theory dominates.

Usage:
    python3 select_by_steps.py theory_scores.csv \
        [--budget 2000] [--cap 50] [--whitelist selection_2k.txt]
"""
from __future__ import annotations
import argparse
import csv
from collections import defaultdict
from pathlib import Path

# Diverse Tier-1 domains (clean Isar, no sorry/oops, broad term vocabulary).
DOMAINS = [
    ".", "Analysis", "Algebra", "Computational_Algebra", "Complex_Analysis",
    "Number_Theory", "Combinatorics", "Cardinals", "Decision_Procs",
    "Data_Structures", "Homology", "Isar_Examples", "Hahn_Banach",
    "Lattice", "Library", "Probability",
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", type=Path)
    ap.add_argument("--budget", type=int, default=2000)
    ap.add_argument("--cap", type=int, default=50,
                    help="max by-steps counted per theory (subsample at "
                         "extraction); smaller => more theories => more diverse")
    ap.add_argument("--min", type=int, default=10,
                    help="ignore theories with fewer than this many by-steps")
    ap.add_argument("--whitelist", type=Path, default=None)
    args = ap.parse_args()

    rows = list(csv.DictReader(args.csv.open()))
    by_dom: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        rel = r["rel"]
        dom = rel.split("/")[0] if "/" in rel else "."
        if dom not in DOMAINS:
            continue
        if int(r["bad"]) != 0:          # drop any sorry/oops drafts
            continue
        by = int(r["by"])
        if by < args.min:
            continue
        r["_dom"], r["_by"] = dom, by
        by_dom[dom].append(r)
    for lst in by_dom.values():
        lst.sort(key=lambda r: r["_by"], reverse=True)

    # Round-robin across domains; each theory contributes min(by, cap).
    selected: list[tuple[dict, int]] = []
    total = 0
    cursors = {d: 0 for d in by_dom}
    active = [d for d in DOMAINS if d in by_dom]
    while total < args.budget and active:
        for d in list(active):
            if total >= args.budget:
                break
            c = cursors[d]
            if c >= len(by_dom[d]):
                active.remove(d)
                continue
            cursors[d] += 1
            r = by_dom[d][c]
            take = min(r["_by"], args.cap, args.budget - total)
            selected.append((r, take))
            total += take

    sel_dom_steps: dict[str, int] = defaultdict(int)
    sel_dom_thys: dict[str, int] = defaultdict(int)
    for r, take in selected:
        sel_dom_steps[r["_dom"]] += take
        sel_dom_thys[r["_dom"]] += 1

    print(f"=== Selection: {len(selected)} theories, ~{total} by-step targets "
          f"(budget {args.budget}, per-theory cap {args.cap}) ===\n")
    print(f"{'domain':24} {'thys':>4} {'steps':>6}")
    print("-" * 38)
    for d in sorted(sel_dom_steps, key=lambda d: -sel_dom_steps[d]):
        print(f"{d:24} {sel_dom_thys[d]:>4} {sel_dom_steps[d]:>6}")

    if args.whitelist:
        with args.whitelist.open("w") as fh:
            fh.write("# rel\tby_steps_available\ttake\n")
            for r, take in sorted(selected, key=lambda x: x[0]["rel"]):
                fh.write(f"{r['rel']}\t{r['_by']}\t{take}\n")
        print(f"\nWhitelist ({len(selected)} theories) -> {args.whitelist}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
