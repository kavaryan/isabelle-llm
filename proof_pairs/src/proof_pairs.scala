/*  Title:      proof_pairs/src/proof_pairs.scala
    Author:     isabelle-llm

Adhoc proof-pair extraction built on top of the official `isabelle
process_theories` tool.

Phase 1 (extract): compose an adhoc "Draft" session (via process_theories)
that re-elaborates the requested theories, with a custom build presentation
hook injected as source files. The hook (proof_pairs_hook.ML) fires on the
requested theories regardless of session qualifier -- unlike Mirabelle's hook,
which is restricted to the build session and is therefore incompatible with the
Draft session. For each proof step it exports a goal-state node and, optionally,
MePo-suggested facts, produced by the shared Proof_Context_Exporter.

Phase 2 (parse): read the structured exports together with the original theory
sources, reconstruct the surrounding proof block via the outer syntax, and emit
one JSON array per theory.
*/

package isabelle.proof_pairs

import java.io.{File => JFile}

import isabelle._


object Proof_Pairs {
  /* injected source files: the custom hook + the goal-state/facts exporter */

  def home: Path = Path.explode("$ISABELLE_PROOF_PAIRS_HOME")

  def injected_files: List[Path] =
    List(
      home + Path.explode("ml/Proof_Pairs_Hook.thy"),
      home + Path.explode("ml/proof_pairs_hook.ML"),
      home + Path.explode("ml/proof_context_exporter.ML"))

  def read_theories(file: Path): List[String] =
    Library.trim_split_lines(File.read(file)).filterNot(s => s.isEmpty || s.startsWith("#"))


  /** phase 1: extract via process_theories + custom hook **/

  val EXPORT_PATTERN = "*:proof_pairs/**"

  def extract(
    options: Options,
    logic: String,
    theories: List[String],
    max_facts: Int,
    leaf_only: Boolean,
    export_dir: Path,
    progress: Progress = new Progress
  ): Build.Results = {
    val extract_options =
      options +
        ("proof_pairs_theories=" + theories.mkString(",")) +
        ("proof_pairs_max_facts=" + max_facts) +
        ("proof_pairs_leaf_only=" + leaf_only)

    progress.echo("Extracting " + theories.length + " theories on logic " + quote(logic) +
      (if (max_facts > 0) " with " + max_facts + " suggested facts/goal" else "") + " ...")

    Process_Theories.process_theories(
      extract_options,
      logic,
      theories = theories,
      files = injected_files,
      export_files = List((export_dir.absolute.implode, 0, List(EXPORT_PATTERN))),
      progress = progress)
  }


  /** phase 2: parse exports into JSON **/

  sealed case class Record(
    theory: String, line: Int, offset: Int,
    command: String = "",
    proof_text_before: String = "",
    state_before: String = "",
    suggested_facts: List[JSON.T] = Nil,
    proof_block: String = "",
    proof_commands: List[String] = Nil,
    is_leaf: Boolean = true,
    has_apply: Boolean = false
  ) {
    def json: JSON.T =
      JSON.Object(
        "theory" -> theory,
        "line" -> line,
        "offset" -> offset,
        "command" -> command,
        "proof_text_before" -> proof_text_before,
        "state_before" -> state_before,
        "suggested_facts" -> suggested_facts,
        "proof_block" -> proof_block,
        "proof_commands" -> proof_commands,
        "is_leaf" -> is_leaf)
  }

  /* outer syntax per qualifier session, loaded once and cached */

  private class Syntax_Cache(options: Options) {
    private val cache = Synchronized(Map.empty[String, Outer_Syntax])
    def apply(qualifier: String): Outer_Syntax =
      cache.change_result { tab =>
        tab.get(qualifier) match {
          case Some(syntax) => (syntax, tab)
          case None =>
            val syntax =
              if (qualifier.isEmpty) Thy_Header.bootstrap_syntax
              else Sessions.background(options, qualifier).base.overall_syntax
            (syntax, tab + (qualifier -> syntax))
        }
      }
  }

  /* proof-block structure over command spans (cf. extract_mirabelle.scala) */

  private sealed case class Proof_Block(start: Int, stop: Int)

