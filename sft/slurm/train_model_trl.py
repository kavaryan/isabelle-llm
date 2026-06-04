#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path

import torch
from datasets import load_dataset
from peft import LoraConfig, PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer
from trl import SFTConfig, SFTTrainer


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fine-tune a causal LM with TRL SFTTrainer.")
    parser.add_argument("--model", required=True, help="Base model path or Hugging Face model ID.")
    parser.add_argument("--dataset", required=True, help="Dataset path or Hugging Face dataset ID.")
    parser.add_argument("--dataset-config", default="", help="Optional dataset config/subset.")
    parser.add_argument("--split", default="train", help="Dataset split.")
    parser.add_argument("--output-dir", required=True, help="Directory for trainer output.")
    parser.add_argument("--merged-output-dir", required=True, help="Directory for merged vLLM-ready checkpoint.")
    parser.add_argument("--max-train-samples", type=int, default=2, help="Maximum examples to train on.")
    parser.add_argument("--question-field", default="question", help="Question/instruction field.")
    parser.add_argument("--solution-field", default="solution", help="Solution/response field.")
    parser.add_argument("--answer-field", default="answer", help="Optional final-answer field.")
    parser.add_argument("--text-field", default="", help="Use an existing single text field instead of formatting fields.")
    parser.add_argument("--max-seq-length", type=int, default=2048)
    parser.add_argument("--epochs", type=float, default=1.0)
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    parser.add_argument("--per-device-train-batch-size", type=int, default=1)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=1)
    parser.add_argument("--lora-r", type=int, default=16)
    parser.add_argument("--lora-alpha", type=int, default=32)
    parser.add_argument("--lora-dropout", type=float, default=0.05)
    parser.add_argument("--full-finetune", action="store_true", help="Disable LoRA and train all weights.")
    parser.add_argument("--bf16", action="store_true")
    parser.add_argument("--fp16", action="store_true")
    parser.add_argument("--report-to", default=os.environ.get("REPORT_TO", "none"))
    parser.add_argument("--run-name", default=os.environ.get("WANDB_RUN_NAME", ""))
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def load_train_dataset(args: argparse.Namespace):
    if args.dataset_config:
        dataset = load_dataset(args.dataset, args.dataset_config, split=args.split)
    else:
        dataset = load_dataset(args.dataset, split=args.split)

    if args.max_train_samples >= 0:
        dataset = dataset.select(range(min(args.max_train_samples, len(dataset))))

    if args.text_field:
        if args.text_field not in dataset.column_names:
            raise ValueError(f"text field {args.text_field!r} not present in dataset columns {dataset.column_names}")
        return dataset

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

    return dataset.map(format_example, remove_columns=dataset.column_names)


def save_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir).expanduser()
    merged_output_dir = Path(args.merged_output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    merged_output_dir.mkdir(parents=True, exist_ok=True)

    train_dataset = load_train_dataset(args)
    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

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

    training_args = SFTConfig(
        output_dir=str(output_dir),
        dataset_text_field=args.text_field or "text",
        max_length=args.max_seq_length,
        packing=False,
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.per_device_train_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        learning_rate=args.learning_rate,
        lr_scheduler_type="cosine",
        warmup_ratio=0.0,
        logging_steps=1,
        save_strategy="no",
        report_to=args.report_to,
        run_name=args.run_name or None,
        bf16=args.bf16,
        fp16=args.fp16,
        gradient_checkpointing=True,
        remove_unused_columns=True,
        seed=args.seed,
    )

    trainer = SFTTrainer(
        model=model,
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
        merged_output_dir / "training_summary.json",
        {
            "base_model": args.model,
            "dataset": args.dataset,
            "dataset_config": args.dataset_config,
            "split": args.split,
            "num_train_examples": len(train_dataset),
            "full_finetune": args.full_finetune,
            "trainer_output_dir": str(output_dir),
            "merged_output_dir": str(merged_output_dir),
        },
    )
    print(f"Saved trainer output to {output_dir}", flush=True)
    print(f"Saved merged vLLM-ready checkpoint to {merged_output_dir}", flush=True)


if __name__ == "__main__":
    main()
