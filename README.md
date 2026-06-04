# Trainig data
We can use:
- [ ] docker run --rm   -v "$PWD":/home/isabelle/work   makarius/isabelle:Isabelle2025-2   process_theories -O -D /home/isabelle/work Hello
- [ ] https://isabelle.in.tum.de/dist/Isabelle2025-2/doc/system.pdf


--
SFT Template:
You're an experienced Isabelle/HOL proof engineer with good grasp of math and computer science algorithms.
Please complete the following proof.
Theory file ending with the fact to proof: {e.proof_text_before}
Proof state: {e.state_before}
{if suggested_facts: 'Suggested facts:' {suggested_facts} else ''}

<Prompt to continue>
{e.proof_block}




