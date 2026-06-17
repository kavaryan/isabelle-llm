# TODO:
- [Sel4 paper](https://arxiv.org/pdf/2603.19715): Neuro-Symbolic Proof Generation for Scaling Systems Software Verification

# Reinforcement learning for formal theorem proving

This directory collects papers on verifier-guided learning and search for formal
theorem proving. The comparison emphasizes **compute required versus improvement
obtained**. Numbers are those reported by the papers; they are not normalized
across hardware, proof assistants, datasets, or inference budgets.

The requested titles "ProofSeek" and "Neural Theorem Proving: Generating and
Structuring Proofs for Formal Verification" refer to the same paper, so there
are six unique PDFs in [`lit/`](lit/).

## Main comparison

| Work | Assistant | Base model | Main approach | Training data / signal | Reported training compute | Inference / search compute | Main reported improvement |
|---|---|---:|---|---|---|---|---|
| [ProD: hierarchical proof decomposition](lit/dong-2024-hierarchical-proof-decomposition.pdf) ([arXiv](https://arxiv.org/abs/2411.01829)) | Isabelle | Llemma-7B | Whole-proof generation with model-proposed lemmas; REINFORCE rewards correct proof subtrees and novel proved lemmas | 300k SFT examples; 20 RL rounds over 5k examples; 37.7% of replay-buffer lemmas were newly proposed | SFT: 8 A100-80GB GPU-days; one RL experiment: about 30 GPU-hours; paper summarizes total as under 36 GPU-days | Pass@16; depth-2 trees for 4k tests take 1-2 h on 8 A5000s | ProD-SFT to ProD-RL: AFP test **40.8% to 45.5%** (+4.7 pp, +11.5% relative); AFP 2023 **36.5% to 39.5%** (+3.0 pp). Worse than the direct SFT baseline on highly OOD miniF2F |
| [ProofSeek / Neural Theorem Proving](lit/rao-2025-proofseek.pdf) ([arXiv](https://arxiv.org/abs/2504.17017)) | Isabelle | DeepSeek-Math-7B-RL | SFT with LoRA, then verifier-rewarded GRPO; whole-proof generation plus ProofAug-style heuristic proof construction | FVELER filtered through PISA; exact retained train size and training duration are not clearly reported | Hardware reported: 1 A40-48GB plus 2 RTX A6000 across two machines; GPU-hours not reported | 10 samples; 4 PISA workers; 10 s tactic and 40 s Sledgehammer limits | Generated AWS policies: **66.6% to 69.1%** (+2.5 pp) and 24:36 to 20:27 runtime versus DeepSeek without ERP. On miniF2F, essentially tied: **41.8% vs 41.8%** without ERP; with ERP, 41.8% vs 42.2% |
| [STP](lit/dong-2025-stp.pdf) ([arXiv](https://arxiv.org/abs/2502.00212)) | Lean and Isabelle | DeepSeek-Prover-V1.5-SFT (Lean); Llemma-7B (Isabelle) | Self-play between a conjecturer and prover; trains on barely provable, relevant conjectures to make verifier rewards denser | Lean: 48 iterations, 3.6M conjectures, 241M proofs, **51.3B generated tokens**; Isabelle: 58 iterations, about 300M proofs | TPU-v4 VMs: 32 nodes × 4 chips = 128 chips; wall time / total TPU-days not reported. About 75% of TPU wall time is proof generation | Whole-proof pass@128 to pass@25,600; headline results use pass@3,200 | LeanWorkbook cumulative solve rate **13.2% to 28.5%** versus expert iteration (+15.3 pp, 2.16×). At pass@3,200, miniF2F **54.9% to 65.0%** (+10.1 pp) and ProofNet **22.0% to 23.9%** (+1.9 pp) versus DeepSeek-Prover-V1.5-RL |
| [Isabellm](lit/hou-2026-isabellm.pdf) ([arXiv](https://arxiv.org/abs/2601.04653)) | Isabelle | Pluggable local/API LLM | Bounded stepwise beam search, tactic reranking, premise selection, micro-RAG, Isar outline planning, fill and repair | Search logs can train small supervised/offline-RL rerankers and premise models; no end-to-end LLM training run is reported | Tested on a 2021 M1 Pro MacBook Pro with 32GB RAM; no large training compute reported | Typically 3-8 candidate commands per call under configurable depth/time budgets | Qualitative examples beat Sledgehammer on selected goals, but **no benchmark-wide success-rate improvement is reported**. Planner repair is described as rarely succeeding beyond trivial cases |
| [AlphaProof](lit/hubert-2025-alphaproof.pdf) ([Nature](https://www.nature.com/articles/s41586-025-09833-y)) | Lean | 3B encoder-decoder proof network | AlphaZero-style tactic policy/value network with AND-OR tree search; massive autoformalization; test-time RL (TTRL) on target-specific variants | 300B-token pretraining; 300k Mathlib state-tactic pairs; about 1M informal problems expanded to about 80M formal problems | Main RL: **about 80,000 TPU v6e-days** (example: 4,000 TPUs for 20 days); autoformalization/pretraining compute not fully rolled into this number | From 2 TPU-min to 12 TPU-h per problem; TTRL from 50 to **500 TPU-days per problem** | From 2 min search to 500-day TTRL: formal-IMO **33.2% to 58.3%** (+25.1 pp), PutnamBench-test **27.9% to 56.1%** (+28.2 pp). At IMO 2024, AlphaProof solved 3/5 non-geometry problems; combined system scored 28/42, silver-medal level |
| [PhysProver](lit/zhang-2026-physprover.pdf) ([arXiv](https://arxiv.org/abs/2601.15737)) | Lean | DeepSeek-Prover-V2-7B | Domain adaptation using GRPO/RLVR with binary Lean-verifier reward and easy-to-hard curriculum | 2,933 PhysLean seeds + 2,608 verified synthetic conjectures = **5,541 examples** | **8 H200 GPUs for about 8 h = 64 GPU-hours**, 2 epochs, batch 256 | Pass@16 | Physics test overall **34.0% to 36.4%** (+2.4 pp, +7.1% relative); MiniF2F-test **+1.3 pp**. Plain SFT hurt by 6.4 pp; rejection-sampling FT gave +1.6 pp |

pp = percentage points.

## Compute-efficiency reading

1. **Best clearly reported low-compute gain: PhysProver.** A 64 GPU-hour RL
   run on only 5,541 examples gives +2.4 pp in-domain and +1.3 pp on miniF2F.
   This is a narrow domain adaptation result, not a general prover trained from
   scratch. Its synthetic-data generation also uses Claude and three provers,
   whose compute is not included in the 64 GPU-hours.

2. **ProD gives a larger in-domain gain on modest hardware.** Its +4.7 pp AFP
   gain uses a 7B model and tens rather than thousands of GPU-days. The useful
   signal comes from verified partial proof trees. The gain shrinks under
   distribution shift, and ProD-RL loses to direct SFT on miniF2F.

3. **STP spends far more compute but changes the scaling curve.** Its strongest
   result is not merely a small benchmark gain: conjecturing makes nearly half
   of generated conjectures provable where ordinary expert iteration produced
   only 131 successes from 2.5M attempts on remaining hard Isabelle statements.
   The cost is 51.3B generated Lean tokens and hundreds of millions of proofs.
   Exact TPU-days are missing, which prevents a clean cost-per-point estimate.

4. **AlphaProof has the highest capability and by far the highest cost.** The
   80,000 TPU-day main RL run is amortized over problems. Peak results add up to
   500 TPU-days of problem-specific TTRL for each target. Standard search alone
   is much cheaper and already strong, but the final Olympiad-level result is not
   representative of an affordable local prover.

5. **ProofSeek and Isabellm are primarily systems papers.** ProofSeek reports
   available hardware and end-to-end evaluation runtime but not training hours,
   making training efficiency impossible to quantify. Isabellm deliberately
   targets consumer hardware, but offers selected examples rather than a
   controlled aggregate benchmark, so no numerical improvement should be
   inferred.

## Important comparison caveats

- **Pass@k is a compute parameter.** A pass@3,200 result is not directly
  comparable to pass@16 or pass@1. STP's headline scores require 3,200 complete
  proofs per theorem; AlphaProof reports actual TPU time; ProD uses proof trees.
- **Training and inference compute are separate.** AlphaProof's table excludes
  the amortized 80,000 TPU-day main RL run from per-problem inference cost.
- **Benchmarks and versions differ.** AlphaProof uses a corrected miniF2F
  version. ProofSeek's table says 245 miniF2F problems although the standard
  split has 244, so its percentages should be read as reported rather than
  silently corrected.
- **Starting models differ substantially.** PhysProver starts from a strong
  specialist prover; ProD starts from Llemma-7B; STP's Lean experiment starts
  from DeepSeek-Prover-V1.5-SFT; AlphaProof includes 300B-token pretraining.
- **Generated-data costs are often omitted.** PhysProver's Claude conjectures,
  ProofSeek's data preparation, and AlphaProof's autoformalization add material
  cost beyond the headline RL training numbers.
- **Domain scope differs.** AFP library proofs, Olympiad mathematics, AWS
  policies, and formal physics measure different capabilities. Percentage-point
  gains should be compared within each row, not ranked globally.

## Papers

| File | Bibliographic note |
|---|---|
| [`dong-2024-hierarchical-proof-decomposition.pdf`](lit/dong-2024-hierarchical-proof-decomposition.pdf) | Dong, Mahankali, and Ma, 2024 |
| [`rao-2025-proofseek.pdf`](lit/rao-2025-proofseek.pdf) | Rao, Eiers, and Lipizzi, 2025; the ProofSeek paper |
| [`dong-2025-stp.pdf`](lit/dong-2025-stp.pdf) | Dong and Ma, ICML 2025 |
| [`hou-2026-isabellm.pdf`](lit/hou-2026-isabellm.pdf) | Hou, 2026 |
| [`hubert-2025-alphaproof.pdf`](lit/hubert-2025-alphaproof.pdf) | Hubert et al., published online in 2025; Nature issue dated 19 March 2026 |
| [`zhang-2026-physprover.pdf`](lit/zhang-2026-physprover.pdf) | Zhang et al., 2026 |

