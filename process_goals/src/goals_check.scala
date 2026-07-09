/*  Title:      goals/src/goals_check.scala

Usage: isabelle goals_run -P check -W 02_oneshot.json -O 03_check.json \
  -A 02_oneshot.json [-A <timeout_secs>] THEORIES...
*/

package isabelle.goals

import isabelle._


class Check_Probe extends JSON_Probe {
  def name = "check"
  override def description = "phase 3: verify phase-2 candidates; keep only the faulty ones"

  private val prior = new Path_Cache(Goals_Output.read_records_by_position)

  def apply(c: Probe.Context): Option[JSON.T] = {
    val args = c.args
    val input = args.head
    val secs = args.lift(1).getOrElse("10").toInt
    val hash = c.struct.source_hash

    def faulty(proof_text: String, error: String): Option[JSON.T] =
      Some(JSON.Object("theory" -> c.theory, "line" -> c.site.line, "offset" -> c.site.offset,
        "file_hash" -> hash, "proof_text" -> proof_text, "check_ok" -> false, "check_error" -> error))

    prior.get(input).get((c.theory, c.site.line, c.site.offset)) match {
      case None => faulty("", "no phase-2 record for this goal")
      case Some(rec) if JSON.string(rec, "file_hash").exists(_ != hash) =>
        faulty(JSON.string(rec, "proof_text").getOrElse(""), "file_hash mismatch: theory source changed since phase 2")
      case Some(rec) if JSON.string(rec, "proof_text").getOrElse("").isEmpty =>
        faulty("", "no proof_text in phase-2 record")
      case Some(rec) =>
        val proof_text = JSON.string(rec, "proof_text").getOrElse("")
        val verdict = c.query("speculate_check_many", secs.toString :: List(proof_text))
        if (verdict.headOption.contains("1")) None
        else faulty(proof_text, "does not close the goal within " + secs + "s (raw verdict: " + verdict.mkString("|") + ")")
    }
  }
}