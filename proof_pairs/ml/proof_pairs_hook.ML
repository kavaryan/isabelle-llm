(*  Title:      proof_pairs/ml/proof_pairs_hook.ML
    Author:     isabelle-llm

A build presentation hook (Build.add_hook) that exports a goal-state node and,
optionally, MePo-suggested facts for every proof step of the requested
theories. It is the Mirabelle presentation hook stripped to the essentials:
crucially it selects theories by their fully-qualified name
(proof_pairs_theories) rather than by the session qualifier, so it also fires
on theories re-elaborated inside an adhoc "Draft" session (as produced by
`isabelle process_theories`). Goal state and facts are produced by the shared
Proof_Context_Exporter and emitted as one structured PIDE export per goal,
"proof_pairs/<line>/<offset>", a <proof_pair> node carrying theory/command/line
as attributes with the goal-state and facts nodes as children.

When proof_pairs_leaf_only is set, non-leaf steps are skipped *before* the
(expensive) MePo call -- a leaf step is one whose innermost enclosing proof
block has no nested sub-proofs. The block structure mirrors the Scala
find_proof_blocks (cf. proof_pairs.scala).
*)

structure Proof_Pairs_Hook =
struct

(* proof commands whose pre-state is exported (cf. mirabelle_subgoals) *)
val considered_commands = ["apply", "by", "proof", "unfolding", "using"];

(* (start, stop) index pairs of proof blocks: openers are theory-goal /
   proof-open commands, closers are proof-close / qed commands *)
fun command_blocks keywords segments =
  let
    fun is_open name =
      Keyword.is_theory_goal keywords name orelse Keyword.is_proof_open keywords name;
    fun is_close name =
      Keyword.is_proof_close keywords name orelse Keyword.is_qed_global keywords name;
    fun step (i, seg) (stack, blocks) =
      let
        val name = Toplevel.name_of (#command seg);
        val stack' = if is_open name then i :: stack else stack;
      in
        if is_close name then
          (case stack' of s :: rest => (rest, (s, i) :: blocks) | [] => (stack', blocks))
        else (stack', blocks)
      end;
  in #2 (fold step (map_index I segments) ([], [])) end;

(* a step is a leaf iff its innermost enclosing block has no nested block *)
fun is_leaf_step blocks i =
  (case filter (fn (s, e) => s <= i andalso i <= e) blocks of
    [] => true
  | containing =>
      let val inner = hd (sort (fn (a, b) => int_ord (#2 a - #1 a, #2 b - #1 b)) containing)
      in not (exists (fn b => b <> inner andalso #1 inner <= #1 b andalso #2 b <= #2 inner) blocks) end);

fun export_step max_facts thy_long_name leaf_only blocks (i, seg) =
  let
    val tr = #command seg;
    val st = #prev_state seg;
    val name = Toplevel.name_of tr;
    val pos = Toplevel.pos_of tr;
  in
    if member (op =) considered_commands name andalso
       can (Proof.assert_backward o Toplevel.proof_of) st andalso
       (not leaf_only orelse is_leaf_step blocks i)
    then
      let
        val pre = Toplevel.proof_of st;
        val thy = Proof.theory_of pre;
        val line = the_default 0 (Position.line_of pos);
        val offset = the_default 0 (Position.offset_of pos);
        (* one structured node per goal: metadata as attributes, with the
           goal-state node and (optionally) the suggested-facts node as
           children -- all produced by the shared Proof_Context_Exporter *)
        fun build () =
          let
            val children =
              Proof_Context_Exporter.make_goal_state_node pre pos ::
              (if max_facts > 0
               then [Proof_Context_Exporter.make_sledgehammer_facts_node pre max_facts []]
               else []);
            val node =
              XML.Elem (("proof_pair",
                [("theory", thy_long_name), ("command", name),
                 ("line", string_of_int line)]), children);
            val binding =
              Path.binding0 (Path.basic "proof_pairs" +
                Path.basic (string_of_int line) + Path.basic (string_of_int offset));
          in Export.export thy binding [XML.Text (YXML.string_of node)] end;
        (* tolerate per-goal failures (e.g. sledgehammer) without aborting the
           build; `try` ignores ordinary exceptions but re-raises interrupts *)
      in ignore (try build ()) end
    else ()
  end;

val _ =
  Build.add_hook (fn _ => fn loaded_theories =>
    let
      val targets =
        space_explode "," (Options.default_string \<^system_option>\<open>proof_pairs_theories\<close>);
      val max_facts = Options.default_int \<^system_option>\<open>proof_pairs_max_facts\<close>;
      val leaf_only = Options.default_bool \<^system_option>\<open>proof_pairs_leaf_only\<close>;
    in
      if null targets orelse forall (fn s => s = "") targets then ()
      else
        loaded_theories
        |> List.app (fn (thy, segments) =>
            let val thy_long_name = Context.theory_long_name thy in
              if member (op =) targets thy_long_name then
                let
                  val blocks =
                    if leaf_only then command_blocks (Thy_Header.get_keywords thy) segments else [];
                in
                  List.app (export_step max_facts thy_long_name leaf_only blocks)
                    (map_index I segments)
                end
              else ()
            end)
    end);

end;
