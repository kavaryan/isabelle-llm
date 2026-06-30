(*  Title:      goals/src/Goals_Queries.thy
    Author:     Maximilian Schaeffeler

ML query operations for the goal tools: goal selectability, MePo facts, whether
try0 / sledgehammer close a goal, and batch candidate checking. Valid in HOL and
descendants.
*)

theory Goals_Queries
  imports Main
begin

ML \<open>
(* register an urgent query op that requires a proof state, passing both the
   toplevel state and the proof to the handler (raising otherwise) *)
fun register_proof_query name f =
  Query_Operation.register {name = name, pri = Task_Queue.urgent_pri}
    (fn {state, args, writeln_result, ...} =>
      (case try Toplevel.proof_of state of
        SOME proof => f {state = state, proof = proof, args = args, writeln_result = writeln_result}
      | NONE => error "Not in a proof state"));
\<close>

ML \<open>
(* MePo-ranked facts as "name [attrs]: statement" lines *)
local
  fun relevant_facts ctxt thy chained_ths hyp_ts concl_t max_facts =
    let
      val params = Sledgehammer_Commands.default_params thy [];
      val keywords = Thy_Header.get_keywords' ctxt;
      val css_table = Sledgehammer_Fact.clasimpset_rule_table_of ctxt;
    in
      Sledgehammer_Fact.nearly_all_facts ctxt false
        Sledgehammer_Fact.no_fact_override keywords css_table chained_ths hyp_ts concl_t
      |> Sledgehammer_Fact.drop_duplicate_facts
      |> Sledgehammer_MePo.mepo_suggested_facts ctxt params max_facts NONE hyp_ts concl_t
    end;

  fun fact_line ctxt ((name, (_, status)), thm) =
    let
      val stmt = space_implode " " (split_lines (Pretty.pure_string_of (Thm.pretty_thm ctxt thm)));
      val attrs =
        (if status = ATP_Problem_Generate.Simp then ["simp"] else []) @
        (if status = ATP_Problem_Generate.Intro then ["intro"] else []) @
        (if status = ATP_Problem_Generate.Elim then ["elim"] else []);
      val display = if null attrs then name else name ^ " [" ^ space_implode "," attrs ^ "]";
    in display ^ ": " ^ stmt end;

  fun rich_facts max_facts state =
    let
      val ctxt = Proof.context_of state;
      val thy = Proof.theory_of state;
      val {facts = chained_ths, goal, ...} = Proof.goal state;
      val (_, hyp_ts, concl_t) = ATP_Util.strip_subgoal goal 1 ctxt;
    in cat_lines (map (fact_line ctxt) (relevant_facts ctxt thy chained_ths hyp_ts concl_t max_facts)) end;
in
  val _ =
    register_proof_query "suggested_facts_rich"
      (fn {proof, args, writeln_result, ...} =>
        let val max_facts = (case args of n :: _ => the_default 32 (Int.fromString n) | _ => 32)
        in writeln_result (rich_facts max_facts proof) end);
end
\<close>

ML \<open>
(* the state before the command is an open backward proof with a remaining subgoal *)
val _ =
  Query_Operation.register {name = "selectable", pri = Task_Queue.urgent_pri}
    (fn {state, writeln_result, ...} =>
      writeln_result
        (case try Toplevel.proof_of state of
          SOME p =>
            if can Proof.assert_backward p andalso Thm.nprems_of (#goal (Proof.goal p)) > 0
            then "1" else "0"
        | NONE => "0"));
\<close>

ML ‹
(* "1"/"" whether a single try0 method closes the goal *)
val _ =
  register_proof_query "try0_closes"
    (fn {proof, args, writeln_result, ...} =>
      let
        val secs = (case args of t :: _ => the_default 10 (Int.fromString t) | _ => 10);
        val ((found, _), _) =
          Try0.generic_try0 Try0.Try (SOME (Time.fromSeconds secs)) Try0.empty_facts proof;
      in writeln_result (if found then "1" else "") end);
›

ML ‹
(* "1"/"" whether sledgehammer closes the goal; kind = "methods" (tactic provers only)
   or "all". Driven like the interactive sledgehammer (silence_state, same params). *)
local
  fun silence_state state =
    Proof.map_contexts (Try0_HOL.silence_methods #> Config.put SMT_Config.verbose false) state;

  fun run_hammer kind secs state =
    let
      val thy = Proof.theory_of state;
      val provers =
        if kind = "methods" then ["metis", "simp", "auto", "blast", "fastforce", "force"]
        else #provers (Sledgehammer_Commands.default_params thy []);
      val params =
        Sledgehammer_Commands.default_params thy
          [("provers", space_implode " " provers), ("timeout", string_of_int secs),
           ("isar_proofs", "smart"), ("try0", "false"),
           ("debug", "false"), ("verbose", "false"), ("overlord", "false")];
    in
      not (null provers) andalso
      fst (Sledgehammer.run_sledgehammer params Sledgehammer_Prover.Normal NONE 1
        Sledgehammer_Fact.no_fact_override (silence_state state))
    end;
in
  (* sledgehammer only attacks subgoal 1, so a multi-subgoal state never counts *)
  val _ =
    register_proof_query "sledgehammer_closes"
      (fn {proof, args, writeln_result, ...} =>
        let
          val (kind, secs) =
            (case args of k :: t :: _ => (k, the_default 30 (Int.fromString t)) | _ => ("all", 30))
          val solved =
            Thm.nprems_of (#goal (Proof.goal proof)) <= 1 andalso run_hammer kind secs proof
        in writeln_result (if solved then "1" else "") end);
end
›

ML \<open>
(* batch: run each candidate on the goal state; "1" iff it discharges all current goals.
   args = [secs, cand...]; one verdict line per candidate, in order. *)
val _ =
  register_proof_query "speculate_check_many"
    (fn {state = st, args, writeln_result, ...} =>
      let
        val (secs, cands) =
          (case args of t :: cs => (the_default 5 (Int.fromString t), cs) | _ => (5, []));
        fun run_all [] s = SOME s
          | run_all (tr :: r) s =
              (case Toplevel.command_errors tr s of ([], SOME s') => run_all r s' | _ => NONE);
        fun discharged s' =
          not (Toplevel.is_proof s') orelse
          (case try Toplevel.proof_of s' of SOME p => can Proof.assert_forward p | NONE => true);
        fun closes c =
          let val trs = Outer_Syntax.parse_text (Toplevel.theory_of st) (K (Toplevel.theory_of st)) Position.start c in
            not (null trs)
            andalso not (exists (fn tr => member (op =) ["sorry", "oops"] (Toplevel.name_of tr)) trs)
            andalso (case Interactive.setmp_parallel_proofs 0
                (Timeout.apply (Time.fromSeconds secs) (fn () => run_all trs st)) () of
              SOME s' => discharged s' | NONE => false)
          end handle Timeout.TIMEOUT _ => false | ERROR _ => false;
      in writeln_result (cat_lines (Par_List.map (fn c => if closes c then "1" else "0") cands)) end);
\<close>

end
