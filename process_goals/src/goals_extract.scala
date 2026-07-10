/*  Title:      goals/src/goals_extract.scala
    Author:     Maximilian Schaeffeler

Probe that extracts proof-pair training data: per goal, its state, the preceding
theory text, and the relevant facts, as one JSON record per goal.
*/

package isabelle.goals

import isabelle._


class Extract_Probe(max_symbols: Int, leaf_only: Boolean, no_apply: Boolean)
  extends Probe[Goals_Output.Record] {
  def name = "extract"
  override def description = "proof-pair records (state, context, facts) per goal"

  // a fact line "name [attrs]: statement" -> {name, statement}
  private def fact_json(line: String): JSON.T = {
    val i = line.indexOf(": ")
    if (i < 0) JSON.Object("name" -> line, "statement" -> "")
    else JSON.Object("name" -> line.substring(0, i).nn, "statement" -> line.substring(i + 2).nn)
  }

  def apply(c: Probe.Context): Option[Goals_Output.Record] = {
    val info = c.block
    if ((leaf_only && !info.is_leaf) || (no_apply && info.has_apply)) None
    else Some(Goals_Output.Record(
      theory = c.theory, line = c.site.line, offset = c.site.offset, command = c.site.name,
      state_before = c.goal_state, proof_text_before = c.text_before(max_symbols),
      suggested_facts = c.facts.map(fact_json), proof_block = info.block,
      proof_commands = info.commands, is_leaf = info.is_leaf))
  }

  // one JSON array per theory under <out>/json (rewritten after each theory)
  override def checkpoint(records: List[Goals_Output.Record], out: Path, progress: Progress): Unit =
    Goals_Output.write_records(out + Path.basic("json"), records)

  def finish(records: List[Goals_Output.Record], out: Path, progress: Progress): Unit = {
    checkpoint(records, out, progress)
    progress.echo("Wrote " + records.length + " records -> " + (out + Path.basic("json")))
  }
}


object Goals_Extract {
  val isabelle_tool = Isabelle_Tool("goals_extract",
    "extract proof-pair training data (state, context, facts) from theories",
    Scala_Project.here,
    { args =>
      val common = new Goals_Args.Common
      val selection = new Goals_Args.Selection
      var out = Path.explode("goals_extract")
      var max_facts = 0
      var max_symbols = 0
      var leaf_only = false
      var no_apply = false

      val getopts = Getopts("""
Usage: isabelle goals_extract [OPTIONS] THEORIES...

  Options are:
    -A           exclude proofs containing any 'apply' command
    -F FACTS     relevant facts per goal (default 0 = none)
    -G           restrict to top-level goals (not nested inside another proof block)
    -L           keep only leaf proofs (innermost block has no nested sub-proof)
    -N           restrict to nested goals (excludes one-liners like 'by simp'/'unfolding x by simp')
    -O DIR       output directory (default goals_extract)
    -T FILE      read theory names from FILE (one per line, # comments); repeatable
    -c N         limit preceding theory text to its last N symbols (0 = full)
    -d DIR       include session directory
    -l NAME      logic session name (default """ + quote(Isabelle_System.default_logic()) + """)
    -m N         max goals per theory (0 = all)
    -o OPTION    override Isabelle system OPTION
    -s N         keep every Nth goal (default 1)
    -v           verbose

  Write one JSON record per goal of THEORIES to DIR/json/<Theory>.json.
""",
        (common.getopts ::: selection.getopts ::: List[(String, String => Unit)](
          "A" -> (_ => no_apply = true),
          "F:" -> (arg => max_facts = Value.Int.parse(arg)),
          "L" -> (_ => leaf_only = true),
          "O:" -> (arg => out = Path.explode(arg)),
          "c:" -> (arg => max_symbols = Value.Int.parse(arg)))): _*)

      val theories = common.theories(getopts(args))
      if (theories.isEmpty) getopts.usage()
      val probe = new Extract_Probe(max_symbols, leaf_only, no_apply)
      val progress = common.progress
      progress.interrupt_handler {
        Goals_Run.run(common.logic, common.dirs, common.options, theories, selection.selector,
          probe, Nil, max_facts, Time.seconds(30.0), out, progress)
      }
    })
}

class Goals_Extract_Tool extends Isabelle_Scala_Tools(Goals_Extract.isabelle_tool)
