#!/usr/bin/env python3
"""Run every test input through the DEPLOYED parser and write the results table.

Used by `make parse-table`, which passes the function URL and a Cognito ID token. Standard
library only: it runs on whatever python is at hand, not inside the backend's virtualenv.

    python3 infra/scripts/parse_table.py --url <function url> --token <id token> \
        --inputs docs/agenda-tests/inputs.json --out docs/agenda-tests/results.json

It prints a Markdown table on stdout (Input / Correct / Invented / Tokens / Cost / Latency) and
saves every full answer to --out, so the submission quotes measured numbers rather than guesses.
"""

import argparse
import json
import time
import urllib.error
import urllib.request


def parse_one(url: str, token: str, text: str, timeout: float) -> dict:
    """POST one paste; return the status, the body and how long the round trip took."""
    request = urllib.request.Request(
        url,
        data=json.dumps({"text": text}).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        method="POST",
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        # The 4xx answers are results too: 422 for "not an agenda", 413 for a paste over the limit.
        status, raw = error.code, error.read()
    except urllib.error.URLError as error:
        return {"status": None, "error": str(error), "wall_ms": round((time.monotonic() - started) * 1000)}
    wall_ms = round((time.monotonic() - started) * 1000)
    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        body = {"raw": raw[:500].decode("utf-8", "replace")}
    return {"status": status, "body": body, "wall_ms": wall_ms}


def one_line(value: object, limit: int = 110) -> str:
    """Compact JSON on a single line, short enough for a table cell."""
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    text = text.replace("|", "\\|")
    return text if len(text) <= limit else text[: limit - 1] + "…"


def main() -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--url", required=True, help="parser function URL")
    arguments.add_argument("--token", required=True, help="Cognito ID token")
    arguments.add_argument("--inputs", default="docs/agenda-tests/inputs.json")
    arguments.add_argument("--out", default="docs/agenda-tests/results.json")
    arguments.add_argument("--timeout", type=float, default=60.0)
    options = arguments.parse_args()

    with open(options.inputs, encoding="utf-8") as handle:
        inputs = json.load(handle)

    results = []
    for case in inputs:
        print(f"# {case['id']}. {case['label']} …", flush=True)
        outcome = parse_one(options.url, options.token, case["text"], options.timeout)
        results.append({**case, "result": outcome})
        print(f"  -> HTTP {outcome.get('status')} in {outcome['wall_ms']} ms", flush=True)

    with open(options.out, "w", encoding="utf-8") as handle:
        json.dump(results, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print()
    print("| # | Input | HTTP | JSON the parser returned | Tokens in/out | Cost | Model latency | Round trip |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    total_cost = 0.0
    for entry in results:
        outcome = entry["result"]
        body = outcome.get("body") or {}
        usage = body.get("usage") or {}
        agenda = body.get("agenda")
        cost = usage.get("cost_usd")
        if isinstance(cost, (int, float)):
            total_cost += cost
        tokens = (
            f"{usage['input_tokens']}/{usage['output_tokens']}"
            if "input_tokens" in usage
            else "-"
        )
        shown = one_line(agenda) if agenda is not None else one_line(body)
        print(
            f"| {entry['id']} | {entry['label']} | {outcome.get('status')} | `{shown}` | {tokens} "
            f"| {f'${cost:.6f}' if isinstance(cost, (int, float)) else '-'} "
            f"| {body.get('latency_ms', '-')} ms | {outcome['wall_ms']} ms |"
        )
    print()
    print(f"Total for {len(results)} parses: ${total_cost:.6f}")
    print(f"Full answers: {options.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
