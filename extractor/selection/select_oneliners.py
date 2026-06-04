#!/usr/bin/env python3
"""Count single-step *terminal* proof goals ("one-liners") per theory and
build a domain-diverse selection targeting a goal budget (default ~2000).

A one-liner goal = a lemma/theorem/corollary/proposition whose whole proof is
a single terminal step (`by <method>`, `.`, `..`), possibly preceded by
`using`/`unfolding`/`supply` modifiers -- with NO `proof`/`apply` block.

This is a source-level *budgeting estimate*. The authoritative count comes
from the PIDE/Mirabelle pipeline (proof_commands == 1). Use this to decide
which theories to feed and how many one-liners to expect.

Usage:
    python3 select_oneliners.py /opt/Isabelle2025-2/src/HOL \
        [--budget 2000] [--csv oneliner_counts.csv] [--whitelist selection.txt]
"""
from __future__ import annotations
import argparse
import csv
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

# Diverse Tier-1 domains (clean Isar, no sorry, broad vocabulary spread).
DOMAINS = [
    ".", "Analysis", "Algebra", "Computational_Algebra", "Complex_Analysis",
    "Number_Theory", "Combinatorics", "Cardinals", "Decision_Procs",
    "Data_Structures", "Homology", "Isar_Examples", "Hahn_Banach",
    "Lattice", "Library", "Probability",
]

GOAL_OPENERS = ["lemma", "theorem", "corollary", "proposition"]
GOAL_RE = re.compile(rf"(?:(?<=\s)|^)(?:{'|'.join(GOAL_OPENERS)})(?=\s)",
                     re.MULTILINE)
# First *structural* proof token after a goal => NOT a one-liner.
STRUCT_RE = re.compile(r"(?:(?<=\s)|^)(?:proof|apply)(?=\s|$|\(|\[)",
                       re.MULTILINE)
# Terminal single-step proof tokens.
TERMINAL_RE = re.compile(r"(?:(?<=\s)|^)(?:by(?=\s|\()|\.\.(?=\s|$)|\.(?=\s|$))",
                         re.MULTILINE)
SORRY_RE = re.compile(r"(?:(?<=\s)|^)(?:sorry|oops)(?=\s|$)", re.MULTILINE)

COMMENT_RE = re.compile(r"\(\*.*?\*\)", re.DOTALL)
CARTOUCHE_RE = re.compile(r"\\<open>.*?\\<close>", re.DOTALL)


def strip_noise(text: str) -> str:
    prev = None
    while prev != text:
        prev = text
        text = COMMENT_RE.sub(" ", text)
    return CARTOUCHE_RE.sub(" ", text)


@dataclass
class Th:
    rel: str
    domain: str
    goals: int = 0
    oneliners: int = 0
    structured: int = 0
    has_sorry: bool = False


def analyse(path: Path, root: Path) -> Th:
    rel = str(path.relative_to(root))
    domain = rel.split("/")[0] if "/" in rel else "."
    text = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
    th = Th(rel=rel, domain=domain, has_sorry=bool(SORRY_RE.search(text)))
    opens = [m.start() for m in GOAL_RE.finditer(text)]
    opens.append(len(text))
    for i in range(len(opens) - 1):
        region = text[opens[i] + 5 : opens[i + 1]]  # skip the opener word
        th.goals += 1
        sm = STRUCT_RE.search(region)
        tm = TERMINAL_RE.search(region)
        if tm and (not sm or tm.start() < sm.start()):
            th.oneliners += 1
        elif sm:
            th.structured += 1
    return th


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", type=Path)
    ap.add_argument("--budget", type=int, default=2000)
    ap.add_argument("--csv", type=Path, default=None)
    ap.add_argument("--whitelist", type=Path, default=None)
    args = ap.parse_args()

    ths = [analyse(p, args.root) for p in sorted(args.root.rglob("*.thy"))]
    # Keep only clean, in-domain theories with a meaningful one-liner count.
    pool = [t for t in ths
            if t.domain in DOMAINS and not t.has_sorry and t.oneliners >= 5]

    by_dom: dict[str, list[Th]] = defaultdict(list)
    for t in pool:
        by_dom[t.domain].append(t)
    for lst in by_dom.values():
        lst.sort(key=lambda t: t.oneliners, reverse=True)

    print(f"Scanned {len(ths)} theories; {len(pool)} clean in-domain theories "
          f"with >=5 one-liners.\n")
    print(f"{'domain':24} {'thys':>4} {'one-liners':>11}")
    print("-" * 43)
    dom_totals = {d: sum(t.oneliners for t in by_dom[d]) for d in by_dom}
    for d in sorted(dom_totals, key=lambda d: -dom_totals[d]):
        print(f"{d:24} {len(by_dom[d]):>4} {dom_totals[d]:>11}")
    print(f"\nTotal one-liners available in pool: {sum(dom_totals.values())}")

    # Round-robin across domains for diversity: pick whole theories
    # (highest one-liner density first) until the budget is hit.
    selected: list[Th] = []
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
            t = by_dom[d][c]
            cursors[d] += 1
            selected.append(t)
            total += t.oneliners

    sel_by_dom: dict[str, int] = defaultdict(int)
    for t in selected:
        sel_by_dom[t.domain] += t.oneliners
    print(f"\n=== Selection: {len(selected)} theories, "
          f"~{total} one-liner goals (target {args.budget}) ===")
    print(f"{'domain':24} {'thys':>4} {'one-liners':>11}")
    print("-" * 43)
    for d in sorted(sel_by_dom, key=lambda d: -sel_by_dom[d]):
        n = sum(1 for t in selected if t.domain == d)
        print(f"{d:24} {n:>4} {sel_by_dom[d]:>11}")

    if args.whitelist:
        with args.whitelist.open("w") as fh:
            for t in sorted(selected, key=lambda t: t.rel):
                fh.write(f"{t.rel}\t{t.oneliners}\n")
        print(f"\nWhitelist ({len(selected)} theories) -> {args.whitelist}")
    if args.csv:
        with args.csv.open("w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["rel", "domain", "goals", "oneliners", "structured",
                        "has_sorry"])
            for t in sorted(ths, key=lambda t: t.oneliners, reverse=True):
                w.writerow([t.rel, t.domain, t.goals, t.oneliners,
                            t.structured, int(t.has_sorry)])
        print(f"Full per-theory table ({len(ths)}) -> {args.csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
