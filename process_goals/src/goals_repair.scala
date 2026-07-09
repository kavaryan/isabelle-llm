/*  Title:      goals/src/goals_repair.scala

Usage: isabelle goals_run -P repair -W 03_check.json -O 04_repair.json \
  -A 03_check.json -A <ir_dir> -A <adapter_command> -A prompts/repair_prompt.txt \
  [-A <max_symbols>] [-A <timeout_secs>] THEORIES...
*/

package isabelle.goals

import isabelle._


object Repair_Prompt {
  def build(template: String, theory: String, context: String, faulty_proof: String, faulty_error: String): String = {
    val feedback = if (faulty_error.nonEmpty) "Checker feedback: " + faulty_error + "\n" else ""
    template.replace("{theory}", theory).nn.replace("{context}", context).nn
      .replace("{faulty_proof}", faulty_proof).nn.replace("{feedback}", feedback).nn
  }
}


class Repair_Probe extends JSON_Probe {
  def name = "repair"
  override def description = "phase 4: interactive repair via goals_repl + an external agent adapter; records the full trace"

  private val prior = new Path_Cache(Goals_Output.read_records_by_position)
  private val prompt_template = new Path_Cache(File.read)

  private def parse_adapter_output(raw: String): (JSON.T, String, String) =
    Exn.capture(JSON.parse(raw)) match {
      case Exn.Res(j) =>
        (JSON.value(j, "transcript").getOrElse(JSON.Object()), JSON.string(j, "final_text").getOrElse(""), "")
      case Exn.Exn(exn) => (JSON.Object(), "", "adapter output not JSON (" + Exn.message(exn) + "): " + raw)
    }

  private def result(c: Probe.Context, hash: String, status: String, extra: (String, JSON.T)*): JSON.T =
    JSON.Object(List("theory" -> c.theory, "line" -> c.site.line, "offset" -> c.site.offset,
      "file_hash" -> hash, "status" -> status) ++ extra: _*)

  private def repair(c: Probe.Context, rec: JSON.T, hash: String,
    ir_dir: String, adapter: String, prompt_file: String, max_symbols: Int, timeout_secs: Int
  ): JSON.T = {
    val faulty_proof = JSON.string(rec, "proof_text").getOrElse("")
    val faulty_error = JSON.string(rec, "check_error").getOrElse("")
    val context = c.text_before(max_symbols)
    val prompt = Repair_Prompt.build(prompt_template.get(prompt_file), c.theory, context, faulty_proof, faulty_error)
    val command = Goals.command_of(c.snapshot, c.site.range)
    val repl_id = "goals_repair_" + c.theory + "_" + c.site.line + "_" + Time.now().ms

    new IR_Launcher(c.session, msg => c.progress.echo(c.tag + " " + msg)).launch(ir_dir) match {
      case Left(err) => result(c, hash, "repl_launch_failed", "error" -> err)
      case Right(launched) =>
        IR_Launcher.with_repl(launched, repl_id, command) { client =>
          val env = List(
            "MINI_IR_HOST" -> "127.0.0.1",
            "MINI_IR_PORT" -> launched.replPort.toString,
            "MINI_IR_TOKEN" -> launched.replToken.getOrElse(""),
            "MINI_IR_REPL_ID" -> repl_id,
            "REPAIR_TIMEOUT_SECS" -> timeout_secs.toString)

          val (transcript, final_text_hint, adapter_error) =
            Exn.capture(External_Adapter.run(adapter, prompt, env)) match {
              case Exn.Res(raw) => parse_adapter_output(raw)
              case Exn.Exn(exn) => (JSON.Object(), "", Exn.message(exn))
            }

          val final_proof_text = Exn.capture(client.text(repl_id)) match {
            case Exn.Res(s) => cat_lines(Library.split_lines(s).filterNot(_.startsWith("[timing]")))
            case Exn.Exn(_) => ""
          }
          val success =
            final_proof_text.trim.nn.nonEmpty &&
            c.query("speculate_check_many", "10" :: List(final_proof_text)).headOption.contains("1")

          result(c, hash, if (success) "repaired" else "unrepaired",
            "faulty_proof" -> faulty_proof, "faulty_error" -> faulty_error,
            "final_proof_text" -> final_proof_text, "success" -> success,
            "transcript" -> transcript, "adapter_final_text_hint" -> final_text_hint,
            "adapter_error" -> adapter_error)
        }
    }
  }

  def apply(c: Probe.Context): Option[JSON.T] = {
    val args = c.args
    val input = args.head
    val ir_dir = args(1)
    val adapter = args(2)
    val prompt_file = args(3)
    val max_symbols = args.lift(4).getOrElse("4000").toInt
    val timeout_secs = args.lift(5).getOrElse("300").toInt
    val hash = c.struct.source_hash

    prior.get(input).get((c.theory, c.site.line, c.site.offset)) match {
      case None => None
      case Some(rec) if JSON.string(rec, "file_hash").exists(_ != hash) =>
        Some(result(c, hash, "hash_mismatch"))
      case Some(rec) =>
        Some(repair(c, rec, hash, ir_dir, adapter, prompt_file, max_symbols, timeout_secs))
    }
  }
}