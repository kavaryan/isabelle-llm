---
description: Pure one-shot text completion, no tool use at all -- used by process_goals' oneshot_adapter.sh for phase-2 proof attempts.
mode: primary
tools:
  bash: false
  edit: false
  write: false
  read: false
  glob: false
  grep: false
  webfetch: false
  websearch: false
  task: false
  todowrite: false
  lsp: false
  skill: false
---

Reply with only the requested content. Do not use tools -- you have none available. Reason only from the text in the user's message.
