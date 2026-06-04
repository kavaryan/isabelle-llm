package isabelle.proof_extractor

import isabelle._

/* Parser for the XML produced by Proof_Context_Exporter
   (proof_context_exporter.ML): <proof_goal>/<state> and
   <suggested_facts>/<fact>. Used by both the LLM Suggestions dockable and
   the Mirabelle data-extraction script (extract_mirabelle.scala). */
object Proof_Context_Parser {
  def get_text(tree: XML.Tree): String = tree match {
    case XML.Elem(_, body) => body.collect { case XML.Text(s) => s }.mkString
    case XML.Text(s) => s
  }

  /* <proof_goal><position file=.. offset=../><state>..</state></proof_goal> */
  def parse_proof_goal(tree: XML.Tree): Option[(String, Int, String)] = tree match {
    case XML.Elem(Markup("proof_goal", _), List(pos_node, state_node)) =>
      val (file_path, offset) = pos_node match {
        case XML.Elem(Markup("position", props), _) =>
          val f = props.collectFirst { case ("file", v) => v }.getOrElse("")
          val o = props.collectFirst { case ("offset", v) => v.toInt }.getOrElse(0)
          (f, o)
        case _ => ("", 0)
      }
      Some((file_path, offset, get_text(state_node)))
    case _ => None
  }

  final case class Fact(name: String, statement: String,
    simp: Boolean, intro: Boolean, elim: Boolean) {
    def attrs: List[String] =
      List(if (simp) Some("simp") else None,
           if (intro) Some("intro") else None,
           if (elim) Some("elim") else None).flatten
    def display_name: String = if (attrs.isEmpty) name else s"$name [${attrs.mkString(",")}]"
  }

  /* <suggested_facts>(<fact name=.. simp/intro/elim>stmt</fact>)*</suggested_facts> */
  def parse_facts(tree: XML.Tree): Option[List[Fact]] = tree match {
    case XML.Elem(Markup("suggested_facts", _), fact_elements) =>
      Some(fact_elements.collect {
        case XML.Elem(Markup("fact", props), body) =>
          val name = props.collectFirst { case ("name", v) => v }.getOrElse("")
          val statement = body.collect { case XML.Text(s) => s }.mkString
          Fact(name, statement,
            props.exists(p => p._1 == "simp"  && p._2 == "true"),
            props.exists(p => p._1 == "intro" && p._2 == "true"),
            props.exists(p => p._1 == "elim"  && p._2 == "true"))
      })
    case _ => None
  }
}
