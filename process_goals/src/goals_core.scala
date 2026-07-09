/*  Title:      goals/src/goals_core.scala
    Author:     Maximilian Schaeffeler

Ingest a set of theories into one headless session and select their proof-goal
sites. A `Selector` is the extensible plug point.
*/

package isabelle.goals

import isabelle._


object Goals {
  // the proof state before command `name` lives at `range`
  final case class Site(range: Text.Range, name: String, line: Int, offset: Int)

  // the theory's short name, used uniformly in progress, records and whitelists
  def theory_name(node_name: Document.Node.Name): String = Long_Name.base_name(node_name.theory)

  // whole seconds for an ML operation's timeout argument (at least 1)
  def timeout_secs(timeout: Time): String = Math.max(1, timeout.seconds.ceil.toInt).toString

  def command_of(snapshot: Document.Snapshot, range: Text.Range): Command =
    snapshot.node.command_iterator(range).map(_._1).nextOption()
      .getOrElse(error("No command in range " + range))

  // theory names from a file: one per line, blanks and #-comments skipped
  def read_theories(file: Path): List[String] =
    Library.trim_split_lines(File.read(file)).filterNot(s => s.isEmpty || s.startsWith("#"))

  // MePo-ranked "name [attrs]: statement" fact lines for the goal (empty if max_facts <= 0)
  def suggested_facts(session: Session, snapshot: Document.Snapshot, range: Text.Range,
    max_facts: Int, timeout: Time): List[String] =
    if (max_facts <= 0) Nil
    else Goals_Query.run(session, snapshot, range, "suggested_facts_rich", List(max_facts.toString), timeout)

  // one candidate per proof step: the state before each proper command
  def candidate_sites(snapshot: Document.Snapshot): List[Site] = {
    val cmds = proper(snapshot)
    val doc = Line.Document(snapshot.node.source)
    for { ((prev, prev_off), (step, step_off)) <- cmds.zip(cmds.drop(1)) }
      yield Site(prev.range + prev_off, step.span.name, doc.position(step_off).line + 1, step_off + 1)
  }

  // keep every nth goal (n = stride, or length/max_calls if stride <= 0), capped at max_calls
  def sample[A](xs: List[A], stride: Int, max_calls: Int): List[A] = {
    val n = if (stride > 0) stride else Math.max(1, if (max_calls > 0) xs.length / max_calls else 1)
    xs.zipWithIndex.collect { case (x, i) if (i + 1) % n == 0 => x } match {
      case ys if max_calls > 0 => ys.take(max_calls); case ys => ys }
  }

  // the proof state shown before the step (read from the snapshot; needs show_states)
  def goal_state(snapshot: Document.Snapshot, range: Text.Range): String =
    cat_lines(
      (for {
        (cmd, _) <- snapshot.node.command_iterator(range)
        case (_, elem: XML.Elem) <- snapshot.command_results(cmd).iterator
        if Protocol.is_state(elem)
      } yield XML.content(elem)).toList)

  // the bare fact name from a "name [attrs]: statement" suggestion line
  private def fact_name(line: String): String = {
    val cut = List(line.indexOf(": "), line.indexOf(" [")).filter(_ >= 0)
    if (cut.isEmpty) line else line.substring(0, cut.min).nn
  }

  // a live preview block for one goal: trailing context lines, the goal state, and
  // (when max_facts > 0) the suggested fact names. Each entry is one log line.
  def preview(session: Session, snapshot: Document.Snapshot, struct: Structure, site: Site,
    context_lines: Int, max_facts: Int, timeout: Time): List[String] = {
    val ctx =
      Library.split_lines(proof_text_before(struct, site.range, 0))
        .map(_.stripTrailing.nn).filter(_.trim.nn.nonEmpty).takeRight(context_lines)
    val goal = Library.split_lines(goal_state(snapshot, site.range)).filter(_.trim.nn.nonEmpty)
    val facts = suggested_facts(session, snapshot, site.range, max_facts, timeout).map(fact_name)
    ctx.map("  | " + _) ::: goal.map("  ⊢ " + _) :::
      (if (facts.isEmpty) Nil else List("  facts: " + facts.mkString(", ")))
  }

