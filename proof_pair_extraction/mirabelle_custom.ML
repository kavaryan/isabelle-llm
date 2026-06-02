structure Mirabelle_Custom =
struct

fun make_goal_state_action _ =
  let
    fun run ({pos, pre, ...} : Mirabelle.command) =
      let
        val payload = Proof_Context_Exporter.make_goal_state_node pre pos
      in
        YXML.string_of payload
      end
    fun finalize () = ""
  in
    ("Initialized custom goal_state_export action", {run = run, finalize = finalize})
  end

fun make_sledgehammer_action ({arguments, ...} : Mirabelle.action_context) =
  let
    val max_facts_param =
      AList.lookup (op =) arguments "max_facts"
      |> Option.map (the o Int.fromString)
      |> the_default 32

    fun run ({pre, ...} : Mirabelle.command) =
      let
        val payload = Proof_Context_Exporter.make_sledgehammer_facts_node pre max_facts_param arguments
      in
        YXML.string_of payload
      end
    fun finalize () = ""
  in
    ("Initialized custom sledgehammer_export action", {run = run, finalize = finalize})
  end

(* --- Register Actions --- *)
val () = Mirabelle.register_action "goal_state_export" make_goal_state_action
val () = Mirabelle.register_action "sledgehammer_export" make_sledgehammer_action

end


