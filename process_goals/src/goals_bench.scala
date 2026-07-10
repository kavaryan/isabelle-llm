/*  Title:      goals/src/goals_bench.scala
    Author:     Maximilian Schaeffeler

Probe for a single-step benchmark: stock arms (try0/sledgehammer) and LLM policy
arms (pass@1 / pass@k) on each goal, writing a per-goal log and a console summary.
*/

package isabelle.goals

import isabelle._


object Goals_Bench {
  sealed trait Arm { def label: String }
  final case class Action_Arm(label: String, op: String, args: List[String]) extends Arm
  final case class LLM_Arm(label: String, url: String, template: String) extends Arm

  // `pass` = (candidates that close the goal, candidates tried); `cands` = every
  // generated candidate with whether it closes the goal; both set by LLM arms only
  final case class Result(solved: Boolean, ms: Int, log: String, pass: Option[(Int, Int)] = None,
    cands: List[(String, Boolean)] = Nil)

  // one benchmarked goal: the outcome of every arm
  final case class Bench_Row(site: Goals.Site, theory: String, outcomes: List[(String, Result)])

  private val temperature = 0.8

  private def prompt(template: String, goal: String, facts: String, theory: String): String =
    template.replace("{goal}", goal).nn
      .replace("{facts}", if (facts.trim.nn.isEmpty) "" else "<suggested_facts>\n" + facts + "\n</suggested_facts>\n").nn
      .replace("{theory}", theory).nn

  def run_arm(c: Probe.Context, arm: Arm, k: Int, max_symbols: Int): Result = {
    val tag = "[" + c.theory + " " + c.site.line + ":" + c.site.offset + " " + c.site.name + "]"
    val start = Time.now()
    def ms = (Time.now() - start).ms.toInt
    def working(s: String): Unit = c.progress.echo("  " + tag + " " + arm.label + ": " + s)
    Exn.capture {
      arm match {
        case Action_Arm(_, op, args) =>
          val ok = c.closes(op, args)
          working(if (ok) "closed" else "no proof")
          Result(ok, ms, if (ok) "closed" else "")
        case LLM_Arm(_, url, template) =>
          val text = prompt(template, c.goal_state, cat_lines(c.facts), c.text_before(max_symbols))
          val cands = LLM.generate(url, arm.label, text, k, temperature, c.timeout)
          val verdicts = c.query("speculate_check_many", c.secs :: cands)
          val closed = cands.zipAll(verdicts, "", "0").map { case (cand, v) => cand.trim.nn.nonEmpty && v == "1" }
          for (((cand, good), i) <- cands.zip(closed).zipWithIndex)
            working((if (good) "✓" else "✗") + " cand " + (i + 1) + "/" + cands.length + ": " + cand.trim.nn)
          val rank = closed.indexOf(true)
          working("pass@" + k + " " + closed.count(identity) + "/" + cands.length +
            (if (rank < 0) " (unsolved)" else " (first closes at rank " + (rank + 1) + ")"))
          Result(rank >= 0, ms, if (rank < 0) "" else "solved rank=" + (rank + 1),
            Some((closed.count(identity), cands.length)), cands.zip(closed))
      }
    } match {
      case Exn.Res(r) => r
      case Exn.Exn(_) => working("error/timeout"); Result(solved = false, ms, "error/timeout")
    }
  }

  // -A specs: try0 | sledgehammer | sledgehammer:methods
  private def action_arm(spec: String, timeout: Time): Action_Arm = {
    val secs = Goals.timeout_secs(timeout)
    spec match {
      case "try0" => Action_Arm(spec, "try0_closes", List(secs))
      case "sledgehammer" => Action_Arm(spec, "sledgehammer_closes", List("all", secs))
      case "sledgehammer:methods" => Action_Arm(spec, "sledgehammer_closes", List("methods", secs))
      case _ => error("unknown -A action: " + spec)
    }
  }

