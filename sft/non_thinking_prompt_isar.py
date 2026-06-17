PROMPT_TEMPLATE = """You are an expert Isabelle/HOL proof assistant. Complete the unfinished proof with a valid Isar proof.

CRITICAL RULES:
1. The completion may span multiple lines and may use structured Isar commands such as `proof`, `qed`, `have`, `show`, `fix`, `assume`, `next`, `obtain`, and `thus`.
2. Produce exactly the proof text needed at the end of the unfinished theory. It may be a direct method proof such as `by <method>` or a complete structured block from `proof` through `qed`.
3. The completion MUST close the current proof and all subgoals it introduces.
4. Do NOT use interactive, diagnostic, or unfinished commands (e.g., `apply`, `sledgehammer`, `sorry`, `oops`, `try0`).
5. Output ONLY the raw Isabelle proof text. Do not include explanations, markdown code blocks, comments, or a preamble.

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

Return only the raw Isabelle proof, preserving any necessary line breaks and indentation, without any extra text.
"""

COMPLETION_TEMPLATE = """{{ proof_block }}"""
