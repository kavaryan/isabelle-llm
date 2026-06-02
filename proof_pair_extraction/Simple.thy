theory Simple
  imports Main Proof_Context_Command
begin

theorem \<open> rev [x, y, z] = [z, y, x] \<close>
proof -
  print_proof_context
  have \<open>subresult\<close> sorry

  have \<open>rev [x, y, z] = rev [y, z] @ [x]\<close> by auto
  also have \<open>\<dots> = rev [z] @ [y, x]\<close> by auto
  also have \<open>\<dots> = [z, y, x] \<close> by auto
  finally show ?thesis .
qed

definition xyz :: "nat \<Rightarrow> nat" where
  "xyz x = x + x"

theorem double_2: \<open>xyz 2 = 4\<close>
  by (metis xyz_def numeral_Bit0)

end
