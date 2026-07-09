/*  Title:      goals/src/goals_hash.scala

Content hashing shared by the discover/oneshot/check/repair pipeline, so each
phase can verify it is still looking at the same theory source the previous
phase saw.
*/

package isabelle.goals

import isabelle._


object Goals_Hash {
  def sha256(text: String): String = {
    val digest = java.security.MessageDigest.getInstance("SHA-256").nn
    val bytes = digest.digest(text.getBytes("UTF-8")).nn
    bytes.map(b => f"${b & 0xff}%02x").mkString
  }
}
