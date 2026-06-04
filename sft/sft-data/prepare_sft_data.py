#!/usr/bin/env python3
"""Build Isabelle proof SFT JSONL splits from extractor output."""

from __future__ import annotations

import argparse
import importlib.util
import json
import random
from pathlib import Path
from typing import Any

from jinja2 import Environment, StrictUndefined


DEFAULT_SEED = 42
DEFAULT_MAX_SEQ_LENGTH = 3072
DEFAULT_CHARS_PER_TOKEN = 3.5
SMOKE_TRAIN_EXAMPLES = 10
SMOKE_TEST_EXAMPLES = 2


def repo_relative(path: str) -> Path:
    return Path(__file__).resolve().parents[2] / path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply the Isabelle proof prompt Jinja template and create reproducible train/test splits."
    )
    parser.add_argument(
        "--input-dir",
        type=Path,
        default=repo_relative("extractor/proof_extractor_out/json"),
        help="Directory containing extractor JSON files.",
    )
    parser.add_argument(
        "--template",
        type=Path,
        default=repo_relative("sft/prompt_jinja2_template.py"),
        help="Python template file defining PROMPT_TEMPLATE and COMPLETION_TEMPLATE.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Directory where train/test JSONL files and metadata are written.",
    )
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help="Fixed shuffle seed.")
    parser.add_argument("--test-ratio", type=float, default=0.2, help="Fraction of examples for the test split.")
    parser.add_argument(
        "--smoke-test",
        action="store_true",
        help="Write a tiny deterministic split with 10 train examples and 2 test examples.",
    )

    parser.add_argument(
        "--include-non-leaf",
        action="store_true",
        help="Include non-leaf proof blocks. By default only leaf one-liner proof blocks are used.",
    )
    parser.add_argument(
        "--max-seq-length",
        type=int,
        default=DEFAULT_MAX_SEQ_LENGTH,
        help="Target maximum sequence length used to truncate proof_text_before.",
    )
    parser.add_argument(
        "--chars-per-token",
        type=float,
        default=DEFAULT_CHARS_PER_TOKEN,
        help="Conservative character/token estimate for template-time truncation.",
    )
    return parser.parse_args()


def normalize_suggested_facts(value: Any) -> str:
    if not value:
        return ""
    if isinstance(value, list):
        lines = []
        for fact in value:
            if isinstance(fact, dict):
                name = str(fact.get("name", "")).strip()
                statement = str(fact.get("statement", "")).strip()
                lines.append(f"{name}: {statement}" if statement else name)
            else:
                lines.append(str(fact).strip())
        return "\n".join(line for line in lines if line)
    return str(value).strip()


def load_template_pair(path: Path) -> tuple[str, str]:
    if path.suffix == ".py":
        spec = importlib.util.spec_from_file_location("isabelle_sft_template", path)
        if spec is None or spec.loader is None:
            raise ValueError(f"cannot import template module from {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        missing = [name for name in ("PROMPT_TEMPLATE", "COMPLETION_TEMPLATE") if not hasattr(module, name)]
        if missing:
            raise ValueError(f"{path} must define {', '.join(missing)}")
        return str(module.PROMPT_TEMPLATE), str(module.COMPLETION_TEMPLATE)
    return path.read_text(encoding="utf-8"), "{{ proof_block }}"


def load_records(input_dir: Path, include_non_leaf: bool) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in sorted(input_dir.glob("*.json")):
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, list):
            raise ValueError(f"{path} must contain a JSON list")
        for index, record in enumerate(payload):
            if not isinstance(record, dict):
                raise ValueError(f"{path}[{index}] must be a JSON object")
            if not include_non_leaf and not record.get("is_leaf", False):
                continue
            proof_block = str(record.get("proof_block", "")).strip()
            if not proof_block:
                continue
            record = dict(record)
            record["_source_file"] = path.name
            record["_source_index"] = index
            records.append(record)
    return records


def estimate_tokens(text: str, chars_per_token: float) -> int:
    return int(len(text) / chars_per_token) + 1


def trim_from_start(text: str, chars_to_remove: int) -> str:
    if chars_to_remove <= 0:
        return text
    trimmed = text[min(chars_to_remove, max(0, len(text) - 1)) :]
    newline = trimmed.find("\n")
    if newline != -1 and newline + 1 < len(trimmed):
        trimmed = trimmed[newline + 1 :]
    return "[... truncated proof context ...]\n" + trimmed.lstrip()


