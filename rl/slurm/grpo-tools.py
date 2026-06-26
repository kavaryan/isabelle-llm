#!/usr/bin/env python3
"""Train a Qwen hotel-booking agent with GRPO and SQLite-backed tools."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
from pathlib import Path
from typing import Any

import torch
from datasets import Dataset
from peft import LoraConfig, PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer
from trl import GRPOConfig, GRPOTrainer


HOTELS = [
    (1, "Hilton Basel", "Basel", "Upscale", "2026-07-01", "2026-07-05", 0),
    (2, "Hyatt Regency Basel", "Basel", "Luxury", "2026-07-01", "2026-07-05", 0),
    (3, "Marriott Zurich", "Zurich", "Luxury", "2026-07-01", "2026-07-05", 0),
    (4, "Hotel Schweizerhof Bern", "Bern", "Luxury", "2026-07-01", "2026-07-05", 0),
    (5, "Radisson Blu Lucerne", "Lucerne", "Upscale", "2026-07-01", "2026-07-05", 0),
    (6, "InterContinental Geneva", "Geneva", "Luxury", "2026-07-01", "2026-07-05", 0),
    (7, "Hotel Basel", "Basel", "Upper Midscale", "2026-07-01", "2026-07-05", 0),
    (8, "Novotel Zurich City West", "Zurich", "Upper Midscale", "2026-07-01", "2026-07-05", 0),
    (9, "ibis Bern Expo", "Bern", "Midscale", "2026-07-01", "2026-07-05", 0),
    (10, "Hotel des Alpes Lucerne", "Lucerne", "Midscale", "2026-07-01", "2026-07-05", 0),
]

SYSTEM_PROMPT = """You are a hotel booking assistant.
Use the available tools to search, book, update, or cancel reservations.
Never invent hotel IDs. Search first when the user identifies a hotel by name
or location. After using tools, give a short answer describing the result."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="Qwen/Qwen3-0.6B")
    parser.add_argument("--db", required=True, help="SQLite database path.")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--merged-output-dir", required=True)
    parser.add_argument("--max-steps", type=int, default=-1)
    parser.add_argument("--epochs", type=float, default=16.0)
    parser.add_argument("--learning-rate", type=float, default=1e-4)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=2)
    parser.add_argument("--num-generations", type=int, default=4)
    parser.add_argument("--max-prompt-length", type=int, default=512)
    parser.add_argument("--max-completion-length", type=int, default=256)
    parser.add_argument("--beta", type=float, default=0.05)
    parser.add_argument("--lora-r", type=int, default=8)
    parser.add_argument("--lora-alpha", type=int, default=16)
    parser.add_argument("--report-to", default=os.environ.get("REPORT_TO", "wandb"))
    parser.add_argument("--run-name", default=os.environ.get("WANDB_RUN_NAME", "grpo-sqlite-tools"))
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--reset-db", action=argparse.BooleanOptionalAction, default=True)
    return parser.parse_args()


def connect() -> sqlite3.Connection:
    db_path = os.environ["HOTEL_DB_PATH"]
    connection = sqlite3.connect(db_path, timeout=30)
    connection.row_factory = sqlite3.Row
    return connection


def initialize_database(path: Path, reset: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as connection:
        if reset:
            connection.execute("DROP TABLE IF EXISTS hotels")
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS hotels(
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                location TEXT NOT NULL,
                price_tier TEXT NOT NULL,
                checkin_date TEXT NOT NULL,
                checkout_date TEXT NOT NULL,
                booked INTEGER NOT NULL CHECK(booked IN (0, 1))
            )
            """
        )
        if reset or connection.execute("SELECT COUNT(*) FROM hotels").fetchone()[0] == 0:
            connection.executemany(
                """
                INSERT OR REPLACE INTO hotels
                (id, name, location, price_tier, checkin_date, checkout_date, booked)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                HOTELS,
            )


def rows_as_dicts(rows: list[sqlite3.Row]) -> list[dict[str, Any]]:
    return [dict(row) for row in rows]


def search_hotels_by_name(name: str) -> list[dict[str, Any]]:
    """Search hotels whose names contain the supplied text.

    Args:
        name: Full or partial hotel name.

    Returns:
        Matching hotel records including IDs and booking state.
    """
    with connect() as connection:
        rows = connection.execute(
            "SELECT * FROM hotels WHERE name LIKE ? COLLATE NOCASE ORDER BY id",
            (f"%{name}%",),
        ).fetchall()
    return rows_as_dicts(rows)


def search_hotels_by_location(location: str) -> list[dict[str, Any]]:
    """Search hotels in a city or location.

    Args:
        location: Full or partial city/location name.

    Returns:
        Matching hotel records including IDs and booking state.
    """
    with connect() as connection:
        rows = connection.execute(
            "SELECT * FROM hotels WHERE location LIKE ? COLLATE NOCASE ORDER BY id",
            (f"%{location}%",),
        ).fetchall()
    return rows_as_dicts(rows)


def book_hotel(hotel_id: int) -> str:
    """Book a hotel by database ID.

    Args:
        hotel_id: Numeric ID returned by a hotel search tool.

    Returns:
        A booking confirmation or an error message.
    """
    with connect() as connection:
        row = connection.execute("SELECT name, booked FROM hotels WHERE id = ?", (hotel_id,)).fetchone()
        if row is None:
            return f"Hotel ID {hotel_id} was not found."
        connection.execute("UPDATE hotels SET booked = 1 WHERE id = ?", (hotel_id,))
    return f"{row['name']} is booked."


