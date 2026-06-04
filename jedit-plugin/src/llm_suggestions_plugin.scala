package isabelle.llm_suggestions

import isabelle._
import isabelle.jedit._
import org.gjt.sp.jedit.{EBMessage, EBPlugin}

class LLM_Suggestions_Plugin extends EBPlugin {
  override def start(): Unit = {
    Output.writeln("Isabelle LLM Suggestions Plugin starting...")
  }

  override def stop(): Unit = {
    Output.writeln("Isabelle LLM Suggestions Plugin stopping...")
  }

  override def handleMessage(message: EBMessage): Unit = {
    // Handle jEdit messages if needed
  }
}