def build_example_text(
    record: dict[str, Any],
    prompt_template: Any,
    completion_template: Any,
    max_seq_length: int,
    chars_per_token: float,
) -> tuple[str, str, bool]:
    context = dict(record)
    context["suggested_facts"] = normalize_suggested_facts(record.get("suggested_facts"))

    prompt = prompt_template.render(**context).rstrip()
    completion = completion_template.render(**context).strip()
    if estimate_tokens(f"{prompt}\n{completion}", chars_per_token) <= max_seq_length:
        return prompt, completion, False

    proof_text_before = str(context.get("proof_text_before", ""))
    overflow_tokens = estimate_tokens(f"{prompt}\n{completion}", chars_per_token) - max_seq_length
    chars_to_remove = int(overflow_tokens * chars_per_token) + 256
    while proof_text_before and estimate_tokens(f"{prompt}\n{completion}", chars_per_token) > max_seq_length:
        proof_text_before = trim_from_start(proof_text_before, chars_to_remove)
        context["proof_text_before"] = proof_text_before
        prompt = prompt_template.render(**context).rstrip()
        chars_to_remove *= 2

    return prompt, completion, True


def render_examples(
    records: list[dict[str, Any]],
    prompt_template_text: str,
    completion_template_text: str,
    max_seq_length: int,
    chars_per_token: float,
) -> list[dict[str, Any]]:
    env = Environment(undefined=StrictUndefined, autoescape=False, keep_trailing_newline=True)
    prompt_template = env.from_string(prompt_template_text)
    completion_template = env.from_string(completion_template_text)
    examples = []
    for record in records:
        prompt, completion, truncated = build_example_text(
            record, prompt_template, completion_template, max_seq_length, chars_per_token
        )
        examples.append(
            {
                "text": f"{prompt}\n{completion}",
                "prompt": prompt,
                "completion": completion,
                "raw_prompt": prompt,
                "raw_completion": completion,
                "proof_text_before_truncated": truncated,
                "theory": record.get("theory", ""),
                "line": record.get("line"),
                "offset": record.get("offset"),
                "source_file": record["_source_file"],
                "source_index": record["_source_index"],
            }
        )
    return examples


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            json.dump(row, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")


def main() -> None:
    args = parse_args()
    if not args.smoke_test and not 0 < args.test_ratio < 1:
        raise ValueError("--test-ratio must be between 0 and 1")

    records = load_records(args.input_dir, args.include_non_leaf)
    if not records:
        raise ValueError(f"no usable records found in {args.input_dir}")

    prompt_template_text, completion_template_text = load_template_pair(args.template)
    examples = render_examples(
        records, prompt_template_text, completion_template_text, args.max_seq_length, args.chars_per_token
    )
    random.Random(args.seed).shuffle(examples)

    if args.smoke_test:
        smoke_count = SMOKE_TRAIN_EXAMPLES + SMOKE_TEST_EXAMPLES
        if len(examples) < smoke_count:
            raise ValueError(f"smoke test requires at least {smoke_count} examples; found {len(examples)}")
        test = examples[:SMOKE_TEST_EXAMPLES]
        train = examples[SMOKE_TEST_EXAMPLES:smoke_count]
    else:
        test_count = round(len(examples) * args.test_ratio)
        test = examples[:test_count]
        train = examples[test_count:]

    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_jsonl(args.output_dir / "train.jsonl", train)
    write_jsonl(args.output_dir / "test.jsonl", test)
    (args.output_dir / "dataset_info.json").write_text(
        json.dumps(
            {
                "seed": args.seed,
                "test_ratio": args.test_ratio,
                "smoke_test": args.smoke_test,
                "num_examples": len(examples),
                "num_train_examples": len(train),
                "num_test_examples": len(test),
                "input_dir": str(args.input_dir),
                "template": str(args.template),
                "format": "jsonl",
                "max_seq_length": args.max_seq_length,
                "chars_per_token": args.chars_per_token,
                "num_truncated_examples": sum(1 for example in examples if example["proof_text_before_truncated"]),
                "text_field": "text",
                "prompt_field": "prompt",
                "completion_field": "completion",
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    print(f"Wrote {len(train)} train examples to {args.output_dir / 'train.jsonl'}")
    print(f"Wrote {len(test)} test examples to {args.output_dir / 'test.jsonl'}")


if __name__ == "__main__":
    main()
