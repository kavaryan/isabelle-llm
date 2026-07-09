/*  Title:      goals/src/goals_repl.scala

Usage: isabelle goals_run -P repl -A <ir_dir> [-A <wait_secs>] -m 1 THEORY
*/

package isabelle.goals

import isabelle._


class Repl_Probe extends JSON_Probe {
  def name = "repl"
  override def description =
    "open an AutoCorrode I/R REPL at one goal (in-session; args: ir_dir [wait_secs])"

  // Ir.state pretty-prints the toplevel (plus a trailing [timing] line): non-empty
  // while a proof is open (even "No subgoals!" -- goal discharged but still
  // pending a `done`/`qed`), empty once back at theory level, i.e. the goal is
  // genuinely finished.
  private def closed(state: String): Boolean =
    cat_lines(Library.split_lines(state).filterNot(_.startsWith("[timing]"))).trim.nn.isEmpty
  private def or_else(r: Exn.Result[String], default: String): String =
    r match { case Exn.Res(s) => s; case Exn.Exn(_) => default }

  def apply(c: Probe.Context): Option[JSON.T] = {
    val ir_dir = c.args.head
    val wait_secs = c.args.lift(1).getOrElse("600").toInt
    val command = Goals.command_of(c.snapshot, c.site.range)
    val repl_id = "goals_repl_" + c.theory + "_" + c.site.line + "_" + Time.now().ms

    def result(extra: (String, JSON.T)*): JSON.T =
      JSON.Object(List("theory" -> c.theory, "line" -> c.site.line, "offset" -> c.site.offset) ++ extra: _*)

    new IR_Launcher(c.session, msg => c.progress.echo(c.tag + " " + msg)).launch(ir_dir) match {
      case Left(err) => Some(result("ok" -> false, "error" -> err))
      case Right(launched) =>
        Some(IR_Launcher.with_repl(launched, repl_id, command) { client =>
          c.progress.echo(c.tag + " I/R REPL " + quote(repl_id) + " ready: host=127.0.0.1 port=" +
            launched.replPort + " token=" + launched.replToken.getOrElse("") + "; waiting up to " + wait_secs + "s")

          val deadline = Time.now() + Time.seconds(wait_secs)
          var state = client.state(repl_id, -1)
          while (!closed(state) && Time.now() < deadline) {
            Time.seconds(3).sleep()
            state = or_else(Exn.capture(client.state(repl_id, -1)), state)
          }

          val ok = closed(state)
          val proof_text = or_else(Exn.capture(client.text(repl_id)), "<failed to read text>")
          c.progress.echo(c.tag + " I/R REPL " + quote(repl_id) + (if (ok) " closed" else " timed out"))
          result("ok" -> ok, "proof_text" -> proof_text, "final_state" -> state)
        })
    }
  }
}