  // theory text up to (and including) the step, keeping the last max_symbols (0 = full)
  def proof_text_before(struct: Structure, range: Text.Range, max_symbols: Int): String = {
    val upto = struct.source.substring(0, range.stop min struct.source.length).nn
    if (max_symbols <= 0) upto
    else {
      val syms = Symbol.explode(upto)
      if (syms.length <= max_symbols) upto else syms.takeRight(max_symbols).mkString
    }
  }

  private def proper(snapshot: Document.Snapshot): List[(Command, Int)] =
    snapshot.node.command_iterator().collect { case (c, o) if c.is_proper => (c, o) }.toList

  // (start, stop) index pairs of proof blocks among proper commands
  private def proof_blocks(cmds: List[Command]): List[(Int, Int)] = {
    val blocks = new scala.collection.mutable.ListBuffer[(Int, Int)]
    val stack = new scala.collection.mutable.Stack[Int]
    for ((c, idx) <- cmds.zipWithIndex if c.span.name.nonEmpty) {
      val kind = c.span.kind.keyword_kind.getOrElse("")
      if (Keyword.theory_goal.contains(kind) || Keyword.proof_open.contains(kind)) stack.push(idx)
      if ((Keyword.proof_close.contains(kind) || Keyword.qed.contains(kind) || Keyword.qed_global.contains(kind))
          && stack.nonEmpty)
        blocks += ((stack.pop(), idx))
    }
    blocks.toList
  }

  // per-theory data shared across that theory's goals (computed once, read concurrently);
  // command offsets index into `source` by character
  final case class Structure(cmds: List[(Command, Int)], blocks: List[(Int, Int)], source: String) {
    lazy val source_hash: String = Goals_Hash.sha256(source)
  }

  def structure(snapshot: Document.Snapshot): Structure = {
    val cmds = proper(snapshot)
    Structure(cmds, proof_blocks(cmds.map(_._1)), snapshot.node.source)
  }

  // the proof block enclosing the step command at source offset `off`
  final case class Block_Info(block: String, commands: List[String], is_leaf: Boolean, has_apply: Boolean)
  object Block_Info { val empty: Block_Info = Block_Info("", Nil, is_leaf = true, has_apply = false) }

  def block_info(struct: Structure, off: Int): Block_Info = {
    val cmds = struct.cmds
    val idx = cmds.indexWhere(_._2 == off)
    if (idx < 0) Block_Info.empty
    else {
      val containing = struct.blocks.filter { case (s, e) => s <= idx && idx <= e }
      if (containing.isEmpty) Block_Info.empty
      else {
        val inner = containing.minBy { case (s, e) => e - s }
        val is_leaf = !struct.blocks.exists(b => b != inner && inner._1 <= b._1 && b._2 <= inner._2)
        val has_apply = cmds.slice(inner._1, inner._2 + 1).exists(_._1.span.name == "apply")
        // contiguous source from the step to the end of the block, preserving whitespace
        val stop = if (inner._2 + 1 < cmds.length) cmds(inner._2 + 1)._2 else struct.source.length
        val block = struct.source.substring(off, stop).nn
        val commands = cmds.slice(idx, inner._2 + 1).map(_._1.source.trim.nn).filter(_.nonEmpty)
        Block_Info(block, commands, is_leaf, has_apply)
      }
    }
  }

  // a Selector turns a checked snapshot into the goals to act on
  type Selector = (Session, Document.Node.Name, Document.Snapshot) => List[Site]

