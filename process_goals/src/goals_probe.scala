/*  Title:      goals/src/goals_probe.scala
    Author:     Maximilian Schaeffeler

The goal-processing spine: drive the headless session over the goals of a set of
theories and hand each goal to a Probe. A Probe is the goal-level analogue of a
stock Dump.Aspect -- a named consumer over a Headless session; its Context plays
the role of Aspect_Args. extract / filter / bench are probes; goals_run is the
open tool for ad-hoc ones.
*/

package isabelle.goals

import isabelle._


trait Probe[A] {
  def name: String
  def description: String = ""

  // run on each goal; return a record to collect, or None to drop the goal
  def apply(context: Probe.Context): Option[A]

  // final output, written once at the end
  def finish(records: List[A], out: Path, progress: Progress): Unit

  // persist the records so far after each theory (crash-safety); default: none
  def checkpoint(records: List[A], out: Path, progress: Progress): Unit = ()
}

object Probe {
  // the live session and one goal, plus the operations a hook needs (≈ Dump.Aspect_Args)
  final case class Context(
    session: Session, snapshot: Document.Snapshot, struct: Goals.Structure, site: Goals.Site,
    theory: String, args: List[String], max_facts: Int, timeout: Time, progress: Progress
  ) {
    def query(op: String, op_args: List[String]): List[String] =
      Goals_Query.run(session, snapshot, site.range, op, op_args, timeout)
    def closes(op: String, op_args: List[String]): Boolean = query(op, op_args).exists(_.trim.nn.nonEmpty)
    def goal_state: String = Goals.goal_state(snapshot, site.range)
    def facts: List[String] = Goals.suggested_facts(session, snapshot, site.range, max_facts, timeout)
    def text_before(max_symbols: Int): String = Goals.proof_text_before(struct, site.range, max_symbols)
    def block: Goals.Block_Info = Goals.block_info(struct, site.offset - 1)
    def secs: String = Goals.timeout_secs(timeout)
    def ref: Goals_Output.Goal_Ref = Goals_Output.Goal_Ref(theory, site.line, site.offset, site.name)
    def tag: String = "[" + theory + " " + site.line + ":" + site.offset + " " + site.name + "]"
  }
}

// a probe whose records are JSON: writes one JSON array (the default for ad-hoc probes)
abstract class JSON_Probe extends Probe[JSON.T] {
  private def write(records: List[JSON.T], out: Path): Unit = {
    Isabelle_System.make_directory(out.dir)
    File.write(out, JSON.Format.pretty_print(records: JSON.T))
  }
  def finish(records: List[JSON.T], out: Path, progress: Progress): Unit = {
    write(records, out); progress.echo("Wrote " + records.length + " records -> " + out)
  }
  override def checkpoint(records: List[JSON.T], out: Path, progress: Progress): Unit = write(records, out)
}

// service base: register a class extending this in etc/build.props `services`
class Goals_Probes(val probes: Probe[JSON.T]*) extends Isabelle_System.Service


object Goals_Run {
  def probes: List[Probe[JSON.T]] =
    Isabelle_System.make_services(classOf[Goals_Probes]).flatMap(_.probes)

  // drive the headless session over the goals, applying `probe`; the records are
  // checkpointed after each theory (crash-safe) and finalised at the end.
  def run[A](
    logic: String, dirs: List[Path], options: Options, theories: List[String],
    select: Goals.Selector, probe: Probe[A], args: List[String], max_facts: Int, timeout: Time,
    out: Path, progress: Progress
  ): Unit = {
    val collected = Synchronized(List.empty[A])
    Goals.with_theories(theories, options, dirs, logic, progress) { (session, node_name, snapshot) =>
      val struct = Goals.structure(snapshot)
      val theory = Goals.theory_name(node_name)
      val theory_records =
        Goals.map_goals(select, session, node_name, snapshot, progress) { site =>
          probe(Probe.Context(session, snapshot, struct, site, theory, args, max_facts, timeout, progress))
        }.flatten
      val all = collected.change_result(acc => { val a = acc ::: theory_records; (a, a) })
      probe.checkpoint(all, out, progress)
      theory_records
    }
    probe.finish(collected.value, out, progress)
  }

  val isabelle_tool = Isabelle_Tool("goals_run",
    "run a registered Probe (custom Scala) over theory goals",
    Scala_Project.here,
    { args =>
      val common = new Goals_Args.Common
      val selection = new Goals_Args.Selection
      var probe_name = ""
      var probe_args: List[String] = Nil
      var max_facts = 16
      var out = Path.explode("goals_run.json")
      var timeout = Time.seconds(30.0)

      val getopts = Getopts("""
Usage: isabelle goals_run [OPTIONS] THEORIES...

  Options are:
    -A ARG       extra argument passed to the probe (repeatable)
    -F N         max facts available to the probe (default 16)
    -O FILE      output file (default goals_run.json)
    -P NAME      probe to run; omit or "list" to list registered probes
    -T FILE      read theory names from FILE (one per line, # comments); repeatable
    -d DIR       include session directory
    -l NAME      logic session name (default ISABELLE_LOGIC)
    -m N         max goals per theory (0 = all)
    -o OPTION    override Isabelle system OPTION
    -s N         keep every Nth goal (default 1)
    -t SECONDS   per-goal timeout (default 30)
    -v           verbose

  Drive the headless session over the goals of THEORIES, handing each to probe
  NAME. Probes are Scala services (extend Goals_Probes in etc/build.props).
""",
        (common.getopts ::: selection.getopts ::: List[(String, String => Unit)](
          "A:" -> (arg => probe_args = probe_args ::: List(arg)),
          "F:" -> (arg => max_facts = Value.Int.parse(arg)),
          "O:" -> (arg => out = Path.explode(arg)),
          "P:" -> (arg => probe_name = arg),
          "t:" -> (arg => timeout = Time.seconds(Value.Double.parse(arg))))): _*)

      val theories = common.theories(getopts(args))
      val available = probes
      if (probe_name == "" || probe_name == "list")
        Output.writeln(cat_lines("registered probes:" ::
          available.map(p => "  " + p.name + (if (p.description.isEmpty) "" else " - " + p.description))))
      else {
        val probe = available.find(_.name == probe_name).getOrElse(
          error("unknown probe " + quote(probe_name) + " (have: " + available.map(_.name).mkString(", ") + ")"))
        if (theories.isEmpty) getopts.usage()
        val progress = common.progress
        progress.interrupt_handler {
          run(common.logic, common.dirs, common.options, theories, selection.selector,
            probe, probe_args, max_facts, timeout, out, progress)
        }
      }
    })

  // example probe (and template for custom ones)
  val state_probe: Probe[JSON.T] = new JSON_Probe {
    def name = "state"
    override def description = "export each goal's command, position and proof state"
    def apply(c: Probe.Context): Option[JSON.T] =
      Some(JSON.Object("theory" -> c.theory, "line" -> c.site.line, "offset" -> c.site.offset,
        "command" -> c.site.name, "state" -> c.goal_state))
  }
}

class Goals_Builtin_Probes extends Goals_Probes(
  Goals_Run.state_probe, new Discover_Probe, new Oneshot_Probe, new Check_Probe, new Repl_Probe, new Repair_Probe)
class Goals_Run_Tool extends Isabelle_Scala_Tools(Goals_Run.isabelle_tool)
