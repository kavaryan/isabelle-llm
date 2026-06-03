/*  Title:      proof_pairs/src/tools.scala
    Author:     isabelle-llm

Command-line tool wrapper: `isabelle proof_pairs`.
*/

package isabelle.proof_pairs

import isabelle._


object Proof_Pairs_Tool {
  val isabelle_tool =
    Isabelle_Tool("proof_pairs",
      "extract proof-pair training data from theories via an adhoc process_theories session",
      Scala_Project.here,
      { args =>
        var logic: Option[String] = None
        var max_facts = 0
        var output_dir = Path.explode("proof_pairs_out")
        var options = Options.init()
        var theory_files: List[Path] = Nil
        var leaf_only = false
        var context_symbols = 0
        var verbose = false

        val getopts = Getopts("""
Usage: isabelle proof_pairs [OPTIONS] [THEORIES...]

  Options are:
    -T FILE      read qualified theory names from FILE (one per line, # comments);
                 repeatable, combined with any THEORIES given as arguments
    -L           keep only leaf proofs (steps whose innermost proof block has
                 no nested sub-proofs)
    -c N         limit proof_text_before to its last N symbols (default 0 = full)
    -l NAME      base logic for all sessions (default: each session's parent)
    -m FACTS     sledgehammer relevance facts per goal (default 0 = no sledgehammer)
    -o OPTION    override Isabelle system OPTION (via NAME=VAL or NAME)
    -d DIR       output directory (default: """ + output_dir + """)
    -v           verbose mode

  Extract proof-pair training data (goal state, proof block, and optionally
  relevance-filtered facts) for the given theories, named as
  qualified names (e.g. HOL-Analysis.Starlike). Theories are grouped by session
  and each group is re-elaborated on that session's parent, so everything below
  the session is supplied prebuilt. Results: <DIR>/json/<Theory>.json.

  Examples:
    isabelle proof_pairs HOL-Lattice.CompleteLattice HOL-Lattice.Lattice
    isabelle proof_pairs -m 32 -T theories.txt -d out
""",
          "T:" -> (arg => theory_files = theory_files ::: List(Path.explode(arg))),
          "L" -> (_ => leaf_only = true),
          "c:" -> (arg => context_symbols = Value.Int.parse(arg)),
          "l:" -> (arg => logic = Some(arg)),
          "m:" -> (arg => max_facts = Value.Int.parse(arg)),
          "o:" -> (arg => options = options + arg),
          "d:" -> (arg => output_dir = Path.explode(arg)),
          "v" -> (_ => verbose = true))

        val arg_theories = getopts(args)
        val file_theories = theory_files.flatMap(Proof_Pairs.read_theories)
        val theories = (file_theories ::: arg_theories).distinct

        val progress = new Console_Progress(verbose = verbose)

        progress.interrupt_handler {
          Proof_Pairs.proof_pairs(options, logic, theories, max_facts, output_dir,
            leaf_only = leaf_only, context_symbols = context_symbols, progress = progress)
        }
      })
}

class Tools extends Isabelle_Scala_Tools(Proof_Pairs_Tool.isabelle_tool)
