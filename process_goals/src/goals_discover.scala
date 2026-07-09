/*  Title:      goals/src/goals_discover.scala

Phase 1 of the distillation pipeline: record goal positions

*/

package isabelle.goals

import isabelle._


class Discover_Probe extends JSON_Probe {
  def name = "discover"
  override def description = "phase 1: record goal positions + theory source hash"

  def apply(c: Probe.Context): Option[JSON.T] =
    Some(JSON.Object(
      "theory" -> c.theory, "line" -> c.site.line, "offset" -> c.site.offset,
      "command" -> c.site.name, "file_hash" -> c.struct.source_hash))
}