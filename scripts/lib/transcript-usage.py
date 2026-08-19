#!/usr/bin/env python3
"""Parse a Claude Code transcript JSONL and aggregate token usage + cost.

Shared by track-subagent.sh (per-subagent) and track-session.sh (per main
session) so both produce identical token/cost/model fields.

Usage:
    python3 transcript-usage.py <transcript_path>

Prints a JSON object to stdout:
    {model, api_calls, input_tokens, output_tokens,
     cache_read_tokens, cache_create_tokens, total_tokens, cost_estimated}

On any error (missing/unreadable file) it still prints a well-formed object
with zeroed counters, so callers never break.
"""
import json
import os
import sys

# Pricing per million tokens (input, output, cache_read, cache_create).
# Approximate published rates; used for an estimate, not billing.
PRICING = {
    "opus":   {"input": 15.0, "output": 75.0, "cache_read": 1.50, "cache_create": 18.75},
    "sonnet": {"input":  3.0, "output": 15.0, "cache_read": 0.30, "cache_create":  3.75},
    "haiku":  {"input":  0.8, "output":  4.0, "cache_read": 0.08, "cache_create":  1.00},
}


def tier_for(model: str) -> str:
    m = (model or "").lower()
    if "opus" in m:
        return "opus"
    if "haiku" in m:
        return "haiku"
    return "sonnet"  # default / sonnet


def parse(transcript_path: str) -> dict:
    model = ""
    inp = out = cr = cc = calls = 0

    path = os.path.expanduser(transcript_path or "")
    if path:
        try:
            with open(path) as f:
                for line in f:
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    msg = entry.get("message", {})
                    if msg.get("role") == "assistant" and "usage" in msg:
                        u = msg["usage"]
                        inp += u.get("input_tokens", 0)
                        out += u.get("output_tokens", 0)
                        cr += u.get("cache_read_input_tokens", 0)
                        cc += u.get("cache_creation_input_tokens", 0)
                        model = msg.get("model", model)
                        calls += 1
        except (FileNotFoundError, OSError):
            pass

    cost = 0.0
    if model and (inp + out + cr + cc) > 0:
        p = PRICING[tier_for(model)]
        cost = (
            inp * p["input"] / 1_000_000
            + out * p["output"] / 1_000_000
            + cr * p["cache_read"] / 1_000_000
            + cc * p["cache_create"] / 1_000_000
        )

    return {
        "model": model or None,
        "api_calls": calls,
        "input_tokens": inp,
        "output_tokens": out,
        "cache_read_tokens": cr,
        "cache_create_tokens": cc,
        "total_tokens": inp + out + cr + cc,
        "cost_estimated": round(cost, 4) if cost > 0 else None,
    }


if __name__ == "__main__":
    tp = sys.argv[1] if len(sys.argv) > 1 else ""
    print(json.dumps(parse(tp)))