  val isabelle_tool = Isabelle_Tool("goals_bench",
    "single-step benchmark with stock and LLM (pass@k) arms on theory goals",
    Scala_Project.here,
    { args =>
      val common = new Goals_Args.Common
      val selection = new Goals_Args.Selection
      var actions: List[String] = Nil
      var llms: List[(String, String, String)] = Nil
      var k = 16
      var max_facts = 16
      var max_symbols = 2000
      var timeout = Time.seconds(30.0)
      var out = Path.explode("goals_bench")

      val getopts = Getopts("""
Usage: isabelle goals_bench [OPTIONS] THEORIES...

  Options are:
    -A NAME      stock arm: try0 | sledgehammer | sledgehammer:methods  (repeatable)
    -F N         max facts in the LLM prompt (default 16)
    -G           restrict to top-level goals (not nested inside another proof block)
    -L SPEC      LLM arm; SPEC = LABEL,URL,PROMPT_FILE                   (repeatable)
    -N           restrict to nested goals (excludes one-liners like 'by simp'/'unfolding x by simp')
    -O DIR       output directory for bench.log (default goals_bench)
    -T FILE      read theory names from FILE (one per line, # comments); repeatable
    -W FILE      restrict to goals in a hard-set whitelist (goals_filter output)
    -c N         preceding theory text in the LLM prompt, last N symbols (default 2000, 0 = full)
    -d DIR       include session directory
    -k N         LLM candidates per goal (default 16)
    -l NAME      logic session name (default ISABELLE_LOGIC)
    -m N         max goals per theory (0 = all)
    -o OPTION    override Isabelle system OPTION
    -s N         keep every Nth goal (default 1)
    -t SECONDS   per-arm timeout (default 30)
    -v           verbose

  Run each arm on every goal of THEORIES, writing DIR/bench.log and a console
  summary with LLM pass@1 / pass@k.
""",
        (common.getopts ::: selection.getopts ::: List[(String, String => Unit)](
          "A:" -> (arg => actions = actions ::: List(arg)),
          "F:" -> (arg => max_facts = Value.Int.parse(arg)),
          "L:" -> (arg => llms = llms ::: List(space_explode(',', arg) match {
            case List(label, url, prompt) => (label, url, prompt)
            case _ => error("bad -L spec (LABEL,URL,PROMPT_FILE): " + arg) })),
          "O:" -> (arg => out = Path.explode(arg)),
          "c:" -> (arg => max_symbols = Value.Int.parse(arg)),
          "k:" -> (arg => k = Value.Int.parse(arg)),
          "t:" -> (arg => timeout = Time.seconds(Value.Double.parse(arg))))): _*)

      val theories = common.theories(getopts(args))
      if (theories.isEmpty) getopts.usage()
      val arms: List[Arm] =
        actions.map(action_arm(_, timeout)) :::
        llms.map { case (label, url, prompt) => LLM_Arm(label, url, File.read(Path.explode(prompt))) }
      if (arms.isEmpty) error("no arms: pass at least one -A or -L")
      val probe = new Bench_Probe(arms, k, max_symbols)
      val progress = common.progress
      progress.interrupt_handler {
        Goals_Run.run(common.logic, common.dirs, common.options, theories, selection.selector,
          probe, Nil, max_facts, timeout, out, progress)
      }
    })
}

class Bench_Probe(arms: List[Goals_Bench.Arm], k: Int, max_symbols: Int) extends Probe[Goals_Bench.Bench_Row] {
  import Goals_Bench._

  def name = "bench"
  override def description = "stock and LLM (pass@k) arms per goal"

  def apply(c: Probe.Context): Option[Bench_Row] = {
    c.progress.echo(cat_lines(c.tag ::
      Goals.preview(c.session, c.snapshot, c.struct, c.site, 2, c.max_facts, c.timeout)))
    Some(Bench_Row(c.site, c.theory, arms.map(a => a.label -> run_arm(c, a, k, max_symbols))))
  }

  def finish(records: List[Bench_Row], out: Path, progress: Progress): Unit = {
    val n = records.length
    val log_lines =
      for { row <- records; (label, res) <- row.outcomes }
        yield Goals_Output.log_line(label, row.site.name, res.ms, row.theory, row.site.line, row.site.offset, res.log)

    progress.echo("\n=== results over " + n + " goals ===")
    val final_lines = arms.map { arm =>
      val os = records.map(_.outcomes.toMap.apply(arm.label))
      val solved = os.count(_.solved)
      val summary = arm match {
        case _: LLM_Arm =>
          val correct = os.flatMap(_.pass).map(_._1).sum
          val total = os.flatMap(_.pass).map(_._2).sum
          val pass1 = if (total == 0) 0.0 else 100.0 * correct / total
          "pass@k " + solved + "/" + n + ", pass@1 " + "%.1f".format(pass1) + "%"
        case _ => "solved " + solved + "/" + n
      }
      progress.echo("%-12s".format(arm.label) + " " + summary)
      Goals_Output.finalize_line(arm.label, summary)
    }

    val log_file = out + Path.basic("bench.log")
    Goals_Output.write_log(log_file, log_lines ::: final_lines)
    progress.echo("Wrote " + log_file)

    val cand_records =
      for { row <- records; (label, res) <- row.outcomes if res.cands.nonEmpty }
        yield Goals_Output.candidate_record(row.theory, label, row.site.name, row.site.line, row.site.offset, res.cands)
    if (cand_records.nonEmpty) {
      val cand_file = out + Path.basic("candidates.json")
      Goals_Output.write_candidates(cand_file, cand_records)
      progress.echo("Wrote " + cand_records.length + " candidate sets -> " + cand_file)
    }
  }
}

class Goals_Bench_Tool extends Isabelle_Scala_Tools(Goals_Bench.isabelle_tool)
