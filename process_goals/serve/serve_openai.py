#!/usr/bin/env python3
"""Self-contained OpenAI-compatible server for the goals benchmark.

Serves any Hugging Face causal-LM checkpoint over POST /v1/chat/completions so that
`goals_bench`'s LLM arm (and any OpenAI client) can sample k proof candidates. The
generation matches the Isabelle-SFT tokenisation: the chat template is applied to the
request's messages with thinking disabled, then `n` samples are drawn.

Needs torch + transformers. Any environment with them works, e.g. a local venv:

    python3 -m venv .venv
    source .venv/bin/activate
    pip install torch transformers
    python serve/serve_openai.py --model kavaryan/Qwen3-0.6B_sft-ds --port 8000

Contract (subset of the OpenAI API):
    POST /v1/chat/completions
    Request : {"model","messages":[...],"n","temperature","max_tokens"}
    Response: {"choices":[{"index","message":{"role","content"},"finish_reason"}],...}
"""
import argparse
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

TOK = None
MODEL = None
LOCK = threading.Lock()  # one generation at a time (single small GPU)
MAX_NEW_TOKENS = 64
MAX_BATCH = 4  # samples per generate() call; bounds KV-cache size
DEVICE = "cuda"


def _template(messages):
    kw = dict(add_generation_prompt=True, return_tensors="pt")
    try:
        return TOK.apply_chat_template(messages, enable_thinking=False, **kw)
    except TypeError:  # tokenizers without the Qwen3 thinking switch
        return TOK.apply_chat_template(messages, **kw)


def _sample(ids, attn, count, temperature, max_new_tokens):
    out = MODEL.generate(
        ids, attention_mask=attn,
        do_sample=True, temperature=temperature, top_p=0.95,
        num_return_sequences=count, max_new_tokens=max_new_tokens,
        pad_token_id=TOK.eos_token_id)
    gen = out[:, ids.shape[1]:]
    texts = [TOK.decode(g, skip_special_tokens=True).strip() for g in gen]
    del out, gen
    return texts


@torch.no_grad()
def complete(messages, n, temperature, max_new_tokens):
    # draw n samples in micro-batches, halving the batch and retrying on CUDA OOM
    # so any n fits on a small GPU; the cache is freed after each request
    ids = _template(messages)
    texts, done, batch = [], 0, min(n, MAX_BATCH)
    with LOCK:
        try:
            gpu_ids = ids.to(DEVICE)
            attn = torch.ones_like(gpu_ids)
            while done < n:
                count = min(batch, n - done)
                try:
                    texts += _sample(gpu_ids, attn, count, temperature, max_new_tokens)
                    done += count
                except torch.cuda.OutOfMemoryError:
                    torch.cuda.empty_cache()
                    if batch == 1:
                        raise
                    batch = max(1, batch // 2)
        finally:
            torch.cuda.empty_cache()
    return texts


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") in ("/v1/models", "/health"):
            self._json(200, {"object": "list", "data": [{"id": MODEL.name_or_path}]})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        messages = req.get("messages", [])
        n = int(req.get("n", 1))
        temperature = float(req.get("temperature", 0.8)) or 0.01
        max_new_tokens = int(req.get("max_tokens") or MAX_NEW_TOKENS)
        try:
            texts = complete(messages, n, temperature, max_new_tokens)
        except Exception as exn:  # OOM that survives batch=1, or any model error
            torch.cuda.empty_cache()
            self._json(503, {"error": {"message": "%s: %s" % (type(exn).__name__, exn)}})
            return
        self._json(200, {
            "object": "chat.completion",
            "model": req.get("model", MODEL.name_or_path),
            "choices": [
                {"index": i, "message": {"role": "assistant", "content": t}, "finish_reason": "stop"}
                for i, t in enumerate(texts)],
        })

    def log_message(self, *args):
        pass


def main():
    global TOK, MODEL, MAX_NEW_TOKENS, MAX_BATCH, DEVICE
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--max-new-tokens", type=int, default=64)
    ap.add_argument("--max-batch", type=int, default=4,
                    help="samples per generate() call (lower if you hit CUDA OOM)")
    ap.add_argument("--device", default="cuda")
    args = ap.parse_args()

    MAX_NEW_TOKENS = args.max_new_tokens
    MAX_BATCH = args.max_batch
    DEVICE = args.device
    print("serve_openai: loading %s on %s ..." % (args.model, args.device), flush=True)
    TOK = AutoTokenizer.from_pretrained(args.model)
    MODEL = AutoModelForCausalLM.from_pretrained(
        args.model, torch_dtype=torch.float16, device_map=args.device)
    MODEL.eval()
    print("serve_openai: ready on http://localhost:%d/v1/chat/completions" % args.port, flush=True)
    ThreadingHTTPServer(("localhost", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
