/*  Title:      goals/src/goals_ir_client.scala

Trimmed copy of AutoCorrode's IRClient/IRLauncher (ir/ir_bridge.scala,
iq/src/IRClient.scala; Copyright Amazon.com, Inc. or its affiliates, MIT
License), keeping only what goals_repl.scala needs: bringing up the I/R ML
(ir.ML / tcp_handler.ML / ml_repl.ML) inside an existing `isabelle.Session`
and opening a REPL from an already-resolved document command (no re-parsing
a file by offset -- goals_repl.scala already has the exact Command from the
live snapshot). Dropped: initFromSourceLocation and everything that pulls in
IQUtils / CommandSelectionTarget (jEdit-plugin-only concerns).
*/

package isabelle.goals

import isabelle._

import java.io.{BufferedReader, InputStreamReader, OutputStreamWriter, PrintWriter}
import java.net.Socket
import scala.util.Using


/** Ephemeral TCP client for the I/R REPL server (repl.py --daemon --expect-ml).
  * Opens a fresh TCP connection per send() call. Protocol: send "command;\n",
  * read lines until "<<DONE>>\n". */
class IR_Client(host: String = "127.0.0.1", port: Int, token: String = "") {
  private val sentinel = "<<DONE>>"

  def connect(): Unit = { val sock = new Socket(host, port); sock.close() }

  def send(command: String): String = {
    val sock = new Socket(host, port)
    try {
      val out = new PrintWriter(new OutputStreamWriter(sock.getOutputStream, "UTF-8"), true)
      val in = new BufferedReader(new InputStreamReader(sock.getInputStream, "UTF-8"))
      if (token.nonEmpty) {
        out.println(token)
        out.flush()
        val response = in.readLine()
        if (response == null || !response.startsWith("OK"))
          error("REPL authentication failed")
      }
      val cmd = if (command.trim.nn.endsWith(";")) command.trim.nn else command.trim.nn + ";"
      out.println(cmd)
      out.flush()
      val sb = new StringBuilder
      var line = in.readLine()
      while (line != null && line != sentinel) {
        if (sb.nonEmpty) sb.append('\n')
        sb.append(line)
        line = in.readLine()
      }
      if (line == null) error("Connection closed by server")
      val result = sb.toString
      if (result.startsWith("ERR\n")) error(result.drop(4))
      result
    }
    finally sock.close()
  }

  private def q(s: String): String = "\"" + s.replace("\\", "\\\\").nn.replace("\"", "\\\"").nn + "\""
  private def mlInt(n: Int): String = if (n < 0) "~" + (-n).toString else n.toString

  def initFromDocument(repl: String, node: String, commandId: Int): String =
    send(s"Ir.init_from_document ${q(repl)} ${q(node)} ${mlInt(commandId)}")
  def step(repl: String, isarText: String): String = send(s"Ir.step ${q(repl)} ${q(isarText)}")
  def back(repl: String): String = send(s"Ir.back ${q(repl)}")
  def state(repl: String, idx: Int): String = send(s"Ir.state ${q(repl)} ${mlInt(idx)}")
  def text(repl: String): String = send(s"Ir.text ${q(repl)}")
  def remove(repl: String): String = send(s"Ir.remove ${q(repl)}")
}


/** Brings up the I/R stack (ir.ML/tcp_handler.ML/ml_repl.ML) against an
  * existing headless `Session` -- the same session goals_run already has the
  * goal's Command resolved in, so no file reload / offset re-resolution is
  * needed. Adapted from AutoCorrode's IRLauncher (ir/ir_bridge.scala). */
object IR_Launcher {
  final case class Launched(client: IR_Client, replPort: Int, replToken: Option[String], process: Process)

  // open a repl on an already-launched I/R stack, run body, always clean up
  def with_repl[A](launched: Launched, repl_id: String, command: Command)(body: IR_Client => A): A = {
    val client = launched.client
    client.initFromDocument(repl_id, command.node_name.node, command.id.toInt)
    try body(client)
    finally { Exn.capture(client.remove(repl_id)); launched.process.destroy() }
  }

  final class Port_Handler extends Session.Protocol_Handler {
    @volatile var port: Option[Int] = None
    @volatile var token: Option[String] = None
    @volatile var maxConn: Option[Int] = None
    private def handle_port(msg: Prover.Protocol_Output): Boolean =
      msg.properties match {
        case List(_, ("port", Value.Int(p)), ("token", tok), ("max_connections", Value.Int(mc))) =>
          port = Some(p); token = Some(tok); maxConn = Some(mc); true
        case List(_, ("port", Value.Int(p)), ("token", tok)) => port = Some(p); token = Some(tok); true
        case List(_, ("port", Value.Int(p))) => port = Some(p); true
        case _ => false
      }
    override val functions: Session.Protocol_Functions = List("IR_Repl.port" -> handle_port)
  }

