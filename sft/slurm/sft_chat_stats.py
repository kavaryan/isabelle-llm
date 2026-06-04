#!/usr/bin/env python3
import argparse
import math
from pathlib import Path
from types import SimpleNamespace

from datasets import load_dataset
from transformers import AutoTokenizer


def load_dataset_split(dataset_id: str, dataset_config: str, split: str):
    dataset_path = Path(dataset_id).expanduser()
    if dataset_path.exists():
        if dataset_config:
            raise ValueError("--dataset-config is only supported for Hugging Face datasets, not local files")
        if dataset_path.is_dir():
            split_path = dataset_path / f"{split}.jsonl"
            if not split_path.exists():
                split_path = dataset_path / f"{split}.json"
            if not split_path.exists():
                raise FileNotFoundError(
                    f"local dataset directory {dataset_path} does not contain {split}.jsonl or {split}.json"
                )
            return load_dataset("json", data_files={split: str(split_path)}, split=split)
        return load_dataset("json", data_files={split: str(dataset_path)}, split=split)
    if dataset_config:
        return load_dataset(dataset_id, dataset_config, split=split)
    return load_dataset(dataset_id, split=split)


def normalize_dataset_columns(dataset, args):
    if args.text_field:
        if args.text_field not in dataset.column_names:
            raise ValueError(f"text field {args.text_field!r} not present in dataset columns {dataset.column_names}")
        return dataset, False
    if {"prompt", "completion"}.issubset(dataset.column_names):
        extra_columns = [column for column in dataset.column_names if column not in {"prompt", "completion"}]
        if extra_columns:
            dataset = dataset.remove_columns(extra_columns)
        return dataset, True
    if "text" in dataset.column_names:
        return dataset, False

    required = [args.question_field, args.solution_field]
    missing = [field for field in required if field not in dataset.column_names]
    if missing:
        raise ValueError(f"missing dataset fields {missing}; available columns: {dataset.column_names}")

    def format_example(example):
        question = str(example[args.question_field]).strip()
        solution = str(example[args.solution_field]).strip()
        answer = str(example.get(args.answer_field, "")).strip() if args.answer_field else ""
        if answer and answer not in solution[-200:]:
            solution = f"{solution}\n\nFinal answer: {answer}"
        return {"text": f"Question:\n{question}\n\nAnswer:\n{solution}"}

    return dataset.map(format_example, remove_columns=dataset.column_names), False


def load_sft_split(
    dataset_id: str,
    dataset_config: str,
    split: str,
    *,
    limit: int = -1,
    question_field: str = "question",
    solution_field: str = "solution",
    answer_field: str = "answer",
    text_field: str = "",
):
    args = SimpleNamespace(
        question_field=question_field,
        solution_field=solution_field,
        answer_field=answer_field,
        text_field=text_field,
    )
    dataset = load_dataset_split(dataset_id, dataset_config, split)
    if limit >= 0:
        dataset = dataset.select(range(min(limit, len(dataset))))
    return normalize_dataset_columns(dataset, args)


def format_chat_parts(tokenizer, prompt: str, completion: str) -> tuple[str, str]:
    prompt_messages = [{"role": "user", "content": prompt}]
    full_messages = [*prompt_messages, {"role": "assistant", "content": completion}]
    prompt_part = tokenizer.apply_chat_template(prompt_messages, tokenize=False, add_generation_prompt=True)
    full_text = tokenizer.apply_chat_template(full_messages, tokenize=False, add_generation_prompt=False)
    if not full_text.startswith(prompt_part):
        raise ValueError("tokenizer chat template did not produce a prompt prefix of the full conversation")
    return prompt_part, full_text[len(prompt_part) :]


