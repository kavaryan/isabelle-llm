theory Proof_Context_Command
  imports Main
  keywords "print_proof_context" :: diag
begin

ML_file "proof_context_exporter.ML"
ML_file "proof_context_command.ML"

end
