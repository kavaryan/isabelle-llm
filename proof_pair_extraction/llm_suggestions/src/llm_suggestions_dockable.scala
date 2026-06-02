package isabelle.llm_suggestions

import isabelle._
import isabelle.jedit._

import scala.swing.{Component, Label, ComboBox, BoxPanel, Orientation, CheckBox}
import scala.collection.mutable.ListBuffer
import java.awt.BorderLayout
import javax.swing.event.{DocumentListener, DocumentEvent}
import org.gjt.sp.jedit.{View, jEdit}

class LLM_Suggestions_Dockable(view: View, position: String) extends Dockable(view, position) {
  dockable =>

  GUI_Thread.require {}

  /* Settings keys */
  private object Settings {
    val PROVIDER  = "llm_suggestions.provider"
    val URL       = "llm_suggestions.url"
    val MODEL     = "llm_suggestions.model"
    val MAX_FACTS = "llm_suggestions.max_facts"
    val VERIFY    = "llm_suggestions.verify"
    val API_KEY   = "llm_suggestions.api_key"
  }

  private def load_string(key: String, default: String): String =
    jEdit.getProperty(key, default)
  private def load_bool(key: String, default: Boolean): Boolean =
    jEdit.getBooleanProperty(key, default)
  private def save_string(key: String, value: String): Unit =
    jEdit.setProperty(key, value)
  private def save_bool(key: String, value: Boolean): Unit =
    jEdit.setBooleanProperty(key, value)

  private def add_auto_save(field: javax.swing.JTextField, key: String): Unit = {
    field.getDocument.addDocumentListener(new DocumentListener {
      def insertUpdate(e: DocumentEvent): Unit = save()
      def removeUpdate(e: DocumentEvent): Unit = save()
      def changedUpdate(e: DocumentEvent): Unit = save()
      private def save(): Unit = {
        save_string(key, field.getText.trim)
        jEdit.propertiesChanged()
      }
    })
  }

  /* Output area */
  private lazy val output: Output_Area = new Output_Area(view)
  override def detach_operation: Option[() => Unit] = output.pretty_text_area.detach_operation
  output.setup(dockable)
  set_content(output.text_pane)

  /* Controls */
  private val provider_options = List(
    "Local / OpenAI Compatible",
    "Custom HTTP Agent",
    "Mock / Test Provider"
  )
  private val provider_selector = new ComboBox(provider_options)

  private val url_field     = new javax.swing.JTextField(load_string(Settings.URL, "http://localhost:11434/v1"), 15)
  private val model_field   = new javax.swing.JTextField(load_string(Settings.MODEL, "llama3"), 8)
  private val api_key_field = new javax.swing.JPasswordField(load_string(Settings.API_KEY, ""), 10)
  private val max_facts_field = new javax.swing.JTextField(load_string(Settings.MAX_FACTS, "5"), 3)
  private val verify_check  = new CheckBox("Verify") {
    selected = load_bool(Settings.VERIFY, true)
    tooltip  = "Try the suggestion in Isabelle before showing it"
  }

  // Restore provider selection and wire up auto-save
  locally {
    val saved = load_string(Settings.PROVIDER, provider_options.head)
    provider_options.indexOf(saved) match {
      case -1 => ()
      case  i => provider_selector.selection.index = i
    }
    add_auto_save(max_facts_field, Settings.MAX_FACTS)
  }

  private val process_indicator = new Process_Indicator

  private val get_suggestion_button = new GUI.Button(GUI.Style_HTML.enclose_bold("Get Suggestion")) {
    tooltip = "Query the selected LLM provider for a proof suggestion"
    override def clicked(): Unit = request_suggestion()
  }

  private val cancel_button = new GUI.Button("Cancel") {
    tooltip = "Cancel the running verification"
    override def clicked(): Unit = llm_verify.cancel_query()
  }

  private val config_panel = new BoxPanel(Orientation.Horizontal) {
    contents += new Label(" Provider: ")
    contents += provider_selector
    contents += new Label(" URL: ")
    contents += Component.wrap(url_field)
    contents += new Label(" Model: ")
    contents += Component.wrap(model_field)
    contents += new Label(" Key: ")
    contents += Component.wrap(api_key_field)
    contents += new Label(" Max Facts: ")
    contents += Component.wrap(max_facts_field)
    contents += verify_check
    contents += get_suggestion_button
    contents += cancel_button
    contents += process_indicator.component
  }