def summarize_token_lengths(lengths: list[int], max_seq_length: int, split_name: str) -> dict[str, float | int]:
    if not lengths:
        summary = {"count": 0}
        print(f"{split_name} token stats after chat template: count=0", flush=True)
        return summary

    sorted_lengths = sorted(lengths)

    def percentile(q: float) -> int:
        index = math.ceil(q * len(sorted_lengths)) - 1
        return sorted_lengths[max(0, min(index, len(sorted_lengths) - 1))]

    mean = sum(lengths) / len(lengths)
    variance = sum((length - mean) ** 2 for length in lengths) / len(lengths)
    below = sum(1 for length in lengths if length <= max_seq_length)
    summary = {
        "count": len(lengths),
        "mean": mean,
        "std": math.sqrt(variance),
        "min": sorted_lengths[0],
        "q1": percentile(0.25),
        "median": percentile(0.50),
        "q3": percentile(0.75),
        "max": sorted_lengths[-1],
        "at_or_below_max_seq_length": below,
        "above_max_seq_length": len(lengths) - below,
        "max_seq_length": max_seq_length,
    }
    print(
        (
            f"{split_name} token stats after chat template: count={summary['count']} "
            f"mean={summary['mean']:.2f} std={summary['std']:.2f} min={summary['min']} "
            f"q1={summary['q1']} median={summary['median']} q3={summary['q3']} "
            f"max={summary['max']} <=max_seq_length({max_seq_length})={below} "
            f">{max_seq_length}={len(lengths) - below}"
        ),
        flush=True,
    )
    return summary


def apply_chat_template_to_prompt_completion_dataset(
    dataset,
    tokenizer,
    max_seq_length: int,
    split_name: str,
    *,
    filter_over_length: bool = True,
):
    if tokenizer.chat_template is None:
        raise ValueError("prompt/completion datasets require a tokenizer with a chat_template")

    def format_example(example):
        prompt, completion = format_chat_parts(
            tokenizer,
            str(example["prompt"]).strip(),
            str(example["completion"]).strip(),
        )
        token_count = len(tokenizer(f"{prompt}{completion}", add_special_tokens=False)["input_ids"])
        return {"prompt": prompt, "completion": completion, "token_count": token_count}

    dataset = dataset.map(format_example)
    lengths = [int(length) for length in dataset["token_count"]]
    summary = summarize_token_lengths(lengths, max_seq_length, split_name)
    if filter_over_length:
        dataset = dataset.filter(lambda example: int(example["token_count"]) <= max_seq_length)
        if len(dataset) == 0:
            raise ValueError(f"{split_name} split has no examples within max_seq_length={max_seq_length}")
        print(f"{split_name} split kept {len(dataset)} examples after max_seq_length filtering", flush=True)
    return dataset.remove_columns(["token_count"]), summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Print token statistics after applying a model chat template to SFT splits."
    )
    parser.add_argument("--model", required=True, help="Model path or Hugging Face model ID.")
    parser.add_argument("--dataset", required=True, help="Dataset path or Hugging Face dataset ID.")
    parser.add_argument("--dataset-config", default="", help="Optional dataset config/subset.")
    parser.add_argument("--splits", nargs="+", default=["train", "test"], help="Splits to inspect.")
    parser.add_argument("--max-seq-length", type=int, default=3072)
    parser.add_argument("--question-field", default="question")
    parser.add_argument("--solution-field", default="solution")
    parser.add_argument("--answer-field", default="answer")
    parser.add_argument("--text-field", default="")
    parser.add_argument(
        "--smoke-test",
        action="store_true",
        help="Inspect only 10 train and 2 test examples, matching the smoke finetune split.",
    )
    parser.add_argument(
        "--filter-over-length",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Also filter and print kept counts. Disable to only print stats.",
    )
    return parser.parse_args()


def smoke_limit(split: str) -> int:
    if split == "train":
        return 10
    if split == "test":
        return 2
    return -1


def main() -> None:
    args = parse_args()
    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    for split in args.splits:
        limit = smoke_limit(split) if args.smoke_test else -1
        dataset, uses_prompt_completion = load_sft_split(
            args.dataset,
            args.dataset_config,
            split,
            limit=limit,
            question_field=args.question_field,
            solution_field=args.solution_field,
            answer_field=args.answer_field,
            text_field=args.text_field,
        )
        print(f"{split} split raw examples: {len(dataset)}", flush=True)
        if not uses_prompt_completion:
            raise ValueError("token statistics after chat template require prompt/completion columns")
        apply_chat_template_to_prompt_completion_dataset(
            dataset,
            tokenizer,
            args.max_seq_length,
            split,
            filter_over_length=args.filter_over_length,
        )


if __name__ == "__main__":
    main()
