#!/usr/bin/env python3
"""Reward helpers for Isabelle verifier-guided GRPO."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def completion_to_text(completion: Any) -> str:
    if isinstance(completion, str):
        return completion.strip()
    if isinstance(completion, list):
        parts = []
        for item in completion:
            parts.append(str(item.get("content", "")) if isinstance(item, dict) else str(item))
        return "".join(parts).strip()
    return str(completion).strip()


@dataclass(frozen=True)
class RewardConfig:
    checker: Path
    timeout_seconds: float
    success_reward: float
    failure_reward: float
    timeout_reward: float
    stderr_chars: int

    @classmethod
    def from_env(cls) -> "RewardConfig":
        checker = Path(os.environ["ISABELLE_REWARD_CHECKER"]).expanduser()
        return cls(
            checker=checker,
            timeout_seconds=float(os.environ.get("ISABELLE_REWARD_TIMEOUT", "60")),
            success_reward=float(os.environ.get("ISABELLE_SUCCESS_REWARD", "1.0")),
            failure_reward=float(os.environ.get("ISABELLE_FAILURE_REWARD", "0.0")),
            timeout_reward=float(os.environ.get("ISABELLE_TIMEOUT_REWARD", "0.0")),
            stderr_chars=int(os.environ.get("ISABELLE_REWARD_STDERR_CHARS", "1200")),
        )


def reward_record(prompt: str, completion: str, metadata: dict[str, Any], config: RewardConfig) -> float:
    payload = dict(metadata)
    payload["prompt"] = prompt
    payload["completion"] = completion
    try:
        result = subprocess.run(
            [sys.executable, str(config.checker)],
            input=json.dumps(payload, ensure_ascii=False),
            text=True,
            timeout=config.timeout_seconds,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return config.timeout_reward

    if result.returncode == 0:
        return config.success_reward

    if config.stderr_chars > 0 and result.stderr:
        print(
            "Isabelle reward failed for "
            f"{metadata.get('theory', '')}:{metadata.get('line', '')}: "
            f"{result.stderr[-config.stderr_chars:]}",
            flush=True,
        )
    return config.failure_reward


def make_isabelle_reward_func(max_workers: int = 1):
    config = RewardConfig.from_env()
    if not config.checker.is_file():
        raise FileNotFoundError(f"Isabelle reward checker does not exist: {config.checker}")

    def reward_func(prompts, completions, **kwargs):
        prompt_texts = [completion_to_text(prompt) for prompt in prompts]
        completion_texts = [completion_to_text(completion) for completion in completions]
        count = len(completion_texts)
        metadata_rows: list[dict[str, Any]] = []
        for index in range(count):
            metadata = {}
            for key, values in kwargs.items():
                if key in {"prompts", "completions", "completion_ids"}:
                    continue
                if isinstance(values, list) and len(values) == count:
                    metadata[key] = values[index]
            metadata_rows.append(metadata)

        if max_workers <= 1:
            return [
                reward_record(prompt, completion, metadata, config)
                for prompt, completion, metadata in zip(prompt_texts, completion_texts, metadata_rows)
            ]

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            return list(
                executor.map(
                    lambda item: reward_record(item[0], item[1], item[2], config),
                    zip(prompt_texts, completion_texts, metadata_rows),
                )
            )

    return reward_func