def update_hotel(hotel_id: int, checkin_date: str, checkout_date: str) -> str:
    """Update the dates for a hotel reservation.

    Args:
        hotel_id: Numeric ID returned by a hotel search tool.
        checkin_date: New check-in date in YYYY-MM-DD format.
        checkout_date: New check-out date in YYYY-MM-DD format.

    Returns:
        An update confirmation or an error message.
    """
    if checkin_date >= checkout_date:
        return "Check-out date must be after check-in date."
    with connect() as connection:
        row = connection.execute("SELECT name FROM hotels WHERE id = ?", (hotel_id,)).fetchone()
        if row is None:
            return f"Hotel ID {hotel_id} was not found."
        connection.execute(
            "UPDATE hotels SET checkin_date = ?, checkout_date = ? WHERE id = ?",
            (checkin_date, checkout_date, hotel_id),
        )
    return f"{row['name']} dates updated to {checkin_date} through {checkout_date}."


def cancel_hotel(hotel_id: int) -> str:
    """Cancel a hotel booking by database ID.

    Args:
        hotel_id: Numeric ID returned by a hotel search tool.

    Returns:
        A cancellation confirmation or an error message.
    """
    with connect() as connection:
        row = connection.execute("SELECT name FROM hotels WHERE id = ?", (hotel_id,)).fetchone()
        if row is None:
            return f"Hotel ID {hotel_id} was not found."
        connection.execute("UPDATE hotels SET booked = 0 WHERE id = ?", (hotel_id,))
    return f"{row['name']} booking is cancelled."


TOOLS = [
    search_hotels_by_location,
    search_hotels_by_name,
    book_hotel,
    update_hotel,
    cancel_hotel,
]


def build_dataset() -> Dataset:
    examples = [
        ("Find hotels in Basel with Basel in the name.", "Hilton Basel"),
        ("Book the Hilton Basel for me.", "booked"),
        ("Cancel Hilton Basel and book Hyatt Regency Basel instead.", "Hyatt Regency Basel"),
        ("Update the Hyatt Regency Basel stay to 2026-08-10 through 2026-08-19.", "updated"),
    ]
    return Dataset.from_list(
        [
            {
                "prompt": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": question},
                ],
                "answer": answer,
            }
            for question, answer in examples
        ]
    )


def completion_text(completion: Any) -> str:
    if isinstance(completion, str):
        return completion
    if isinstance(completion, list):
        return "\n".join(
            json.dumps(message, sort_keys=True) if isinstance(message, dict) else str(message)
            for message in completion
        )
    return str(completion)


def accuracy_reward(completions: list[Any], answer: list[str], **_: Any) -> list[float]:
    """Reward responses containing the expected outcome keyword."""
    return [
        float(str(expected).casefold() in completion_text(completion).casefold())
        for completion, expected in zip(completions, answer, strict=True)
    ]


def main() -> None:
    args = parse_args()
    db_path = Path(args.db).expanduser().resolve()
    os.environ["HOTEL_DB_PATH"] = str(db_path)
    initialize_database(db_path, args.reset_db)

    output_dir = Path(args.output_dir).expanduser()
    merged_output_dir = Path(args.merged_output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    merged_output_dir.mkdir(parents=True, exist_ok=True)

    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True, padding_side="left")
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    dtype = torch.bfloat16 if torch.cuda.is_available() and torch.cuda.is_bf16_supported() else torch.float16
    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        torch_dtype=dtype,
        trust_remote_code=True,
    )
    model.config.use_cache = False

    peft_config = LoraConfig(
        task_type="CAUSAL_LM",
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        target_modules="all-linear",
        bias="none",
    )
    training_args = GRPOConfig(
        output_dir=str(output_dir),
        learning_rate=args.learning_rate,
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        num_generations=args.num_generations,
        num_train_epochs=args.epochs,
        max_steps=args.max_steps,
        max_prompt_length=args.max_prompt_length,
        max_completion_length=args.max_completion_length,
        beta=args.beta,
        logging_steps=1,
        save_strategy="epoch",
        report_to=args.report_to,
        run_name=args.run_name,
        bf16=dtype == torch.bfloat16,
        fp16=dtype == torch.float16,
        gradient_checkpointing=True,
        remove_unused_columns=False,
        seed=args.seed,
    )
    trainer = GRPOTrainer(
        model=model,
        args=training_args,
        processing_class=tokenizer,
        train_dataset=build_dataset(),
        tools=TOOLS,
        reward_funcs=accuracy_reward,
        peft_config=peft_config,
    )
    trainer.train()
    trainer.save_model(str(output_dir))
    tokenizer.save_pretrained(str(output_dir))

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
    merged_model = PeftModel.from_pretrained(base_model, str(output_dir)).merge_and_unload()
    merged_model.save_pretrained(str(merged_output_dir), safe_serialization=True)
    tokenizer.save_pretrained(str(merged_output_dir))
    print(f"SQLite database: {db_path}", flush=True)
    print(f"Trainer output: {output_dir}", flush=True)
    print(f"Merged checkpoint: {merged_output_dir}", flush=True)


if __name__ == "__main__":
    main()
