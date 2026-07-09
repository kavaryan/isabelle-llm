/*  Title:      goals/src/goals_oneshot.scala

Usage: isabelle goals_run -P oneshot -W 01_discover.json -O 02_oneshot.json \
  -A 01_discover.json -A <adapter_command> -A prompts/oneshot_prompt.txt \
  [-A <max_symbols>] THEORIES...
*/

package isabelle.goals

import isabelle._


object Oneshot_Prompt {
  def build(template: String, theory: String, context: String): String =
    template.replace("{theory}", theory).nn.replace("{context}", context).nn

  private val fenced = """(?s)```isabelle\n(.*?)```""".r

  def extract_proof(response: String): String =
    fenced.findFirstMatchIn(response).map(_.group(1).nn.trim.nn).getOrElse("")
}


object External_Adapter {
  def run(command: String, prompt: String, env: List[(String, String)] = Nil): String = {
    val result = Isabelle_System.bash(Bash.string(command), input = prompt, env = Isabelle_System.Settings.env(env))
    if (!result.ok)
      error("adapter " + quote(command) + " exited " + result.rc + ". stdout: " + result.out + " stderr: " + result.err)
    result.out
  }
}


class Oneshot_Probe extends JSON_Probe {
  def name = "oneshot"
  override def description = "phase 2: one-shot LLM proof attempt via an external adapter"

  private val prior = new Path_Cache(Goals_Output.read_records_by_position)
  private val prompt_template = new Path_Cache(File.read)

  def apply(c: Probe.Context): Option[JSON.T] = {
    val args = c.args
    val input = args.head
    val adapter = args(1)
    val prompt_file = args(2)
    val max_symbols = args.lift(3).getOrElse("4000").toInt
    val hash = c.struct.source_hash

    def record(status: String, extra: (String, JSON.T)*): JSON.T =
      JSON.Object(List("theory" -> c.theory, "line" -> c.site.line, "offset" -> c.site.offset,
        "file_hash" -> hash, "status" -> status) ++ extra: _*)

    prior.get(input).get((c.theory, c.site.line, c.site.offset)).map { rec =>
      if (JSON.string(rec, "file_hash").exists(_ != hash)) record("hash_mismatch")
      else {
        val context = c.text_before(max_symbols)
        val prompt = Oneshot_Prompt.build(prompt_template.get(prompt_file), c.theory, context)
        Exn.capture(External_Adapter.run(adapter, prompt)) match {
          case Exn.Res(response) =>
            val proof_text = Oneshot_Prompt.extract_proof(response)
            record(if (proof_text.nonEmpty) "extracted" else "no_code_block",
              "adapter" -> adapter, "context_chars" -> context.length,
              "raw_response" -> response, "proof_text" -> proof_text)
          case Exn.Exn(exn) => record("error", "adapter" -> adapter, "error" -> Exn.message(exn))
        }
      }
    }
  }
}