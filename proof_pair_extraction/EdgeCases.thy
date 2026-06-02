theory EdgeCases
  imports Main Proof_Context_Command
begin

theorem t_sorry: "A \<longrightarrow> A"
  sorry

theorem t_oops: "A \<longrightarrow> A"
  oops

theorem t_done: "A \<longrightarrow> A"
  apply (rule impI)
  apply assumption
  done

theorem t_by: "A \<longrightarrow> A"
  by (rule impI)

theorem t_dot: "A \<Longrightarrow> A"
  by assumption

theorem t_nested: "A \<and> B \<Longrightarrow> A \<and> B"
proof -
  assume H: "A \<and> B"
  have A: "A" using H by (rule conjunct1)
  have B: "B" using H sorry
  from A B show "A \<and> B" by (rule conjI)
qed

end