  def default_selector(stride: Int = 1, max_calls: Int = 0): Selector =
    (session, _, snapshot) => {
      val cands = candidate_sites(snapshot)
      // the selectable batch processes one overlay per candidate, so scale its budget
      val timeout = Time.seconds(30.0 + 0.1 * cands.length)
      val verdicts =
        Goals_Query.run_many(session, snapshot, cands.map(_.range), "selectable", Nil, timeout)
      sample(cands.zip(verdicts).collect { case (c, v) if v.headOption.contains("1") => c }, stride, max_calls)
    }

  // restrict to the goals listed in a hard-set whitelist, by theory + position
  def whitelist_selector(file: Path): Selector = {
    val all = Goals_Output.read_whitelist(file)
    (_, node_name, snapshot) => {
      val keep = all.filter(_.theory == theory_name(node_name)).map(g => (g.line, g.offset)).toSet
      candidate_sites(snapshot).filter(s => keep((s.line, s.offset)))
    }
  }

  // select the goals of `snapshot`, then run `body` over each (in parallel by default),
  // echoing a per-theory count and a verbose per-goal progress line
  def map_goals[A](
    select: Selector, session: Session, node_name: Document.Node.Name, snapshot: Document.Snapshot,
    progress: Progress, parallel: Boolean = true
  )(body: Site => A): List[A] = {
    val sites = select(session, node_name, snapshot)
    val total = sites.length
    progress.echo(total + " goals in " + theory_name(node_name))
    val done = Synchronized(0)
    def one(site: Site): A = {
      val r = body(site)
      val n = done.change_result(c => (c + 1, c + 1))
      progress.echo("  goal " + n + "/" + total + " @ " + site.line + ":" + site.offset, verbose = true)
      r
    }
    if (parallel) Par_List.map(one, sites) else sites.map(one)
  }

  def home: Path = Path.explode("$GOALS_HOME")

  // headless session over a set of theories, grouped by the session that owns each one:
  // session theories load on that owner's prebuilt requirements, standalone files/names on
  // `base_logic`. After loading the Goals_Queries ML ops, `body` runs per checked theory; a
  // failing theory is logged and skipped. (The goals analogue of Dump.Context: a thin loop
  // over stock Headless.)
  def with_theories[A](
    theories: List[String], options: Options, dirs: List[Path], base_logic: String, progress: Progress
  )(body: (Session, Document.Node.Name, Document.Snapshot) => A): List[A] = {
    if (theories.isEmpty) error("No theories given")
    val structure = Sessions.load_structure(options, dirs = dirs)
    theories.groupBy(structure.theory_qualifier).toList.flatMap { case (owner, names) =>
      val logic = if (owner.nonEmpty) owner else proper_string(base_logic).getOrElse(Isabelle_System.default_logic())
      val background =
        Sessions.background(options, logic, dirs = dirs, session_requirements = owner.nonEmpty,
          progress = progress).check_errors
      progress.echo("Building " + background.session_name + " ...")
      Build.build(options, selection = Sessions.Selection.session(background.session_name),
        build_heap = true, dirs = dirs, infos = background.infos, progress = progress).check
      // show_states only on the interactive session: goal_state reads it from command markup
      val resources = Headless.Resources(options + "show_states=true", background, new System_Logger())
      val session = resources.start_session(progress = progress)
      try {
        if (!session.use_theories(List("Goals_Queries"),
          master_dir = (home + Path.basic("src")).implode, progress = progress).ok)
          error("Goals_Queries.thy did not load cleanly")
        names.zipWithIndex.flatMap { case (origin, i) =>
          progress.echo("=== [" + (i + 1) + "/" + names.length + "] " + origin + " ===")
          Exn.capture {
            val node_name = resources.import_name(Sessions.DRAFT, "", origin)
            val result = session.use_theories(List(origin), progress = progress)
            if (!result.ok) progress.echo_warning(origin + " did not check cleanly")
            body(session, node_name, result.snapshot(node_name))
          } match {
            case Exn.Res(a) => Some(a)
            case Exn.Exn(exn) => progress.echo_warning(origin + " skipped: " + Exn.message(exn)); None
          }
        }
      }
      finally session.stop()
    }
  }
}
