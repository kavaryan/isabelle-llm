# LLM Suggestions Plugin for Isabelle/jEdit

This directory contains an Isabelle/jEdit IDE plugin that adds a panel to suggest real-time tactics and proofs using local or remote LLM backends.

## Features

*   **Interactive Panel**: Query LLMs directly from within the Isabelle/jEdit editor.
*   **Multiple LLM Backends**: Supports local OpenAI-compatible endpoints (e.g., Ollama, `llama.cpp`), custom HTTP agents, or mock providers for testing.
*   **Context Extraction**: Dynamically reads the current proof state and queries MePo (Isabelle's relevance filter) for surrounding facts to feed into the prompt context.
*   **On-the-fly Verification**: The plugin can run the LLM's suggestion through Isabelle's compilation pipeline to verify its correctness before presenting it.
*   **Auto-Feedback Loop**: If verification fails, the plugin can automatically feed the error message back to the LLM and request a corrected proof.

## Installation

To load the plugin in Isabelle/jEdit:

```bash
# Register the plugin as an Isabelle component
isabelle components -u /path/to/isabelle-llm/jedit-plugin

# Recompile the Scala code
isabelle scala_build
```

Start Isabelle/jEdit. Open the panel by selecting **Plugins** -> **LLM Suggestions** or opening the **LLM Suggestions** dockable.

## Configuration & Options

The control bar at the top of the panel supports the following options:

*   **Provider**: Choose between "Local / OpenAI Compatible", "Custom HTTP Agent", or "Mock / Test Provider".
*   **URL**: The endpoint of your LLM provider (default: `http://localhost:11434/v1`).
*   **Model**: Model name (e.g., `llama3`).
*   **Key**: API token (if required).
*   **Max Facts**: Capped number of relevance-filtered facts to include in the context.
*   **Verify**: Check this to try the tactic in Isabelle before displaying. If it fails, the plugin automatically retries with error feedback.

## Implementation Details

*   [dockables.xml](dockables.xml) — Registers the panel as a dockable jEdit window.
*   [plugin.props](plugin.props) — Plugin properties and metadata.
*   [llm_verify.ML](llm_verify.ML) — Query operation registering `llm_context` and `llm_verify` on Isabelle's ML side to export proof states and evaluate suggestions dynamically.
*   [src/](src/) — Scala sources managing API requests, UI state, swing components, and PIDE interactions.