  add(config_panel.peer, BorderLayout.NORTH)

  /* Retry loop state */

  private val MAX_RETRIES = 2

  private case class PendingRequest(
    provider: LLMProvider,
    preceding: String,
    proofSource: String,
    stateBefore: String,
    facts: List[String],
    doVerify: Boolean,
    retries: Int = MAX_RETRIES,
    lastSuggestion: String = "",
    previousError: Option[(String, String)] = None
  )

  private var pending_request: Option[PendingRequest] = None
  private var verifying: Boolean = false

  /* llm_verify Query_Operation */

  private val pane_elems = ListBuffer.empty[XML.Elem]

  private def refresh_pane(): Unit = {
    val snap = PIDE.snapshot(view)
    output.pretty_text_area.update(snap, Command.Results.empty, pane_elems.toList)
  }

  private def clear_pane(): Unit = {
    pane_elems.clear()
    refresh_pane()
  }

  private def show_status(msg: String): Unit = {
    pane_elems += XML.Elem(Markup(Markup.WRITELN_MESSAGE, Nil), List(XML.Text(msg)))
    refresh_pane()
  }

  private def show_suggestion(suggestion: String): Unit = {
    pane_elems += XML.Elem(Markup(Markup.SENDBACK, Nil), List(XML.Text("\n" + suggestion)))
    refresh_pane()
  }

  private def consume_verify_status(status: Query_Operation.Status): Unit = {
    status match {
      case Query_Operation.Status.waiting =>
        process_indicator.update("Verifying suggestion ...", 5)
      case Query_Operation.Status.running =>
        process_indicator.update("Running tactic ...", 15)
      case Query_Operation.Status.finished =>
        process_indicator.update(null, 0)
    }
  }

  private def consume_verify_output(editor_output: Editor.Output): Unit = {
    GUI_Thread.later {
      if (verifying) {
        val msgs = editor_output.messages.flatMap {
          case XML.Elem(Markup(Markup.WRITELN_MESSAGE, _), body) =>
            val text = XML.content(body).trim
            if (text.startsWith("PROOF_COMPLETE") ||
                text.startsWith("PROOF_STATE") ||
                text.startsWith("UNVERIFIED")) Some(text) else None
          case _ => None
        }
        msgs.headOption match {
          case Some(msg) if msg.startsWith("PROOF_COMPLETE") =>
            Output.writeln("[✓] Suggestion verified.")
            pending_request.foreach { req => show_suggestion(req.lastSuggestion) }
            verifying = false
            pending_request = None
          case Some(msg) if msg.startsWith("PROOF_STATE") =>
            val n = msg.stripPrefix("PROOF_STATE").trim.takeWhile(_.isDigit)
            Output.writeln(s"[i] Suggestion applied ($n subgoal(s) remaining from outer proof).")
            pending_request.foreach { req => show_suggestion(req.lastSuggestion) }
            verifying = false
            pending_request = None
          case Some(msg) if msg.startsWith("UNVERIFIED") =>
            val reason = msg.stripPrefix("UNVERIFIED").trim.stripPrefix(":").trim
            retry_or_fail(if (reason.nonEmpty) reason else "verification failed")
          case _ => ()
        }
      }
    }
  }

  private def retry_or_fail(error: String): Unit = {
    pending_request match {
      case Some(req) if req.retries > 0 && req.doVerify =>
        val remaining = req.retries - 1
        val retryMsg = s"[↻] Verification failed (${req.retries - remaining}/$MAX_RETRIES retries used): $error"
        Output.warning(retryMsg)
        show_status(retryMsg)
        pending_request = Some(req.copy(
          retries = remaining,
          lastSuggestion = "",
          previousError = Some((req.lastSuggestion, error))
        ))
        run_llm()
      case Some(req) =>
        val errMsg = "[✗] Suggestion failed verification" +
          (if (error.nonEmpty) ": " + error else "")
        Output.warning(errMsg)
        show_suggestion(req.lastSuggestion)
        show_status(errMsg)
        verifying = false
        pending_request = None
      case None =>
        Output.warning("[✗] Suggestion failed verification" +
          (if (error.nonEmpty) ": " + error else ""))
        verifying = false
    }
  }

