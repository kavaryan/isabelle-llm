#!/usr/bin/env isabelle scala
/*
  Programmatic Mirabelle extraction script in Isabelle/Scala.
  Invokes the Mirabelle tool natively within the Isabelle Scala runtime.

  Usage:
    isabelle scala extract_mirabelle.scala <session> [output_dir] [max_facts]
  Example:
    isabelle scala extract_mirabelle.scala Dataset out_custom_scala 3
*/

import isabelle._
import isabelle.llm_suggestions.Proof_Context_Parser

object Extract_Mirabelle {
  case class ProofBlock(startIdx: Int, endIdx: Int)

  def find_proof_blocks(spans: List[Command_Span.Span]): List[ProofBlock] = {
    val blocks = new scala.collection.mutable.ListBuffer[ProofBlock]
    val stack = new scala.collection.mutable.Stack[Int]
    
    for ((span, idx) <- spans.zipWithIndex) {
      if (span.name.nonEmpty) {
        val kind = span.kind.keyword_kind.getOrElse("")
        val is_open = Keyword.theory_goal.contains(kind) || Keyword.proof_open.contains(kind)
        val is_close = Keyword.proof_close.contains(kind) || Keyword.qed.contains(kind) || Keyword.qed_global.contains(kind)

        
        if (is_open) {
          stack.push(idx)
        }
        if (is_close && stack.nonEmpty) {
          val start = stack.pop()
          blocks += ProofBlock(start, idx)
        }
      }
    }
    blocks.toList
  }

  def get_remaining_proof_commands(
    spans: List[Command_Span.Span],
    foundIndex: Int,
    blocks: List[ProofBlock]
  ): List[Command_Span.Span] = {
    val containing = blocks.filter(b => b.startIdx <= foundIndex && foundIndex <= b.endIdx)
    if (containing.isEmpty) {
      List(spans(foundIndex))
    } else {
      val innermost = containing.minBy(b => b.endIdx - b.startIdx)
      spans.slice(foundIndex, innermost.endIdx + 1)
    }
  }

  def get_tactic_and_history(
    session: Session,
    theory_name: String,
    file_path: String,
    offset: Int
  ): (String, String, String, List[String], Boolean) = {
    if (theory_name.isEmpty || offset <= 0) ("", "", "", Nil, true)
    else {
      try {
        val opt_node_name = session.resources.session_base.known_theories.get(theory_name).map(_.name)
        val path = if (file_path.nonEmpty) Path.explode(file_path) else Path.explode(opt_node_name.get.node)
        val theory_source = File.read(path)
        
        val syntax = opt_node_name match {
          case Some(node_name) => session.resources.session_base.theory_syntax(node_name)
          case None => session.resources.session_base.overall_syntax
        }
        val spans = syntax.parse_spans(theory_source)
        
        val chunk = Symbol.Text_Chunk(theory_source)
        val char_offset = chunk.decode(offset)
        
        var current_offset = 0
        var found_span: Option[Command_Span.Span] = None
        var found_offset = 0
        var found_idx = -1
        
        val loop = new scala.util.control.Breaks
        loop.breakable {
          for ((span, idx) <- spans.zipWithIndex) {
            val span_len = span.length
            if (char_offset >= current_offset && char_offset < current_offset + span_len) {
              found_span = Some(span)
              found_offset = current_offset
              found_idx = idx
              loop.break()
            }
            current_offset += span_len
          }
        }
        
        found_span match {
          case Some(span) =>
            val tactic = Token.implode(span.content).trim
            val history = theory_source.substring(0, found_offset)
            
            val blocks = find_proof_blocks(spans)
            
            def is_leaf_block(b: ProofBlock): Boolean = {
              !blocks.exists(other => other != b && b.startIdx <= other.startIdx && other.endIdx <= b.endIdx)
            }
            
            val containing = blocks.filter(b => b.startIdx <= found_idx && found_idx <= b.endIdx)
            val (proof_block, proof_commands, is_leaf) = if (containing.isEmpty) {
              ("", Nil, true)
            } else {
              val innermost = containing.minBy(b => b.endIdx - b.startIdx)
              val remaining_spans = spans.slice(found_idx, innermost.endIdx + 1)
              val block_text = remaining_spans.map(s => Token.implode(s.content)).mkString
              val cmds = remaining_spans.map(s => Token.implode(s.content).trim).filter(_.nonEmpty)
              (block_text, cmds, is_leaf_block(innermost))
            }
            
            (tactic, history, proof_block, proof_commands, is_leaf)
          case None => ("", "", "", Nil, true)
        }
      } catch {
        case exn: Throwable =>
          try {
            val error_log = (Path.current + Path.basic("error.log")).absolute.file
            val writer = new java.io.PrintWriter(new java.io.FileWriter(error_log, true))
            writer.println(s"Error in get_tactic_and_history for $theory_name ($file_path) at $offset:")
            exn.printStackTrace(writer)
            writer.close()
          } catch { case _: Throwable => }
          ("", "", "", Nil, true)
      }
    }
  }

