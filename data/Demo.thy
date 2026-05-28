theory Demo
    imports Main
begin

definition double :: "nat => nat" where
  "double n = 2 * n"

lemma "double n = n + n"
    sorry


end