  private lazy val llm_verify =
    new Query_Operation(PIDE.editor, view, "llm_verify",
      consume_verify_status, consume_verify_output)

  /* llm_context Query_Operation: goal state + relevant MePo facts */

  private def consume_context_status(status: Query_Operation.Status): Unit = {
    status match {
      case Query_Operation.Status.waiting =>
        process_indicator.update("Gathering proof context ...", 5)
      case Query_Operation.Status.running =>
        process_indicator.update("Selecting relevant facts ...", 15)
      case Query_Operation.Status.finished =>
        process_indicator.update(null, 0)
    }
  }

  // Parse the <proof_context> YXML produced by Proof_Context_Exporter into
  // the goal-state text and a list of "name: statement" facts, reusing the
  // shared Proof_Context_Parser (also used by extract_mirabelle.scala).
  private def parse_context(body: XML.Body): (String, List[String]) = {
    val children = body.flatMap {
      case XML.Elem(Markup("proof_context", _), cs) => cs
      case _ => Nil
    }
    val state =
      children.flatMap(Proof_Context_Parser.parse_proof_goal).map(_._3.trim).headOption.getOrElse("")
    val facts =
      children.flatMap(Proof_Context_Parser.parse_facts).flatten
        .map(f => f.display_name + ": " + f.statement.trim.replaceAll("\\s+", " "))
    (state, facts)
  }

  private def consume_context_output(editor_output: Editor.Output): Unit = {
    GUI_Thread.later {
      pending_request match {
        case Some(req) =>
          val ctx = editor_output.messages.collectFirst {
            case XML.Elem(Markup(Markup.WRITELN_MESSAGE, _), body) => body
          }
          val err = editor_output.messages.collectFirst {
            case XML.Elem(Markup(Markup.ERROR_MESSAGE, _), body) => XML.content(body)
          }
          (ctx, err) match {
            case (Some(body), _) =>
              val (state_before, facts) = parse_context(body)
              Output.writeln("[context] goal state:\n" + state_before)
              Output.writeln("[context] " + facts.length + " relevant facts:\n" + facts.mkString("\n"))
              show_status("Context gathered (" + facts.length + " facts).")
              pending_request = Some(req.copy(stateBefore = state_before, facts = facts))
              run_llm()
            case (None, Some(msg)) =>
              pending_request = None
              show_status("[!] Could not gather proof context: " + msg.trim)
              Output.warning("[!] Could not gather proof context: " + msg.trim)
            case _ => ()
          }
        case None => ()
      }
    }
  }

  private lazy val llm_context =
    new Query_Operation(PIDE.editor, view, "llm_context",
      consume_context_status, consume_context_output)

  /* Helper: active provider */

  private def get_active_provider(): LLMProvider = {
    provider_selector.selection.item match {
      case "Local / OpenAI Compatible" =>
        val url   = url_field.getText.trim
        val model = model_field.getText.trim
        val key   = new String(api_key_field.getPassword).trim
        if (url.isEmpty) error("Base URL cannot be empty.")
        new OpenAICompatibleProvider(url, model, key)
      case "Custom HTTP Agent" =>
        val url = url_field.getText.trim
        if (url.isEmpty) error("Agent URL cannot be empty.")
        new CustomAgentProvider(url)
      case _ =>
        new MockLLMProvider()
    }
  }

  private def enclosing_proof_range(snapshot: Document.Snapshot, node: Document.Node.Name, offset: Text.Offset)
  : Option[Text.Range] = {
    val node0 = snapshot.node
    for {
      cmd0   <- snapshot.current_command(node, offset)
      cmds    = node0.command_iterator().toList
      idx     = cmds.indexWhere(_._1 == cmd0)
      startIdx <- (idx to 0 by -1).find { i =>
        cmds(i)._1.span.is_keyword_kind(s => Keyword.proof_goal.contains(s) || Keyword.theory_goal.contains(s))
      }
      startCmd = cmds(startIdx)._1
      startOff <- node0.command_start(startCmd)
      endCmd <- {
        var depth = 0
        cmds.drop(startIdx).map(_._1).find { cmd =>
          if (cmd.span.is_keyword_kind(s => Keyword.proof_open.contains(s) || Keyword.theory_goal.contains(s))) { depth += 1; false }
          else if (cmd.span.is_keyword_kind(s => Keyword.proof_close.contains(s))) { depth -= 1; depth == 0 }
          else false
        }
      }
      endOff <- node0.command_start(endCmd)
    } yield Text.Range(startOff, endOff + endCmd.source.length)
  }

