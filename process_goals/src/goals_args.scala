/*  Title:      goals/src/goals_args.scala
    Author:     Maximilian Schaeffeler

Command-line flags shared by the goal tools: the headless-session selection
(-T/-d/-l/-o/-v) and the goal-sampling options (-s/-m).
*/

package isabelle.goals

import isabelle._


object Goals_Args {
  // -T/-d/-l/-o/-v: the theories and session every goals tool runs over
  class Common {
    var logic: String = Isabelle_System.default_logic()
    var dirs: List[Path] = Nil
    var options: Options = Options.init()
    var theory_files: List[Path] = Nil
    var verbose: Boolean = false

    val getopts: List[(String, String => Unit)] = List(
      "T:" -> (arg => theory_files = theory_files ::: List(Path.explode(arg))),
      "d:" -> (arg => dirs = dirs ::: List(Path.explode(arg))),
      "l:" -> (arg => logic = arg),
      "o:" -> (arg => options = options + arg),
      "v" -> (_ => verbose = true))

    def theories(rest: List[String]): List[String] =
      (theory_files.flatMap(Goals.read_theories) ::: rest).distinct

    def progress: Console_Progress = new Console_Progress(verbose = verbose)
  }

  // -s/-m: keep every Nth goal, at most N goals per theory; -W: restrict to a
  // whitelist file (any of the pipeline phase JSON outputs -- they all carry
  // theory/line/offset, which is all whitelist_selector reads)
  class Selection {
    var stride: Int = 1
    var max_calls: Int = 0
    var whitelist: Option[Path] = None

    val getopts: List[(String, String => Unit)] = List(
      "m:" -> (arg => max_calls = Value.Int.parse(arg)),
      "s:" -> (arg => stride = Value.Int.parse(arg)),
      "W:" -> (arg => whitelist = Some(Path.explode(arg))))

    def selector: Goals.Selector =
      whitelist match {
        case Some(file) => Goals.whitelist_selector(file)
        case None => Goals.default_selector(stride, max_calls)
      }
  }
}
