/*  Title:      goals/src/goals_query.scala
    Author:     Maximilian Schaeffeler

Run a registered ML query operation headlessly against a snapshot and return its
writeln lines.
*/

package isabelle.goals

import isabelle._


object Goals_Query {
  private val overlays = Synchronized(Map.empty[Document.Node.Name, Document.Node.Overlays])

  private def change_overlays(session: Session, node_name: Document.Node.Name)(
    f: Document.Node.Overlays => Document.Node.Overlays
  ): Unit =
    overlays.change { all =>
      val updated = f(all.getOrElse(node_name, Document.Node.Overlays.empty))
      session.update(Document.Blobs.empty,
        List(node_name -> Document.Node.Perspective(true, Text.Perspective.full, updated)))
      if (updated.is_empty) all - node_name else all + (node_name -> updated)
    }

  // the <op>_query messages tagged with `instance` in the command's results
  private def instance_messages(
    snapshot: Document.Snapshot, command: Command, instance: String
  ): List[(String, XML.Body)] =
    (for {
      case (_, XML.Elem(Markup(Markup.RESULT, Markup.Instance(`instance`)), List(XML.Elem(markup, body))))
        <- snapshot.command_results(command).iterator
    } yield markup.name -> body).toList

  // writeln lines of a finished operation, raising its error if any
  private def lines_of(messages: List[(String, XML.Body)]): List[String] =
    messages.collect { case (Markup.ERROR, body) => XML.content(body) } match {
      case Nil =>
        messages.collect { case (Markup.WRITELN, body) => XML.content(body) }
          .flatMap(_.linesIterator.filter(_.nonEmpty))
      case errors => error(cat_lines(errors))
    }

  // install a temporary <op>_query overlay on the command at `range`, block until it
  // finishes, and return its writeln lines (raises on the operation's error or timeout)
  def run(session: Session, snapshot: Document.Snapshot, range: Text.Range,
    op: String, args: List[String], timeout: Time): List[String] =
    run_many(session, snapshot, List(range), op, args, timeout).head

  // run `op` on every range in one document update, blocking until all finish; results
  // are returned in the order of `ranges` (raises on any operation's error or timeout)
  def run_many(session: Session, snapshot: Document.Snapshot, ranges: List[Text.Range],
    op: String, args: List[String], timeout: Time): List[List[String]] = {
    if (ranges.isEmpty) Nil
    else {
      val node_name = snapshot.node_name
      val overlay = op + "_query"
      // one probe per range: (command, instance, overlay_args)
      val probes =
        ranges.map { range =>
          val instance = Document_ID.make().toString
          (Goals.command_of(snapshot, range), instance, instance :: args)
        }
      val commands = probes.map(_._1).toSet

      val result = Synchronized[Option[List[List[String]]]](None)
      def check(): Unit = {
        val snap = session.get_state().snapshot(node_name)
        if (!snap.is_outdated && commands.forall(snap.node.commands.contains)) {
          val messages = probes.map { case (c, i, _) => instance_messages(snap, c, i) }
          if (messages.forall(_.exists(_._1 == Markup.FINISHED)))
            result.change(_ => Some(messages.map(lines_of)))
        }
      }

      val consumer =
        Session.Consumer[Session.Commands_Changed]("goals_query") { changed =>
          if (result.value.isEmpty && changed.commands.exists(commands)) check()
        }
      session.commands_changed += consumer
      try {
        change_overlays(session, node_name)(ov =>
          probes.foldLeft(ov) { case (ov, (c, _, ov_args)) => ov.insert(c, overlay, ov_args) })
        val deadline = Time.now() + timeout
        result.timed_access[List[List[String]]](_ => Some(deadline), st => st.map((_, st)))
          .getOrElse(error(op + " timed out after " + timeout.message))
      }
      finally {
        session.commands_changed -= consumer
        change_overlays(session, node_name)(ov =>
          probes.foldLeft(ov) { case (ov, (c, _, ov_args)) => ov.remove(c, overlay, ov_args) })
      }
    }
  }
}
