structure Proof_Context_Command =
struct

fun print_current_proof_context state =
  let
    val prf = Toplevel.proof_of state handle Fail _ => error "Not in proof mode"
    val pos = Position.thread_data ()
    val goal_xml = Proof_Context_Exporter.make_goal_state_node prf pos
    val facts_xml = Proof_Context_Exporter.make_sledgehammer_facts_node prf 3 []
  in
    Output.writeln (YXML.string_of (XML.Elem (("proof_context", []), [goal_xml, facts_xml])))
  end

val () =
  Outer_Syntax.command @{command_keyword "print_proof_context"} "extract current proof state and MePo facts"
    (Scan.succeed (Toplevel.keep print_current_proof_context))

end