  private def find_proof_blocks(spans: List[Command_Span.Span]): List[Proof_Block] = {
    val blocks = new scala.collection.mutable.ListBuffer[Proof_Block]
    val stack = new scala.collection.mutable.Stack[Int]
    for ((span, idx) <- spans.zipWithIndex if span.name.nonEmpty) {
      val kind = span.kind.keyword_kind.getOrElse("")
      if (Keyword.theory_goal.contains(kind) || Keyword.proof_open.contains(kind))
        stack.push(idx)
      if ((Keyword.proof_close.contains(kind) || Keyword.qed.contains(kind) ||
            Keyword.qed_global.contains(kind)) && stack.nonEmpty)
        blocks += Proof_Block(stack.pop(), idx)
    }
    blocks.toList
  }

  /* reconstruct the proof block enclosing the command at a symbol-offset */

  private def reconstruct(
    source: String,
    spans: List[Command_Span.Span],
    offset: Int
  ): (String, String, List[String], Boolean, Boolean) = {
    val char_offset = Symbol.Text_Chunk(source).decode(offset)

    var current = 0
    var found_idx = -1
    var found_start = 0
    val loop = new scala.util.control.Breaks
    loop.breakable {
      for ((span, idx) <- spans.zipWithIndex) {
        val len = span.length
        if (char_offset >= current && char_offset < current + len) {
          found_idx = idx; found_start = current; loop.break()
        }
        current += len
      }
    }

    if (found_idx < 0) (source.substring(0, char_offset min source.length), "", Nil, true, false)
    else {
      val history = source.substring(0, found_start)
      val blocks = find_proof_blocks(spans)
      // a block is a leaf if no other block is nested strictly inside it
      def is_leaf_block(b: Proof_Block): Boolean =
        !blocks.exists(o => o != b && b.start <= o.start && o.stop <= b.stop)
      val containing = blocks.filter(b => b.start <= found_idx && found_idx <= b.stop)
      val (proof_block, proof_commands, is_leaf, has_apply) =
        if (containing.isEmpty) ("", Nil, true, false)
        else {
          val innermost = containing.minBy(b => b.stop - b.start)
          val remaining = spans.slice(found_idx, innermost.stop + 1)
          val block_spans = spans.slice(innermost.start, innermost.stop + 1)
          val has_apply = block_spans.exists(_.name == "apply")
          (remaining.map(s => Token.implode(s.content)).mkString,
           remaining.map(s => Token.implode(s.content).trim).filter(_.nonEmpty),
           is_leaf_block(innermost),
           has_apply)
        }
      (history, proof_block, proof_commands, is_leaf, has_apply)
    }
  }

  /* one structured export per goal:
     <proof_pair theory= command= line=><proof_goal/>[<suggested_facts/>] */

  private sealed case class Raw(
    theory: String, command: String, line: Int,
    file_path: String, offset: Int, state: String,
    facts: List[Proof_Context_Parser.Fact])

  private def read_export(file: JFile): Option[Raw] =
    YXML.parse_body(YXML.Source(File.read(file))) match {
      case List(XML.Elem(Markup("proof_pair", props), body)) =>
        val goal = body.collectFirst { case e @ XML.Elem(Markup("proof_goal", _), _) => e }
          .flatMap(Proof_Context_Parser.parse_proof_goal)
        goal.map { case (file_path, offset, state) =>
          val facts = body.collectFirst { case e @ XML.Elem(Markup("suggested_facts", _), _) => e }
            .flatMap(Proof_Context_Parser.parse_facts).getOrElse(Nil)
          Raw(
            theory = Properties.get(props, "theory").getOrElse(""),
            command = Properties.get(props, "command").getOrElse(""),
            line = Properties.get(props, "line").map(Value.Int.parse).getOrElse(0),
            file_path = file_path, offset = offset, state = state, facts = facts)
        }
      case _ => None
    }

  private def facts_json(facts: List[Proof_Context_Parser.Fact]): List[JSON.T] =
    facts.map(f =>
      JSON.Object(
        "name" -> Symbol.decode(f.display_name),
        "statement" -> Symbol.decode(f.statement)))

  /* keep at most the last `max_symbols` Isabelle symbols (0 = unlimited);
     truncates on a symbol boundary so symbol sequences stay intact */
  private def limit_context(text: String, max_symbols: Int): String =
    if (max_symbols <= 0) text
    else {
      val syms = Symbol.explode(text)
      if (syms.length <= max_symbols) text else syms.takeRight(max_symbols).mkString
    }

