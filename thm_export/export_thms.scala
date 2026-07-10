import isabelle._

import scala.collection.mutable

@main def export_thms(session_dir: String, session_name: String, out_path: String): Unit = {
  val options = Options.init()
  val background = Sessions.background(options, session_name, dirs = List(Path.explode(session_dir)))
  val file_cache = mutable.Map.empty[String, String]

  // the source text of the proposition, exactly as written after the theorem's name
  def source_statement(entity: Export_Theory.Entity[Export_Theory.Thm]): String =
    if (entity.file.isEmpty) ""
    else {
      val content = file_cache.getOrElseUpdate(entity.file, File.read(Path.explode(entity.file)))
      val stop = Symbol.Text_Chunk(content).decode(entity.range).stop
      val quote1 = content.indexOf('"', stop)
      val quote2 = if (quote1 >= 0) content.indexOf('"', quote1 + 1) else -1
      if (quote2 >= 0) content.substring(quote1 + 1, quote2).trim else ""
    }

  using(Export.open_session_context(Store(options), background)) { session_context =>
    val thms_json =
      for {
        theory_name <- Export_Theory.theory_names(session_context)
        theory = Export_Theory.read_theory(session_context.theory(theory_name))
        entity <- theory.thms
      } yield JSON.Object(
        "theory" -> theory_name,
        "name" -> entity.name,
        "statement" -> source_statement(entity),
        "file" -> entity.file)

    File.write(Path.explode(out_path), JSON.Format(JSON.Object("theorems" -> thms_json)))
    System.err.println(s"Wrote ${thms_json.length} theorems to $out_path")
  }
}
