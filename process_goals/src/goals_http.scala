/*  Title:      goals/src/goals_http.scala
    Author:     Maximilian Schaeffeler

Sample k proof candidates from an OpenAI-compatible chat-completions endpoint
(any server speaking /v1/chat/completions: the bundled serve/serve_openai.py,
vLLM, llama.cpp, or a hosted API).
*/

package isabelle.goals

import isabelle._

import java.net.URI
import java.net.http.{HttpClient, HttpRequest, HttpResponse}
import java.time.Duration


object LLM {
  private def post(url: String, body: String, timeout: Time, api_key: Option[String]): HttpResponse[String] = {
    val builder = HttpRequest.newBuilder(URI.create(url).nn).nn
    builder.timeout(Duration.ofMillis(timeout.ms).nn)
    builder.header("Content-Type", "application/json")
    api_key.foreach(key => builder.header("Authorization", "Bearer " + key))
    builder.POST(HttpRequest.BodyPublishers.ofString(body).nn)
    HttpClient.newHttpClient().nn.send(builder.build().nn, HttpResponse.BodyHandlers.ofString()).nn
  }

  // one user turn with the rendered prompt; n = k samples; choices -> candidate proofs.
  // transient failures (timeout, 5xx server load/OOM) are retried a few times
  def generate(url: String, model: String, prompt: String, k: Int, temperature: Double,
    timeout: Time, retries: Int = 2, api_key: Option[String] = None, max_tokens: Int = 64): List[String] = {
    val body =
      JSON.Format(JSON.Object(
        "model" -> model,
        "messages" -> List(JSON.Object("role" -> "user", "content" -> prompt)),
        "n" -> k, "temperature" -> temperature, "max_tokens" -> max_tokens))
    def attempt(left: Int): List[String] =
      Exn.capture(post(url, body, timeout, api_key)) match {
        case Exn.Res(response) if response.statusCode() == 200 =>
          val json = JSON.parse(response.body().nn)
          JSON.array(json, "choices").getOrElse(Nil)
            .flatMap(choice => JSON.value(choice, "message").flatMap(JSON.string(_, "content")))
        case Exn.Res(response) if response.statusCode() < 500 || left == 0 =>
          error("LLM server " + quote(url) + " returned HTTP " + response.statusCode() + ": " + response.body())
        case Exn.Exn(exn) if left == 0 => throw exn
        case _ => attempt(left - 1)  // transient: timeout or 5xx
      }
    attempt(retries)
  }
}