  final class Status_Handler extends Session.Protocol_Handler {
    @volatile var replied: Boolean = false
    @volatile var running: Boolean = false
    @volatile var port: Option[Int] = None
    @volatile var token: Option[String] = None
    @volatile var maxConn: Option[Int] = None
    private def handle_status(msg: Prover.Protocol_Output): Boolean = {
      val props = msg.properties
      props.collectFirst { case ("running", v) => v } match {
        case Some(r) =>
          running = (r == "true")
          props.collectFirst { case ("port", Value.Int(p)) => p }.foreach(p => port = Some(p))
          props.collectFirst { case ("token", t) => t }.foreach(t => token = Some(t))
          props.collectFirst { case ("max_connections", Value.Int(mc)) => mc }.foreach(mc => maxConn = Some(mc))
          replied = true; true
        case None => false
      }
    }
    override val functions: Session.Protocol_Functions = List("IR_Repl.status" -> handle_status)
  }
}

final class IR_Launcher(session: Session, onStatus: String => Unit = _ => ()) {
  import IR_Launcher._

  private def handlerOf[H <: Session.Protocol_Handler](cls: Class[H], make: => H): Option[H] = {
    if (session.get_protocol_handler(cls).isEmpty) session.init_protocol_handler(make)
    session.get_protocol_handler(cls)
  }

  // Introduce an in-memory `ir` theory node inlining ir.ML/tcp_handler.ML/ml_repl.ML,
  // so the IR_Repl.* protocol commands become defined on this session.
  private def ensureLoaded(irDir: String): Either[String, Document.Node.Name] = {
    def read(name: String): Either[String, String] = {
      val f = new java.io.File(irDir, name)
      if (!f.isFile) Left(s"I/R ML source not found: ${f.getPath}")
      else Right(Using.resource(scala.io.Source.fromFile(f, "UTF-8"))(_.mkString))
    }
    for { irML <- read("ir.ML"); tcpML <- read("tcp_handler.ML"); mlReplML <- read("ml_repl.ML") } yield {
      def ml(src: String): String = "ML‹" + src + "›"
      val text =
        "theory ir\n  imports Main\nbegin\n" +
        "declare [[ML_write_global = true]]\n" +
        ml(irML) + "\n" + ml(tcpML) + "\n" + ml(mlReplML) + "\n" +
        "declare [[ML_write_global = false]]\n" +
        "end\n"
      val resources = session.resources
      val node = resources.import_name(Sessions.DRAFT, irDir, "ir")
      val header = resources.check_thy(node, Scan.char_reader(text))
      val edits: List[Document.Edit_Text] = List(
        node -> Document.Node.Deps(header),
        node -> Document.Node.Edits(Text.Edit.inserts(0, text)),
        node -> Document.Node.Perspective(true, Text.Perspective.empty, Document.Node.Overlays.empty))
      onStatus("Loading I/R ML into the prover (node " + node.theory + ") ...")
      session.update(Document.Blobs.empty, edits)
      node
    }
  }

