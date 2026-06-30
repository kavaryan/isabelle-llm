/*  Title:      goals/src/goals_filter.scala
    Author:     Maximilian Schaeffeler

Probe that keeps the goals try0 (and optionally sledgehammer) cannot close: a
"hard" benchmark whitelist consumed by goals_bench.
*/

package isabelle.goals

import isabelle._


class Filter_Probe(
  use_sledgehammer: Boolean, methods_only: Boolean, leaf_only: Boolean, no_apply: Boolean
) extends Probe[Goals_Output.Goal_Ref] {
  def name = "filter"
  override def description = "goals that try0 (optionally sledgehammer) cannot close"

  def apply(c: Probe.Context): Option[Goals_Output.Goal_Ref] = {
    val info = c.block
    if ((leaf_only && !info.is_leaf) || (no_apply && info.has_apply)) None
    else {
      c.progress.echo(cat_lines(c.tag ::
        Goals.preview(c.session, c.snapshot, c.struct, c.site, 2, 0, c.timeout)))
      def solves(label: String, op: String, args: List[String]): Boolean =
        try {
          val ok = c.closes(op, args)
          if (ok) c.progress.echo("  " + c.tag + " " + label + " closed")
          ok
        } catch {
          case exn: Throwable =>
            c.progress.echo("  " + c.tag + " " + label + " failed: " + exn.getMessage)
            false
        }
      // sledgehammer never closes a multi-subgoal state, so try0 alone decides those
      val easy =
        solves("try0", "try0_closes", List(c.secs)) ||
        (use_sledgehammer && solves("sledgehammer", "sledgehammer_closes",
          List(if (methods_only) "methods" else "all", c.secs)))
      if (easy) { c.progress.echo("  " + c.tag + " EASY"); None }
      else { c.progress.echo("  " + c.tag + " HARD"); Some(c.ref) }
    }
  }

  override def checkpoint(records: List[Goals_Output.Goal_Ref], out: Path, progress: Progress): Unit =
    Goals_Output.write_whitelist(out, records)

  def finish(records: List[Goals_Output.Goal_Ref], out: Path, progress: Progress): Unit = {
    checkpoint(records, out, progress)
    progress.echo("Wrote " + records.length + " hard goals -> " + out)
  }
}


object Goals_Filter {
  val isabelle_tool = Isabelle_Tool("goals_filter",
    "select goals that try0 (and optionally sledgehammer) cannot close",
    Scala_Project.here,
    { args =>
      val common = new Goals_Args.Common
      val selection = new Goals_Args.Selection
      var out = Path.explode("hard_goals.json")
      var use_sledgehammer = false
      var methods_only = false
      var leaf_only = false
      var no_apply = false
      var timeout = Time.seconds(30.0)

      val getopts = Getopts("""
Usage: isabelle goals_filter [OPTIONS] THEORIES...

  Options are:
    -A           exclude proofs containing any 'apply' command
    -H           also try sledgehammer (drop goals it closes)
    -L           keep only leaf proofs (innermost block has no nested sub-proof)
    -M           sledgehammer with built-in proof methods only
    -O FILE      output whitelist JSON (default hard_goals.json)
    -T FILE      read theory names from FILE (one per line, # comments); repeatable
    -d DIR       include session directory
    -l NAME      logic session name (default ISABELLE_LOGIC)
    -m N         max goals per theory (0 = all)
    -o OPTION    override Isabelle system OPTION
    -s N         keep every Nth goal (default 1)
    -t SECONDS   per-goal timeout (default 30)
    -v           verbose

  Write the goals of THEORIES that try0 cannot close (a "hard" benchmark set).
  With -L -A: one-liner goals (a single leaf proof, no apply).
""",
        (common.getopts ::: selection.getopts ::: List[(String, String => Unit)](
          "A" -> (_ => no_apply = true),
          "H" -> (_ => use_sledgehammer = true),
          "L" -> (_ => leaf_only = true),
          "M" -> (_ => methods_only = true),
          "O:" -> (arg => out = Path.explode(arg)),
          "t:" -> (arg => timeout = Time.seconds(Value.Double.parse(arg))))): _*)

      val theories = common.theories(getopts(args))
      if (theories.isEmpty) getopts.usage()
      val probe = new Filter_Probe(use_sledgehammer, methods_only, leaf_only, no_apply)
      val progress = common.progress
      progress.interrupt_handler {
        Goals_Run.run(common.logic, common.dirs, common.options, theories, selection.selector,
          probe, Nil, 0, timeout, out, progress)
      }
    })
}

class Goals_Filter_Tool extends Isabelle_Scala_Tools(Goals_Filter.isabelle_tool)
