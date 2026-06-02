(* Title: llm_verify.ML
   Author: Maximilian Schaeffeler

   Query_Operations for the LLM Suggestions panel:

   * "llm_context" -- extract the current goal state and the relevant MePo
     facts, reusing Proof_Context_Exporter (see ../proof_context_exporter.ML).
     Returns the YXML of a <proof_context> node via writeln_result.

   * "llm_verify" -- verify a suggested proof by running it through the normal
     Isar command pipeline on the current proof state. The argument is the
     full proof text (a tactic like "by simp", an "apply ... done" script, or a
     structured "proof ... qed" block).
*)

val () =
  Query_Operation.register {name = "llm_context", pri = Task_Queue.urgent_pri}
    (fn {state, args, writeln_result, ...} =>
      let
        val max_facts =
          case args of s :: _ => the_default 10 (Int.fromString s) | [] => 10
        val _ =
          if not (Toplevel.is_proof state)
          then error "llm_context: not inside a proof"
          else ()
        val prf = Toplevel.proof_of state
        val pos = Position.thread_data ()
        val goal_xml = Proof_Context_Exporter.make_goal_state_node prf pos
        val facts_xml = Proof_Context_Exporter.make_sledgehammer_facts_node prf max_facts []
        val xml = XML.Elem (("proof_context", []), [goal_xml, facts_xml])
      in
        writeln_result (YXML.string_of_body [xml])
      end)

val () =
  Query_Operation.register {name = "llm_verify", pri = Task_Queue.urgent_pri}
    (fn {state, args, writeln_result, ...} =>
      let
        val proof_text =
          case args of s :: _ => s | [] => ""
        val thy = Toplevel.theory_of state
        val timeout = seconds 2.0
        val result =
          if not (Toplevel.is_proof state) then
            "UNVERIFIED: not inside a proof"
          else if proof_text = "" then
            "UNVERIFIED: no proof given"
          else
            let
              val text' = "using [[quick_and_dirty]]\n" ^ proof_text
              val transitions =
                Outer_Syntax.parse_text thy (fn () => thy) Position.none text'
              fun run_transition (tr, st) =
                let
                  val old = ! Multithreading.parallel_proofs
                  val _ = Multithreading.parallel_proofs := Int.min (2, old)
                  val st' = Toplevel.command_exception false tr st
                  val _ = Multithreading.parallel_proofs := old
                in st' end
              val st' =
                Timeout.apply timeout
                  (List.foldl (fn (tr, st) => run_transition (tr, st)) state)
                  transitions
                handle Timeout.TIMEOUT _ =>
                  error ("reconstruction timed out after " ^ Time.toString timeout)
              val state_text =
                Pretty.string_of (Pretty.chunks (Toplevel.pretty_state st'))
              val header =
                if Toplevel.is_proof st' then
                  let val {goal, ...} = Proof.goal (Toplevel.proof_of st')
                  in "PROOF_STATE " ^ Int.toString (Thm.nprems_of goal) end
                else "PROOF_COMPLETE 0"
            in
              header ^ "\n" ^ state_text
            end
            handle Timeout.TIMEOUT _ => "UNVERIFIED: reconstruction timed out"
                 | ERROR msg => "UNVERIFIED: " ^ msg
                 | exn => "UNVERIFIED: " ^ Runtime.exn_message exn
      in
        writeln_result result
      end)
