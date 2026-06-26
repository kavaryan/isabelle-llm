#!/usr/bin/env python3
"""Train Qwen-style causal LMs with TRL GRPO and Isabelle verifier rewards."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import torch
from peft import LoraConfig, PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer
from trl import GRPOConfig, GRPOTrainer

from isabelle_reward import make_isabelle_reward_func
from sft_chat_stats import load_dataset_split, summarize_token_lengths


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verifier-guided GRPO with TRL.")
    parser.add_argument("--model", required=True, help="Base model path or Hugging Face model ID.")
    parser.add_argument("--dataset", required=True, help="Dataset path or Hugging Face dataset ID.")
    parser.add_argument("--dataset-config", default="", help="Optional dataset config/subset.")
    parser.add_argument("--split", default="train", help="Training split.")
    parser.add_argument("--output-dir", required=True, help="Directory for trainer output.")
    parser.add_argument("--merged-output-dir", required=True, help="Directory for merged vLLM-ready checkpoint.")
    parser.add_argument("--max-train-samples", type=int, default=-1)
    parser.add_argument("--max-prompt-length", type=int, default=3072)
    parser.add_argument("--max-completion-length", type=int, default=128)
    parser.add_argument("--max-steps", type=int, default=100)
    parser.add_argument("--epochs", type=float, default=1.0)
    parser.add_argument("--learning-rate", type=float, default=1e-6)
    parser.add_argument("--per-device-train-batch-size", type=int, default=1)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=1)
    parser.add_argument("--num-generations", type=int, default=4)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--beta", type=float, default=0.04)
    parser.add_argument("--scale-rewards", default="true", choices=["true", "false", "batch"])
    parser.add_argument("--reward-workers", type=int, default=1)
    parser.add_argument("--lora-r", type=int, default=16)
    parser.add_argument("--lora-alpha", type=int, default=32)
    parser.add_argument("--lora-dropout", type=float, default=0.05)
    parser.add_argument("--full-finetune", action="store_true")
    parser.add_argument("--bf16", action="store_true")
    parser.add_argument("--fp16", action="store_true")
    parser.add_argument("--report-to", default=os.environ.get("REPORT_TO", "none"))
    parser.add_argument("--run-name", default=os.environ.get("WANDB_RUN_NAME", ""))
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def load_grpo_dataset(args: argparse.Namespace, tokenizer):
    dataset = load_dataset_split(
        args.dataset,
        args.dataset_config,
        args.split,
    )
    if args.max_train_samples >= 0:
        dataset = dataset.select(range(min(args.max_train_samples, len(dataset))))
    if not {"prompt", "completion"}.issubset(dataset.column_names):
        raise ValueError("GRPO training expects prompt/completion JSONL columns so rewards can use proof metadata")

    def format_example(example):
        raw_prompt = str(example["prompt"]).strip()
        if tokenizer.chat_template is None:
            prompt = raw_prompt
        else:
            prompt = tokenizer.apply_chat_template(
                [{"role": "user", "content": raw_prompt}],
                tokenize=False,
                add_generation_prompt=True,
            )
        token_count = len(tokenizer(prompt, add_special_tokens=False)["input_ids"])
        return {"prompt": prompt, "gold_completion": str(example["completion"]).strip(), "token_count": token_count}

    dataset = dataset.map(format_example)
    lengths = [int(length) for length in dataset["token_count"]]
    summarize_token_lengths(lengths, args.max_prompt_length, args.split)
    dataset = dataset.filter(lambda example: int(example["token_count"]) <= args.max_prompt_length)
    if len(dataset) == 0:
        raise ValueError(f"{args.split} split has no examples within max_prompt_length={args.max_prompt_length}")
    return dataset.remove_columns(["token_count"])


def scale_rewards_value(value: str):
    if value == "true":
        return True
    if value == "false":
        return False
    return value


def save_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir).expanduser()
    merged_output_dir = Path(args.merged_output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    merged_output_dir.mkdir(parents=True, exist_ok=True)

    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "left"

    train_dataset = load_grpo_dataset(args, tokenizer)

    dtype = torch.bfloat16 if args.bf16 else torch.float16 if args.fp16 else "auto"
    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        torch_dtype=dtype,
        trust_remote_code=True,
        device_map=None,
    )
    model.config.use_cache = False

    peft_config = None
    if not args.full_finetune:
        peft_config = LoraConfig(
            r=args.lora_r,
            lora_alpha=args.lora_alpha,
            lora_dropout=args.lora_dropout,
            bias="none",
            task_type="CAUSAL_LM",
            target_modules="all-linear",
        )

    training_args = GRPOConfig(
        output_dir=str(output_dir),
        max_prompt_length=args.max_prompt_length,
        max_completion_length=args.max_completion_length,
        num_train_epochs=args.epochs,
        max_steps=args.max_steps,
        per_device_train_batch_size=args.per_device_train_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        num_generations=args.num_generations,
        temperature=args.temperature,
        top_p=args.top_p,
        beta=args.beta,
        scale_rewards=scale_rewards_value(args.scale_rewards),
        learning_rate=args.learning_rate,
        lr_scheduler_type="cosine",
        warmup_ratio=0.0,
        logging_steps=1,
        save_strategy="steps",
        save_steps=max(10, args.max_steps),
        report_to=args.report_to,
        run_name=args.run_name or None,
        bf16=args.bf16,
        fp16=args.fp16,
        gradient_checkpointing=True,
        remove_unused_columns=False,
        seed=args.seed,
    )

    trainer = GRPOTrainer(
        model=model,
        reward_funcs=make_isabelle_reward_func(args.reward_workers),
        args=training_args,
        train_dataset=train_dataset,
        processing_class=tokenizer,
        peft_config=peft_config,
    )
    trainer.train()
    trainer.save_model(str(output_dir))
    tokenizer.save_pretrained(str(output_dir))

    if peft_config is None:
        trainer.model.save_pretrained(str(merged_output_dir), safe_serialization=True)
        tokenizer.save_pretrained(str(merged_output_dir))
    else:
        del trainer
        del model
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        base_model = AutoModelForCausalLM.from_pretrained(
            args.model,
            torch_dtype=dtype,
            trust_remote_code=True,
            device_map="cpu",
        )
        merged_model = PeftModel.from_pretrained(base_model, str(output_dir))
        merged_model = merged_model.merge_and_unload()
        merged_model.save_pretrained(str(merged_output_dir), safe_serialization=True)
        tokenizer.save_pretrained(str(merged_output_dir))

    save_json(
        merged_output_dir / "grpo_training_summary.json",
        {
            "base_model": args.model,
            "dataset": args.dataset,
            "split": args.split,
            "num_train_examples": len(train_dataset),
            "trainer_output_dir": str(output_dir),
            "merged_output_dir": str(merged_output_dir),
            "full_finetune": args.full_finetune,
            "max_steps": args.max_steps,
            "num_generations": args.num_generations,
            "reward_checker": os.environ.get("ISABELLE_REWARD_CHECKER", ""),
        },
    )
    print(f"Saved trainer output to {output_dir}", flush=True)
    print(f"Saved merged vLLM-ready checkpoint to {merged_output_dir}", flush=True)


if __name__ == "__main__":
    main()
