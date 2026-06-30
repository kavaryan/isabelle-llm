/*  Title:      goals/src/goals_output.scala
    Author:     Maximilian Schaeffeler

Outputs over selected goals: per-theory JSON records, the hard-set goal whitelist,
and the benchmark log.
*/

package isabelle.goals

import isabelle._


object Goals_Output {
  // one extraction record per proof step
  sealed case class Record(
    theory: String, line: Int, offset: Int, command: String,
    state_before: String = "", proof_text_before: String = "", suggested_facts: List[JSON.T] = Nil,
    proof_block: String = "", proof_commands: List[String] = Nil, is_leaf: Boolean = true
  ) {
    def json: JSON.T =
      JSON.Object(
        "theory" -> theory, "line" -> line, "offset" -> offset, "command" -> command,
        "proof_text_before" -> proof_text_before, "state_before" -> state_before,
        "suggested_facts" -> suggested_facts, "proof_block" -> proof_block,
        "proof_commands" -> proof_commands, "is_leaf" -> is_leaf)
  }

  // one JSON array per theory: <dir>/<Theory>.json; returns the per-theory record counts
  def write_records(dir: Path, records: List[Record]): Map[String, Int] = {
    Isabelle_System.make_directory(dir)
    val by_theory = records.groupBy(_.theory)
    for ((theory, recs) <- by_theory) {
      val arr: JSON.T = recs.sortBy(r => (r.line, r.offset)).map(_.json)
      File.write(dir + Path.basic(theory + ".json"), JSON.Format.pretty_print(arr))
    }
    by_theory.view.mapValues(_.length).toMap
  }


  // a goal referenced by theory + position (the hard-set whitelist)
  sealed case class Goal_Ref(theory: String, line: Int, offset: Int, name: String) {
    def json: JSON.T =
      JSON.Object("theory" -> theory, "line" -> line, "offset" -> offset, "name" -> name)
  }

  def write_whitelist(file: Path, refs: List[Goal_Ref]): Unit = {
    Isabelle_System.make_directory(file.dir)
    File.write(file, JSON.Format.pretty_print(refs.map(_.json): JSON.T))
  }

  def read_whitelist(file: Path): List[Goal_Ref] =
    JSON.parse(File.read(file)) match {
      case xs: List[_] =>
        xs.collect { case obj: JSON.Object.T @unchecked =>
          Goal_Ref(
            JSON.string(obj, "theory").getOrElse(""),
            JSON.int(obj, "line").getOrElse(0),
            JSON.int(obj, "offset").getOrElse(0),
            JSON.string(obj, "name").getOrElse(""))
        }
      case _ => Nil
    }


  // every LLM candidate generated for a goal, with whether it closes it
  def candidate_record(theory: String, arm: String, command: String, line: Int, offset: Int,
    cands: List[(String, Boolean)]): JSON.T =
    JSON.Object(
      "theory" -> theory, "line" -> line, "offset" -> offset, "command" -> command, "arm" -> arm,
      "candidates" -> cands.map { case (proof, closes) => JSON.Object("proof" -> proof, "closes" -> closes) })

  def write_candidates(file: Path, records: List[JSON.T]): Unit = {
    Isabelle_System.make_directory(file.dir)
    File.write(file, JSON.Format.pretty_print(records: JSON.T))
  }


  private val label_width = 12
  private def label(s: String): String = Library.format("%-" + label_width + "s", s)

  // benchmark log: "label goal.NAME CPUms theory line:offset RESULT"
  def log_line(label: String, name: String, ms: Int, theory: String, line: Int, offset: Int, result: String): String =
    this.label(label) + " goal." + Library.format("%-9s", name) + " " +
      Library.format("%5sms", ms) + " " + theory + " " + line + ":" + offset + "  " + result

  def finalize_line(label: String, summary: String): String = {
    val prefix = this.label(label) + " finalize   "
    prefix + summary.replace("\n", "\n" + " " * prefix.length)
  }

  def write_log(file: Path, lines: List[String]): Unit = {
    Isabelle_System.make_directory(file.dir)
    File.write(file, lines.mkString("\n") + "\n")
  }
}
