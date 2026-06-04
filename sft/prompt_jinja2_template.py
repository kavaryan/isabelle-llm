PROMPT_TEMPLATE = """You are an expert Isabelle/HOL proof assistant. Complete the current subgoal in the unfinished proof using a single one-liner command sequence.

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

<unfinished_theory>
{{ proof_text_before }}
</unfinished_theory>

<proof_state>
{{ state_before }}
</proof_state>

{% if suggested_facts -%}
<suggested_facts>
{{ suggested_facts }}
</suggested_facts>
{%- endif %}

Return only the raw Isabelle proof without any extra token.
"""

COMPLETION_TEMPLATE = """{{ proof_block }}"""
