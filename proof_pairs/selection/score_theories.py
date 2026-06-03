#!/usr/bin/env python3
"""Score Isabelle .thy files by proof style to curate a high-quality,
structured-Isar training corpus (and down-rank messy apply-script theories).

Heuristic, source-text based (no prover needed). For each theory we count
command-like keywords and derive an "Isar ratio". This is intended as a
*ranking/filtering* aid, not ground truth -- spot-check the top results.

Usage:
    python3 score_theories.py /opt/Isabelle2025-2/src/HOL [--csv out.csv] [--top N]
"""
from __future__ import annotations
import argparse
import csv
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Keywords that mark *structured Isar* reasoning (the style we want).
ISAR_KEYWORDS = [
    "proof", "qed", "show", "have", "obtain", "fix", "assume", "presume",
    "case", "next", "moreover", "ultimately", "also", "finally", "thus",
    "hence", "with", "from", "let", "consider", "define",
]
# Keywords that mark *apply-script* / low-structure proofs (the style we avoid).
APPLY_KEYWORDS = ["apply", "done", "back", "defer", "prefer", "apply_end"]
# Incomplete / placeholder proofs -- a sign the theory is a draft.
BAD_KEYWORDS = ["sorry", "oops"]
# Proof goal openers -- used to size the theory by how much it proves.
GOAL_KEYWORDS = [
    "lemma", "theorem", "corollary", "proposition", "lemmas",
]

# Match a keyword only when it stands as a command token: at a line start or
# after whitespace, followed by a non-word char. Avoids matching inside
# identifiers like "applyP" or "have_foo".
def _kw_regex(words: list[str]) -> re.Pattern:
    alt = "|".join(re.escape(w) for w in words)
    return re.compile(rf"(?:(?<=\s)|^)(?:{alt})(?=\s|$|\(|\[|\{{)", re.MULTILINE)

ISAR_RE = _kw_regex(ISAR_KEYWORDS)
APPLY_RE = _kw_regex(APPLY_KEYWORDS)
BAD_RE = _kw_regex(BAD_KEYWORDS)
GOAL_RE = _kw_regex(GOAL_KEYWORDS)
BY_RE = _kw_regex(["by"])

# Strip (* ... *) comments (nested) and text cartouches \<open>...\<close> so
# prose/comments don't pollute keyword counts.
COMMENT_RE = re.compile(r"\(\*.*?\*\)", re.DOTALL)
CARTOUCHE_RE = re.compile(r"\\<open>.*?\\<close>", re.DOTALL)


def strip_noise(text: str) -> str:
    # Repeatedly remove comments to approximate nesting.
    prev = None
    while prev != text:
        prev = text
        text = COMMENT_RE.sub(" ", text)
    text = CARTOUCHE_RE.sub(" ", text)
    return text


@dataclass
class Score:
    path: Path
    rel: str
    loc: int = 0
    goals: int = 0
    isar: int = 0
    apply: int = 0
    by: int = 0
    bad: int = 0

    @property
    def isar_ratio(self) -> float:
        denom = self.isar + self.apply
        return self.isar / denom if denom else 0.0

    @property
    def has_proofs(self) -> bool:
        return self.goals > 0 and (self.isar + self.apply + self.by) > 0

    # Composite quality score in [0,1]-ish. Rewards structured Isar, penalises
    # apply-density and any sorry/oops. Only meaningful for files with proofs.
    @property
    def quality(self) -> float:
        if not self.has_proofs:
            return 0.0
        score = self.isar_ratio
        if self.bad:
            score *= 0.3  # drafts with sorry/oops are heavily penalised
        return round(score, 4)


def score_file(path: Path, root: Path) -> Score:
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = strip_noise(raw)
    s = Score(path=path, rel=str(path.relative_to(root)))
    s.loc = raw.count("\n") + 1
    s.goals = len(GOAL_RE.findall(text))
    s.isar = len(ISAR_RE.findall(text))
    s.apply = len(APPLY_RE.findall(text))
    s.by = len(BY_RE.findall(text))
    s.bad = len(BAD_RE.findall(text))
    return s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", type=Path)
    ap.add_argument("--csv", type=Path, default=None)
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--min-goals", type=int, default=10,
                    help="ignore theories with fewer proof goals")
    ap.add_argument("--min-ratio", type=float, default=0.85,
                    help="min Isar ratio to count as high-quality")
    args = ap.parse_args()

    files = sorted(args.root.rglob("*.thy"))
    scores = [score_file(f, args.root) for f in files]

    qualifying = [
        s for s in scores
        if s.goals >= args.min_goals and s.bad == 0
        and s.isar_ratio >= args.min_ratio
    ]
    qualifying.sort(key=lambda s: (s.quality, s.goals), reverse=True)

    print(f"Scanned {len(scores)} theories under {args.root}")
    print(f"{len(qualifying)} qualify "
          f"(>= {args.min_goals} goals, isar_ratio >= {args.min_ratio}, no sorry/oops)\n")
    hdr = f"{'quality':>7}  {'ratio':>5}  {'goals':>5}  {'isar':>5}  {'apply':>5}  {'by':>5}  path"
    print(hdr)
    print("-" * len(hdr))
    for s in qualifying[: args.top]:
        print(f"{s.quality:7.3f}  {s.isar_ratio:5.2f}  {s.goals:5d}  "
              f"{s.isar:5d}  {s.apply:5d}  {s.by:5d}  {s.rel}")

    if args.csv:
        with args.csv.open("w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["rel", "loc", "goals", "isar", "apply", "by",
                        "bad", "isar_ratio", "quality"])
            for s in sorted(scores, key=lambda s: s.quality, reverse=True):
                w.writerow([s.rel, s.loc, s.goals, s.isar, s.apply, s.by,
                            s.bad, round(s.isar_ratio, 4), s.quality])
        print(f"\nFull table for all {len(scores)} theories -> {args.csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
