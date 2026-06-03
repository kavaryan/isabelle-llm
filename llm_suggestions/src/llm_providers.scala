package isabelle.llm_suggestions

import isabelle._
import java.net.http.{HttpRequest, HttpClient, HttpResponse}
import java.net.URI
import java.time.Duration

trait LLMProvider {
  def getProofSuggestion(
    preceding: String,
    proofSource: String,
    stateBefore: String,
    suggestedFacts: List[String],
    previousError: Option[(String, String)] = None
  ): String
}

class OpenAICompatibleProvider(baseUrl: String, modelName: String, apiKey: String) extends LLMProvider {
  override def getProofSuggestion(
    preceding: String,
    proofSource: String,
    stateBefore: String,
    suggestedFacts: List[String],
    previousError: Option[(String, String)] = None
  ): String = {
    val factsStr = if (suggestedFacts.isEmpty) "" else "\nRelevant Facts:\n" + suggestedFacts.map("- " + _).mkString("\n")

    val errorFeedback = previousError match {
      case Some((suggestion, err)) =>
        s"""

Previous attempt (failed):
  Suggestion: $suggestion
  Error: $err

Please correct the error and provide a working proof."""
      case None => ""
    }

    val systemPrompt = "You are an expert Isabelle/HOL proof assistant. " +
      "Output a single proof attempt that closes the current goal. " +
      "The proof MUST consist of at most one 'by' invocation, optionally preceded by one or more 'using' or 'unfolding' clauses. " +
      "Valid forms: 'by <method>', 'using <facts> by <method>', 'unfolding <defs> by <method>', or combinations. " +
      "No 'apply', no 'proof ... qed', no 'have', no 'show', no sorries, no natural language. " +
      "Output only the proof line, nothing else.\n\n" +
      "Allowed methods (use these exact forms):\n" +
      "  auto                — by (auto [simp: <f>] [simp del: <f>] [dest: <f>] [intro: <f>] [elim: <f>] [split: <f>])\n" +
      "  simp                — by (simp [add: <f>] [del: <f>])\n" +
      "  force               — by (force [simp: <f>] [simp del: <f>] [dest: <f>] [intro: <f>] [elim: <f>] [split: <f>])\n" +
      "  blast               — by blast\n" +
      "  fastforce           — by (fastforce [simp: <f>] [simp del: <f>] [dest: <f>] [intro: <f>] [elim: <f>] [split: <f>])\n" +
      "  metis               — by (metis <facts>)\n" +
      "  rule                — by (rule <thm>)\n" +
      "  intro               — by (intro <thms>)\n" +
      "  elim                — by (elim <thms>)\n" +
      "  induction           — by (induct <var>) auto\n\n" +
      "Examples:\n" +
      "  by auto\n" +
      "  by (simp add: append_assoc)\n" +
      "  using assms by auto\n" +
      "  unfolding comp_def by (rule refl)"

    val userContent = s"""Preceding Theory Text:
$preceding

Current Lemma:
$proofSource

Goal State:
$stateBefore
$factsStr$errorFeedback"""

    // Construct standard OpenAI compatible chat completions payload
    val messages = JSON.Format(List(
      JSON.Object("role" -> "system", "content" -> systemPrompt),
      JSON.Object("role" -> "user", "content" -> userContent)
    ))

    val body =
      s"""{
         |  "model": ${JSON.Format(modelName)},
         |  "messages": $messages,
         |  "temperature": 0.2
         |}""".stripMargin

    val client = HttpClient.newBuilder()
      .connectTimeout(Duration.ofSeconds(10))
      .build()

    val cleanUrl = if (baseUrl.endsWith("/")) baseUrl.stripSuffix("/") else baseUrl
    Output.writeln("[LLM request] POST " + cleanUrl + "/chat/completions\n" + body)
    val requestBuilder = HttpRequest.newBuilder()
      .uri(URI.create(s"$cleanUrl/chat/completions"))
      .header("Content-Type", "application/json")
      .timeout(Duration.ofSeconds(60))
      .POST(HttpRequest.BodyPublishers.ofString(body))

    if (apiKey.nonEmpty) {
      requestBuilder.header("Authorization", s"Bearer $apiKey")
    }

    val request = requestBuilder.build()
    val response = client.send(request, HttpResponse.BodyHandlers.ofString())

    if (response.statusCode() != 200) {
      error(s"HTTP Error ${response.statusCode()}: ${response.body()}")
    }

    // Standard OpenAI JSON Parsing
    val obj = JSON.parse(response.body())
    val choices = JSON.array(obj, "choices").getOrElse(error("Missing 'choices' in OpenAI response"))
    val choice = choices.headOption.getOrElse(error("Empty 'choices' in OpenAI response"))
    val messageObj = JSON.value(choice, "message").getOrElse(error("Missing 'message' in choice"))
    val content = JSON.string(messageObj, "content").getOrElse(error("Missing 'content' in message"))
    
    content.trim
  }
}

class CustomAgentProvider(agentUrl: String) extends LLMProvider {
  override def getProofSuggestion(
    preceding: String,
    proofSource: String,
    stateBefore: String,
    suggestedFacts: List[String],
    previousError: Option[(String, String)] = None
  ): String = {
    val pairs = List(
      "preceding" -> preceding,
      "proof_source" -> proofSource,
      "state_before" -> stateBefore,
      "suggested_facts" -> suggestedFacts
    ) ++ previousError.map { case (sugg, err) =>
      List("previous_suggestion" -> sugg, "previous_error" -> err)
    }.getOrElse(Nil)

    val body = JSON.Format(JSON.Object(pairs: _*))

    val client = HttpClient.newBuilder()
      .connectTimeout(Duration.ofSeconds(10))
      .build()

    Output.writeln("[LLM request] POST " + agentUrl + "\n" + body)
    val request = HttpRequest.newBuilder()
      .uri(URI.create(agentUrl))
      .header("Content-Type", "application/json")
      .timeout(Duration.ofSeconds(60))
      .POST(HttpRequest.BodyPublishers.ofString(body))
      .build()

    val response = client.send(request, HttpResponse.BodyHandlers.ofString())

    if (response.statusCode() != 200) {
      error(s"Agent Error ${response.statusCode()}: ${response.body()}")
    }

    val obj = JSON.parse(response.body())
    JSON.string(obj, "suggestion").getOrElse(response.body().trim)
  }
}

class MockLLMProvider extends LLMProvider {
  override def getProofSuggestion(
    preceding: String,
    proofSource: String,
    stateBefore: String,
    suggestedFacts: List[String],
    previousError: Option[(String, String)] = None
  ): String = "by auto"
}