  private def awaitConsolidated(node: Document.Node.Name, timeoutMs: Long): Either[String, Unit] = {
    def status(): Document_Status.Node_Status = {
      val snap = session.snapshot(node_name = node)
      Document_Status.Node_Status.make(Date.now(), snap.state, snap.version, node)
    }
    val latch = new java.util.concurrent.CountDownLatch(1)
    val consumer = Session.Consumer[Session.Commands_Changed]("IR_Launcher.awaitConsolidated") {
      case Session.Commands_Changed(_, nodes, _) => if (nodes.contains(node) && status().consolidated) latch.countDown()
      case _ =>
    }
    session.commands_changed += consumer
    try {
      if (status().consolidated) latch.countDown()
      val settled = latch.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS) || status().consolidated
      if (!settled) Left(s"I/R ML did not load within ${timeoutMs / 1000}s -- the prover may be busy")
      else if (status().failed > 0) Left("I/R ML failed to load -- error while evaluating the inlined ML")
      else Right(())
    }
    finally session.commands_changed -= consumer
  }

  /** Bring up ir.ML on this session (if not already) and spawn repl.py as a thin
    * pooled front-end to the ML_Repl socket, returning a connected IR_Client. */
  def launch(irDir: String): Either[String, Launched] = {
    val replPy = new java.io.File(irDir, "repl.py").getPath

    val portH = handlerOf(classOf[Port_Handler], new Port_Handler)
      .getOrElse(return Left("Failed to register the IR_Repl.port protocol handler"))
    val statusH = handlerOf(classOf[Status_Handler], new Status_Handler)
      .getOrElse(return Left("Failed to register the IR_Repl.status protocol handler"))

    statusH.replied = false; statusH.running = false; statusH.port = None
    statusH.token = None; statusH.maxConn = None
    session.protocol_command("IR_Repl.status")
    onStatus("Probing IR_Repl.status ...")
    var probe = 0
    while (!statusH.replied && probe < 10) { Thread.sleep(500); probe += 1 }

    val reuse: Option[(Int, Option[String], Option[Int])] =
      if (statusH.replied && statusH.running) statusH.port.map(p => (p, statusH.token, statusH.maxConn)) else None

    if (!statusH.replied) {
      onStatus("IR_Repl.status: no reply -- loading I/R ML ad-hoc")
      ensureLoaded(irDir) match {
        case Right(node) =>
          onStatus("Waiting for the I/R ML node to consolidate ...")
          awaitConsolidated(node, 120000) match {
            case Right(()) => onStatus("I/R ML node consolidated")
            case Left(msg) => return Left(msg)
          }
        case Left(msg) => return Left(msg)
      }
    }
    else if (statusH.running) onStatus("IR_Repl: ML_Repl already running on port " + statusH.port.getOrElse(0))
    else onStatus("IR_Repl: ML loaded but ML_Repl not running")

    val (mlPort, mlToken, mlMaxConn): (Int, Option[String], Option[Int]) =
      reuse match {
        case Some(t) => t
        case None =>
          portH.port = None; portH.token = None; portH.maxConn = None
          session.protocol_command("IR_Repl.start")
          onStatus("Sent IR_Repl.start")
          val deadline = System.currentTimeMillis() + 15000
          while (portH.port.isEmpty && System.currentTimeMillis() < deadline) Thread.sleep(100)
          portH.port match {
            case Some(p) => onStatus("ML_Repl reported port " + p); (p, portH.token, portH.maxConn)
            case None => return Left("ML_Repl did not report a port within 15s -- cannot start repl.py")
          }
      }

    val isabellePath = Isabelle_System.getenv("ISABELLE_HOME")
    val pb = new ProcessBuilder("python3", replPy, "--daemon", "--expect-ml",
      "--poly-ml-port", mlPort.toString, "--isabelle", isabellePath, "--no-heap-db")
    mlMaxConn.foreach(mc => pb.command().nn.addAll(java.util.List.of("--pool-size", mc.toString)))
    mlToken.foreach(tok => pb.environment().nn.put("IR_REPL_AUTH_TOKEN", tok))
    pb.redirectErrorStream(true)
    onStatus("Executing: " + String.join(" ", pb.command().nn))
    val proc = pb.start().nn

    def stripAnsi(s: String): String = s.replaceAll("\u001b\\[[0-9;]*m", "").nn
    val reader = new java.io.BufferedReader(new java.io.InputStreamReader(proc.getInputStream))
    val portPattern = """Waiting for connections on \S+:(\d+)""".r
    val tokenPattern = """IR_Repl\.token: (\S+)""".r
    var replPort: Option[Int] = None
    var replToken: String = ""
    var eof = false
    var extraLines = 0
    while ((replPort.isEmpty || (replToken.isEmpty && extraLines < 5)) && !eof) {
      val line = reader.readLine()
      if (line == null) { eof = true; onStatus("repl.py: EOF on stdout") }
      else {
        val clean = stripAnsi(line)
        onStatus("repl.py: " + clean)
        portPattern.findFirstMatchIn(clean).foreach(m => replPort = Some(m.group(1).toInt))
        tokenPattern.findFirstMatchIn(clean).foreach(m => replToken = m.group(1))
        if (replPort.isDefined && replToken.isEmpty) extraLines += 1
      }
    }
    replPort match {
      case Some(port) =>
        try {
          val client = new IR_Client(port = port, token = replToken)
          client.connect()
          onStatus("IR_Client connected on port " + port)
          Right(Launched(client, port, if (replToken.nonEmpty) Some(replToken) else None, proc))
        }
        catch { case e: Exception => Left("IR_Client failed to connect: " + e.getMessage) }
      case None => Left("repl.py did not report port")
    }
  }
}