  def parse(
    options: Options,
    export_dir: Path,
    json_dir: Path,
    leaf_only: Boolean = false,
    no_apply: Boolean = false,
    context_symbols: Int = 0,
    progress: Progress = new Progress
  ): Map[String, Int] = {
    val syntax_cache = new Syntax_Cache(options)
    val span_cache = Synchronized(Map.empty[String, (String, List[Command_Span.Span])])
    def parsed(file_path: String, qualifier: String): (String, List[Command_Span.Span]) =
      span_cache.change_result(tab =>
        tab.get(file_path) match {
          case Some(v) => (v, tab)
          case None =>
            val src = File.read(Path.explode(file_path))
            val v = (src, syntax_cache(qualifier).parse_spans(src))
            (v, tab + (file_path -> v))
        })

    val files =
      if (export_dir.is_dir) File.find_files(export_dir.file, file => file.isFile) else Nil
    val records =
      for { file <- files; raw <- read_export(file) } yield {
        val (history, block, commands, is_leaf, has_apply) =
          if (raw.file_path.isEmpty) ("", "", Nil, true, false)
          else
            try { val (src, spans) = parsed(raw.file_path, Long_Name.qualifier(raw.theory))
                  reconstruct(src, spans, raw.offset) }
            catch { case exn: Throwable =>
              progress.echo_warning("reconstruct failed for " + raw.theory +
                " @" + raw.offset + ": " + exn.getMessage)
              ("", "", Nil, true, false) }
        Record(
          theory = Long_Name.base_name(raw.theory),
          line = raw.line,
          offset = raw.offset,
          command = Symbol.decode(raw.command),
          proof_text_before = Symbol.decode(limit_context(history, context_symbols)),
          state_before = Symbol.decode(raw.state),
          suggested_facts = facts_json(raw.facts),
          proof_block = Symbol.decode(block),
          proof_commands = commands.map(Symbol.decode),
          is_leaf = is_leaf,
          has_apply = has_apply)
      }

    Isabelle_System.make_directory(json_dir)
    val kept = records.filter(r => (!leaf_only || r.is_leaf) && (!no_apply || !r.has_apply))
    val by_theory = kept.groupBy(_.theory)
    for ((theory, recs) <- by_theory) {
      val sorted = recs.sortBy(r => (r.line, r.offset))
      val arr: JSON.T = sorted.map(_.json)
      File.write(json_dir + Path.basic(theory + ".json"), JSON.Format.pretty_print(arr))
    }
    by_theory.view.mapValues(_.length).toMap
  }


  /** end-to-end **/

  /* Theories are grouped by their session and each group is re-elaborated on
     that session's parent (so everything below the session is supplied
     prebuilt and only the session's own theories re-run). An explicit `logic`
     overrides this for every group. */

  def proof_pairs(
    options: Options,
    logic: Option[String],
    theories: List[String],
    max_facts: Int,
    output_dir: Path,
    leaf_only: Boolean = false,
    no_apply: Boolean = false,
    context_symbols: Int = 0,
    progress: Progress = new Progress
  ): Unit = {
    if (theories.isEmpty) error("No theories given")
    val export_dir = output_dir + Path.basic("export")
    val json_dir = output_dir + Path.basic("json")
    if (export_dir.is_dir) Isabelle_System.rm_tree(export_dir)
    Isabelle_System.make_directory(output_dir)

    val structure = Sessions.load_structure(options)
    def base_logic(session: String): String =
      logic.getOrElse(structure(session).parent.getOrElse("Pure"))

    val by_session = theories.groupBy(Long_Name.qualifier).toList.sortBy(_._1)
    var grand_total = 0
    var theories_count = 0
    for ((session, group) <- by_session) {
      val base = base_logic(session)
      progress.echo("=== session " + quote(session) + " on base " + quote(base) +
        ": " + group.length + " theories ===")
      val results = extract(options, base, group, max_facts, leaf_only, export_dir, progress = progress)
      if (!results.ok) error("Extraction failed for session " + quote(session) +
        " (rc = " + results.rc + ")")

      progress.echo("Parsing exports for session " + quote(session) +
        (if (leaf_only) " (leaf proofs only)" else "") +
        (if (no_apply) " (excluding apply proofs)" else "") + " ...")
      val counts = parse(options, export_dir, json_dir,
        leaf_only = leaf_only, no_apply = no_apply, context_symbols = context_symbols, progress = progress)
      val total = counts.valuesIterator.sum
      grand_total += total
      theories_count += counts.size
      for ((theory, n) <- counts.toList.sortBy(-_._2)) {
        progress.echo("Wrote " + n + " proof-step records for " + theory + " -> " + json_dir)
      }

      if (export_dir.is_dir) Isabelle_System.rm_tree(export_dir)
    }

    progress.echo("Finished! Wrote a grand total of " + grand_total + " proof-step records across " +
      theories_count + " theories -> " + json_dir)
  }
}