  /* Main request flow */

  private def request_suggestion(): Unit = {
    save_settings()
    try {
      val snapshot = PIDE.snapshot(view)
      val node     = PIDE.editor.current_node(view).getOrElse(error("No active theory file open."))
      val offset   = view.getTextArea.getCaretPosition
      val command  = snapshot.current_command(node, offset)
        .getOrElse(error("Cursor is not on an active Isabelle command."))

      val range = enclosing_proof_range(snapshot, node, offset).getOrElse {
        val start = snapshot.node.command_start(command).getOrElse(0)
        Text.Range(start, start + command.source.length)
      }
      val source       = snapshot.node.source
      val proof_source = range.substring(source)
      val preceding    = source.substring(0, range.start).takeRight(2000)
      val max_facts    = try { max_facts_field.getText.trim.toInt } catch { case _: Throwable => 5 }
      val provider     = get_active_provider()

      pending_request = Some(PendingRequest(provider, preceding, proof_source, "", Nil, verify_check.selected))
      clear_pane()
      show_status("Gathering proof context...")
      Output.writeln("[*] Gathering proof context (goal state + relevant facts) ...")
      llm_context.apply_query(List(max_facts.toString))
    } catch {
      case exn: Throwable =>
        pending_request = None
        Output.writeln("[!] Error: " + exn.getMessage)
    }
  }

  private def run_llm(): Unit = {
    pending_request match {
      case Some(req) =>
        val statusMsg = "[*] Querying LLM (" + req.facts.length + " relevant facts) ..."
        Output.writeln(statusMsg)
        show_status(statusMsg)
        Isabelle_Thread.fork(name = "llm_query_thread") {
          try {
            val suggestion = req.provider.getProofSuggestion(
              req.preceding, req.proofSource, req.stateBefore, req.facts, req.previousError)
            Output.writeln("[LLM response]\n" + suggestion)
            GUI_Thread.later {
              if (req.doVerify) {
                pending_request = Some(req.copy(lastSuggestion = suggestion))
                val verifyMsg = "[*] Verifying: " + suggestion.take(60).replace("\n", " ") + " ..."
                Output.writeln(verifyMsg)
                verifying = true
                llm_verify.apply_query(List(suggestion))
              } else {
                show_suggestion(suggestion)
                Output.writeln("[+] Suggestion ready — click to insert.")
                pending_request = None
              }
            }
          } catch {
            case exn: Throwable =>
              GUI_Thread.later {
                val errMsg = "[!] LLM query failed: " + exn.getMessage
                Output.writeln(errMsg)
                show_status(errMsg)
                pending_request = None
              }
          }
        }
      case None =>
        val errMsg = "[!] No pending request to process."
        Output.writeln(errMsg)
        show_status(errMsg)
    }
  }

  /* Settings persistence */

  private def save_settings(): Unit = {
    save_string(Settings.PROVIDER,  provider_selector.selection.item)
    save_string(Settings.URL,       url_field.getText.trim)
    save_string(Settings.MODEL,     model_field.getText.trim)
    save_string(Settings.MAX_FACTS, max_facts_field.getText.trim)
    save_bool(Settings.VERIFY,      verify_check.selected)
    save_string(Settings.API_KEY,   new String(api_key_field.getPassword).trim)
  }

  override def focusOnDefaultComponent(): Unit = get_suggestion_button.requestFocus()

  /* Session lifecycle */

  private val main =
    Session.Consumer[Session.Global_Options](getClass.getName) {
      case _: Session.Global_Options => GUI_Thread.later { output.handle_resize() }
    }

  override def init(): Unit = {
    PIDE.session.global_options += main
    llm_context.activate()
    llm_verify.activate()
    output.init()
  }

  override def exit(): Unit = {
    save_settings()
    llm_verify.deactivate()
    llm_context.deactivate()
    PIDE.session.global_options -= main
    output.exit()
  }
}
