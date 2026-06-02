theory LLM_Verify
  imports Main
begin

(* Reuse the existing goal-state + MePo relevant-facts extractor. *)
ML_file \<open>../proof_context_exporter.ML\<close>
ML_file \<open>llm_verify.ML\<close>

end
