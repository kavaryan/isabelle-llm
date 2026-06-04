structure Proof_Context_Exporter =
struct

(* --- Modular Goal State Extractor --- *)
fun make_goal_state_node pre pos =
  let
    val pretty_state = Proof.pretty_state pre
    val state_str = Pretty.pure_string_of (Pretty.chunks pretty_state)
    
    val file_str = Option.valOf (Position.file_of pos) handle Option.Option => ""
    val offset_str = Option.map string_of_int (Position.offset_of pos) |> the_default ""
    
    val pos_node = XML.Elem (("position", [("file", file_str), ("offset", offset_str)]), [])
    val state_node = XML.Elem (("state", []), [XML.Text state_str])
  in
    XML.Elem (("proof_goal", []), [pos_node, state_node])
  end


(* --- Modular Sledgehammer Fact Extractor --- *)
fun get_mepo_facts ctxt thy chained_ths hyp_ts concl_t max_facts arguments =
  let
    val params = Sledgehammer_Commands.default_params thy arguments
    val keywords = Thy_Header.get_keywords' ctxt
    val css_table = Sledgehammer_Fact.clasimpset_rule_table_of ctxt
  in
    Sledgehammer_Fact.nearly_all_facts ctxt false
      Sledgehammer_Fact.no_fact_override keywords css_table chained_ths
      hyp_ts concl_t
    |> Sledgehammer_Fact.drop_duplicate_facts
    |> Sledgehammer_MePo.mepo_suggested_facts ctxt params
        max_facts
        NONE hyp_ts concl_t
  end

(* fact_info : string * (scope * status), stature = (scope, status)
   We read the status directly -- no extra lookups needed.

   [[name]] is the resolved fact identifier Sledgehammer uses:
   [[Sledgehammer_MePo.mepo_suggested_facts]] returns a [[Sledgehammer_Fact.fact]]
   whose name is already externalised (via [[get_name]] in sledgehammer_fact.ML).
   It is emitted verbatim -- do not run it through [[Facts.extern]] again, which
   expects an *internal* name and would re-hide an already-external one as
   "??.<name>" (cf. [[Long_Name.hidden]]). *)
fun format_fact ctxt ((name, (_, status)), thm) =
  let
    val stmt = Pretty.pure_string_of (Thm.pretty_thm ctxt thm)

    val is_simp  = (status = ATP_Problem_Generate.Simp)
    val is_intro = (status = ATP_Problem_Generate.Intro)
    val is_elim  = (status = ATP_Problem_Generate.Elim)

    val a0 = [("name", name)]
    val a1 = if is_simp  then ("simp",  "true") :: a0 else a0
    val a2 = if is_intro then ("intro", "true") :: a1 else a1
    val a3 = if is_elim  then ("elim",  "true") :: a2 else a2
  in
    XML.Elem (("fact", a3), [XML.Text stmt])
  end

fun make_sledgehammer_facts_node pre max_facts arguments =
  let
    val thy = Proof.theory_of pre
    (* Resolve facts as Sledgehammer does (cf. sledgehammer.ML, [[run_sledgehammer]]):
       the OUTER proof context [[Proof.context_of pre]], with only the chained
       facts and goal term taken from [[Proof.goal pre]]. *)
    val ctxt = Proof.context_of pre
    val {facts = chained_ths, goal, ...} = Proof.goal pre
    val subgoal = 1
    val (_, hyp_ts, concl_t) = ATP_Util.strip_subgoal goal subgoal ctxt

    val facts = get_mepo_facts ctxt thy chained_ths hyp_ts concl_t max_facts arguments
    val formatted_facts = map (format_fact ctxt) facts
  in
    XML.Elem (("suggested_facts", []), formatted_facts)
  end

end