  case class PendingEntry(
    goal_name: Option[String] = None,
    cpu_ms: Option[Int] = None,
    proof_text_before: Option[String] = None,
    state_before: Option[String] = None,
    tactic_source: Option[String] = None,
    suggested_facts: Option[List[JSON.T]] = None,
    proof_block: Option[String] = None,
    proof_commands: Option[List[String]] = None,
    is_leaf: Option[Boolean] = None
  )

  def main(args: Array[String]): Unit = {
    if (args.length < 1) {
      System.err.println("Usage: isabelle scala extract_mirabelle.scala <session> [output_dir] [max_facts] [leaf_only]")
      sys.exit(1)
    }
    
    val session = args(0)
    val out_dir = if (args.length >= 2) Path.explode(args(1)) else Path.explode("out_custom_scala")
    val max_facts = if (args.length >= 3) args(2).toInt else 32
    val leaf_only = if (args.length >= 4) (args(3) == "true" || args(3) == "1") else false
    
    Isabelle_System.make_directory(out_dir)
    val log_file = out_dir + Path.basic("mirabelle.log")
    File.write(log_file, "")

    class File_Progress(log: Path) extends Console_Progress(verbose = true) {
      override def output(messages: List[Progress.Msg]): Unit = {
        super.output(messages)
        try {
          val text = output_text(messages, false)
          if (text.nonEmpty) {
            File.append(log, text)
          }
        } catch { case _: Throwable => }
      }
    }

    val options = Options.init()
    val progress = new File_Progress(log_file)
    
    // Include the current directory where the Dataset ROOT is located
    val dirs = List(Path.current)
    val selection = Sessions.Selection(sessions = List(session))
    
    progress.echo(s"[*] Triggering programmatic Mirabelle run for session '$session'...")
    
    // Execute inside an Isabelle-specific thread context
    val runner_thread = Isabelle_Thread.fork(name = "mirabelle_runner", inherit_locals = true) {
      progress.echo("Building required heaps ...")
      val build_results0 =
        Build.build(options, build_heap = true,
          selection = selection.copy(requirements = true), progress = progress, dirs = dirs)
          
      if (!build_results0.ok) {
        progress.echo("[!] Building required heaps failed!")
        sys.exit(build_results0.rc)
      }
      
      // Setup completed in main
      
      val mirabelle_actions_str =
        if (max_facts == 0) "goal_state_export"
        else s"goal_state_export;sledgehammer_export [max_facts = $max_facts]"

      val build_options =
        options + "timeout_build=false" +
          s"mirabelle_actions=$mirabelle_actions_str" +
          ("mirabelle_output_dir=" + out_dir.implode)
          
      progress.echo(s"Running Custom Mirabelle build with actions: $mirabelle_actions_str")
      
      val pending = collection.mutable.Map[(String, Int, Int), PendingEntry]()
      val initialized_theories = collection.mutable.Set[String]()

      def write_record(
        theory_name: String,
        line: Int,
        offset: Int,
        goal_name: String,
        cpu_ms: Int,
        proof_text_before: String,
        state_before: String,
        tactic_source: String,
        suggested_facts: List[JSON.T],
        proof_block: String,
        proof_commands: List[String]
      ): Unit = {
        val json = scala.collection.immutable.ListMap(
          "theory" -> theory_name,
          "line" -> line,
          "offset" -> offset,
          "command" -> goal_name,
          "cpu_ms" -> cpu_ms,
          "proof_text_before" -> proof_text_before,
          "state_before" -> state_before,
          "tactic_source" -> tactic_source,
          "suggested_facts" -> suggested_facts,
          "proof_block" -> proof_block,
          "proof_commands" -> proof_commands
        )
        val theory_log = out_dir + Path.basic(theory_name + ".json")
        initialized_theories.synchronized {
          if (!initialized_theories.contains(theory_name)) {
            File.write(theory_log, "[\n")
            initialized_theories += theory_name
          } else {
            File.append(theory_log, ",\n")
          }
        }
        val record_str = JSON.Format.pretty_print(json).linesIterator.map("  " + _).mkString("\n")
        File.append(theory_log, record_str)
      }

      def write_entry(theory_name: String, line: Int, offset: Int, entry: PendingEntry): Unit = {
        write_record(
          theory_name, line, offset,
          entry.goal_name.getOrElse("unknown"),
          entry.cpu_ms.getOrElse(0),
          entry.proof_text_before.getOrElse(""),
          entry.state_before.getOrElse(""),
          entry.tactic_source.getOrElse(""),
          entry.suggested_facts.getOrElse(Nil),
          entry.proof_block.getOrElse(""),
          entry.proof_commands.getOrElse(Nil)
        )
      }

      def process_export(
        theory_name: String,
        line: Int,
        offset: Int,
        goal_name: String,
        cpu_ms: Int,
        goal_info: Option[(String, String, String, String, List[String], Boolean)], // (state_before, tactic_source, proof_text_before, proof_block, proof_commands, is_leaf)
        facts_info: Option[List[JSON.T]]
      ): Unit = pending.synchronized {
        if (max_facts == 0) {
          // Fast-path: directly write, bypass map entirely
          val (state_before, tactic_source, proof_text_before, proof_block, proof_commands, is_leaf) = goal_info.get
          if (!leaf_only || is_leaf) {
            val entry = PendingEntry(
              goal_name = Some(goal_name),
              cpu_ms = Some(cpu_ms),
              proof_text_before = Some(proof_text_before),
              state_before = Some(state_before),
              tactic_source = Some(tactic_source),
              suggested_facts = Some(Nil),
              proof_block = Some(proof_block),
              proof_commands = Some(proof_commands),
              is_leaf = Some(is_leaf)
            )
            write_entry(theory_name, line, offset, entry)
          }
        } else {
          val key = (theory_name, line, offset)
          val entry = pending.getOrElse(key, PendingEntry())
          
          val new_entry = entry.copy(
            goal_name = entry.goal_name.orElse(Some(goal_name)),
            cpu_ms = entry.cpu_ms.orElse(Some(cpu_ms)),
            proof_text_before = entry.proof_text_before.orElse(goal_info.map(_._3)),
            state_before = entry.state_before.orElse(goal_info.map(_._1)),
            tactic_source = entry.tactic_source.orElse(goal_info.map(_._2)),
            suggested_facts = entry.suggested_facts.orElse(facts_info),
            proof_block = entry.proof_block.orElse(goal_info.map(_._4)),
            proof_commands = entry.proof_commands.orElse(goal_info.map(_._5)),
            is_leaf = entry.is_leaf.orElse(goal_info.map(_._6))
          )
          
          if (new_entry.state_before.isDefined && new_entry.suggested_facts.isDefined) {
            if (!leaf_only || new_entry.is_leaf.getOrElse(true)) {
              write_entry(theory_name, line, offset, new_entry)
            }
            pending.remove(key)
          } else {
            pending(key) = new_entry
          }
        }
      }

      def session_setup(session_name: String, session: Session): Unit = {
        session.all_messages +=
          Session.Consumer[Prover.Message]("dataset_export") {
            case msg: Prover.Protocol_Output =>
              msg.properties match {
                case Protocol.Export(args) if args.name.startsWith("mirabelle/") =>
                  try {
                    val yxml = YXML.parse_body(msg.chunk)
                    Export.explode_name(args.name) match {
                      case List("mirabelle", action, "goal", goal_name, line, offset, cpu_ms) =>
                        if (action.endsWith("goal_state_export")) {
                          yxml match {
                            case List(goal_elem) if Proof_Context_Parser.parse_proof_goal(goal_elem).isDefined =>
                              val Some((file_path, offset_val, state_before)) =
                                Proof_Context_Parser.parse_proof_goal(goal_elem): @unchecked
                              val (tactic_source, proof_text_before, proof_block, proof_commands, is_leaf) =
                                get_tactic_and_history(session, args.theory_name, file_path, offset_val)
                              process_export(
                                args.theory_name, line.toInt, offset.toInt,
                                goal_name, cpu_ms.toInt,
                                Some((state_before, tactic_source, proof_text_before, proof_block, proof_commands, is_leaf)),
                                None
                              )
                            case _ =>
                              progress.echo("Ignoring non-standard proof_goal export: " + args.compound_name)
                          }
                        } else if (action.endsWith("sledgehammer_export")) {
                          yxml match {
                            case List(facts_elem) if Proof_Context_Parser.parse_facts(facts_elem).isDefined =>
                              val suggested_facts =
                                Proof_Context_Parser.parse_facts(facts_elem).getOrElse(Nil).map { f =>
                                  JSON.Object("name" -> f.display_name, "statement" -> f.statement)
                                }
                              process_export(
                                args.theory_name, line.toInt, offset.toInt,
                                goal_name, cpu_ms.toInt,
                                None,
                                Some(suggested_facts)
                              )
                            case _ =>
                              progress.echo("Ignoring non-standard suggested_facts export: " + args.compound_name)
                          }
                        } else {
                          progress.echo("Unknown action in export: " + action)
                        }

                      case List("mirabelle", action, "initialize") =>
                        progress.echo("Action initialized: " + action)
                      case List("mirabelle", action, "finalize") =>
                        progress.echo("Action finalized: " + action)
                      case _ =>
                        progress.echo("Unhandled mirabelle export compound name: " + args.compound_name)
                    }
                  } catch {
                    case exn: Throwable =>
                      progress.echo("Error processing export " + args.compound_name + ": " + exn.getMessage)
                  }
                case _ =>
              }
            case _ =>
          }
      }
      
      val results =
        Build.build(build_options, clean_build = true,
          selection = selection, progress = progress, dirs = dirs, session_setup = session_setup)
          
      // Flush any remaining unmatched goals to the log file (e.g. if sledgehammer didn't produce an export for some goals)
      pending.synchronized {
        if (pending.nonEmpty) {
          progress.echo(s"Flushing ${pending.size} unmatched goal states from buffer...")
          for (((theory_name, line, offset), entry) <- pending) {
            if (!leaf_only || entry.is_leaf.getOrElse(true)) {
              write_entry(theory_name, line, offset, entry)
            }
          }
          pending.clear()
        }
      }

      // Finalize JSON array in theory files
      initialized_theories.synchronized {
        for (theory_name <- initialized_theories) {
          val theory_log = out_dir + Path.basic(theory_name + ".json")
          File.append(theory_log, "\n]\n")
        }
      }

      if (results.ok) {
        progress.echo(s"[+] Mirabelle run successful! Logs saved in $out_dir")
        sys.exit(0)
      } else {
        progress.echo(s"[!] Mirabelle run failed!")
        sys.exit(results.rc)
      }
    }
    
    runner_thread.join()
  }
}
