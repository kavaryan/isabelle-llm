#!/usr/bin/env python3
import argparse
import inspect
import json
import os
from contextlib import nullcontext
from pathlib import Path

import torch
from peft import LoraConfig, PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer
from trl import SFTConfig, SFTTrainer

from sft_chat_stats import apply_chat_template_to_prompt_completion_dataset, load_sft_split


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fine-tune a causal LM with TRL SFTTrainer.")
    parser.add_argument("--model", required=True, help="Base model path or Hugging Face model ID.")
    parser.add_argument("--dataset", required=True, help="Dataset path or Hugging Face dataset ID.")
    parser.add_argument("--dataset-config", default="", help="Optional dataset config/subset.")
    parser.add_argument("--split", default="train", help="Dataset split.")
    parser.add_argument("--eval-split", default="", help="Optional eval split for trainer eval_loss logging.")
    parser.add_argument("--max-eval-samples", type=int, default=-1, help="Maximum examples for trainer eval_loss.")
    parser.add_argument("--output-dir", required=True, help="Directory for trainer output.")
    parser.add_argument("--merged-output-dir", required=True, help="Directory for merged vLLM-ready checkpoint.")
    parser.add_argument("--max-train-samples", type=int, default=2, help="Maximum examples to train on.")
    parser.add_argument("--question-field", default="question", help="Question/instruction field.")
    parser.add_argument("--solution-field", default="solution", help="Solution/response field.")
    parser.add_argument("--answer-field", default="answer", help="Optional final-answer field.")
    parser.add_argument("--text-field", default="", help="Use an existing single text field instead of formatting fields.")
    parser.add_argument(
        "--completion-only-loss",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="For prompt/completion datasets, train only on completion tokens.",
    )
    parser.add_argument("--max-seq-length", type=int, default=3072)
    parser.add_argument("--epochs", type=float, default=1.0)
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    parser.add_argument("--per-device-train-batch-size", type=int, default=1)
    parser.add_argument("--per-device-eval-batch-size", type=int, default=1)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=1)
    parser.add_argument("--lora-r", type=int, default=16)
    parser.add_argument("--lora-alpha", type=int, default=32)
    parser.add_argument("--lora-dropout", type=float, default=0.05)
    parser.add_argument("--full-finetune", action="store_true", help="Disable LoRA and train all weights.")
    parser.add_argument(
        "--baseline-eval-before-train",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Evaluate the raw base model on train/eval splits before training and log to the same run.",
    )
    parser.add_argument("--bf16", action="store_true")
    parser.add_argument("--fp16", action="store_true")
    parser.add_argument("--report-to", default=os.environ.get("REPORT_TO", "none"))
    parser.add_argument("--run-name", default=os.environ.get("WANDB_RUN_NAME", ""))
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def load_train_dataset(args: argparse.Namespace):
    return load_sft_split(
        args.dataset,
        args.dataset_config,
        args.split,
        limit=args.max_train_samples,
        question_field=args.question_field,
        solution_field=args.solution_field,
        answer_field=args.answer_field,
        text_field=args.text_field,
    )


def load_eval_dataset(args: argparse.Namespace):
    if not args.eval_split:
        return None, False
    return load_sft_split(
        args.dataset,
        args.dataset_config,
        args.eval_split,
        limit=args.max_eval_samples,
        question_field=args.question_field,
        solution_field=args.solution_field,
        answer_field=args.answer_field,
        text_field=args.text_field,
    )


def save_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def make_sft_config(**kwargs) -> SFTConfig:
    supported = inspect.signature(SFTConfig).parameters
    filtered = {key: value for key, value in kwargs.items() if key in supported}
    dropped = sorted(set(kwargs) - set(filtered))
    if dropped:
        print(f"Warning: installed TRL SFTConfig does not support {dropped}; ignoring them", flush=True)
    return SFTConfig(**filtered)


def disabled_adapter_context(model):
    if isinstance(model, PeftModel) and hasattr(model, "disable_adapter"):
        return model.disable_adapter()
    return nullcontext()


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir).expanduser()
    merged_output_dir = Path(args.merged_output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    merged_output_dir.mkdir(parents=True, exist_ok=True)

    train_dataset, uses_prompt_completion = load_train_dataset(args)
    eval_dataset, eval_uses_prompt_completion = load_eval_dataset(args)
    if eval_dataset is not None and eval_uses_prompt_completion != uses_prompt_completion:
        raise ValueError("train and eval splits must use the same formatting mode")
    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    if uses_prompt_completion:
        train_dataset, _ = apply_chat_template_to_prompt_completion_dataset(
            train_dataset, tokenizer, args.max_seq_length, args.split
        )
        if eval_dataset is not None:
            eval_dataset, _ = apply_chat_template_to_prompt_completion_dataset(
                eval_dataset, tokenizer, args.max_seq_length, args.eval_split
            )

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

    training_args = make_sft_config(
        output_dir=str(output_dir),
        dataset_text_field=args.text_field or "text",
        completion_only_loss=args.completion_only_loss if uses_prompt_completion else None,
        max_length=args.max_seq_length,
        packing=False,
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.per_device_train_batch_size,
        per_device_eval_batch_size=args.per_device_eval_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        learning_rate=args.learning_rate,
        lr_scheduler_type="cosine",
        warmup_ratio=0.0,
        logging_steps=1,
        eval_strategy="epoch" if eval_dataset is not None else "no",
        evaluation_strategy="epoch" if eval_dataset is not None else "no",
        save_strategy="no",
        report_to=args.report_to,
        run_name=args.run_name or None,
        bf16=args.bf16,
        fp16=args.fp16,
        gradient_checkpointing=True,
        remove_unused_columns=False,
        seed=args.seed,
    )

    trainer = SFTTrainer(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        processing_class=tokenizer,
        peft_config=peft_config,
    )

    baseline_metrics: dict[str, dict[str, float]] = {}
    if args.baseline_eval_before_train:
        print("Running baseline evaluation before training", flush=True)
        with disabled_adapter_context(trainer.model):
            baseline_train_metrics = trainer.evaluate(
                eval_dataset=trainer.train_dataset,
                metric_key_prefix="base_train",
            )
            baseline_metrics["train"] = baseline_train_metrics
            print(f"BASELINE train {json.dumps(baseline_train_metrics, sort_keys=True)}", flush=True)
            if eval_dataset is not None:
                baseline_eval_metrics = trainer.evaluate(
                    eval_dataset=trainer.eval_dataset,
                    metric_key_prefix="base_eval",
                )
                baseline_metrics["eval"] = baseline_eval_metrics
                print(f"BASELINE eval {json.dumps(baseline_eval_metrics, sort_keys=True)}", flush=True)

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
        merged_output_dir / "training_summary.json",
        {
            "base_model": args.model,
            "dataset": args.dataset,
            "dataset_config": args.dataset_config,
            "split": args.split,
            "eval_split": args.eval_split,
            "num_train_examples": len(train_dataset),
            "num_eval_examples": len(eval_dataset) if eval_dataset is not None else 0,
            "baseline_eval_before_train": args.baseline_eval_before_train,
            "baseline_metrics": baseline_metrics,
            "full_finetune": args.full_finetune,
            "trainer_output_dir": str(output_dir),
            "merged_output_dir": str(merged_output_dir),
        },
    )
    print(f"Saved trainer output to {output_dir}", flush=True)
    print(f"Saved merged vLLM-ready checkpoint to {merged_output_dir}", flush=True)


if __name__ == "__main__":
    main()
