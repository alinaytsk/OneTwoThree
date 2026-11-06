"""Replay one day of payment events into Redpanda, in the order they were received.

The point of replaying by receivedAt rather than modifiedDate is that it reproduces the
one thing that makes streaming hard: an event can arrive after a later one. Sorting by
event time would quietly remove the problem the consumer exists to handle.

    python producer.py --day 2026-10-01
    python producer.py --day 2026-10-01 --rate 50 --limit 2000
    python producer.py --day 2026-10-01 --fail-rate 0.30     # experiment 3

The key is invoiceId, so every event of one payment lands in one partition and keeps its
order. Without a key, the three events of a payment could be spread over three partitions
and read in any order.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from datetime import datetime
from pathlib import Path

from confluent_kafka import Producer

DATA = Path(__file__).resolve().parent.parent / "data"
TOPIC = "payments"


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def load_day(day: str) -> list[dict]:
    path = DATA / f"dt={day}" / "events.jsonl"
    if not path.exists():
        sys.exit(
            f"no local copy of {day} at {path}\n"
            f"download it first:  make -C .. data DAY={day}"
        )
    with path.open(encoding="utf-8") as handle:
        events = [json.loads(line) for line in handle if line.strip()]
    # Arrival order, which is not event order: this is what makes events late.
    events.sort(key=lambda event: event["receivedAt"])
    return events


def fail_some_payments(events: list[dict], fail_rate: float) -> int:
    """Turn roughly `fail_rate` of payments into failures, to make the alert fire.

    A payment is failed as a whole - its terminal event becomes a failure - because a
    payment that succeeds and then fails is not something the real system can produce,
    and the consumer would be right to be confused by it.
    """
    rng = random.Random(20261101)
    # Draw once per payment, not once per event: a payment has 2-3 events, so drawing per
    # event would doom it with probability 1 - (1 - rate)^3 - 66% for a rate of 30%.
    doomed = {
        invoice
        for invoice in sorted({event["invoiceId"] for event in events})
        if rng.random() < fail_rate
    }
    changed = 0
    for event in events:
        if event["invoiceId"] in doomed and event["status"] == "success":
            event["status"] = "failure"
            event["failureReason"] = "Insufficient funds"
            event["finalAmount"] = 0
            changed += 1
    return changed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--day", default="2026-10-01")
    parser.add_argument("--broker", default="localhost:19092")
    parser.add_argument("--rate", type=float, default=20.0,
                        help="payments per second (not events: a payment is 2-3 events)")
    parser.add_argument("--limit", type=int, default=0, help="stop after N events")
    parser.add_argument("--fail-rate", type=float, default=0.0,
                        help="share of payments to turn into failures")
    args = parser.parse_args()

    events = load_day(args.day)

    if args.fail_rate:
        changed = fail_some_payments(events, args.fail_rate)
        print(f"turned {changed} payments into failures ({args.fail_rate:.0%} asked for)")

    if args.limit:
        events = events[: args.limit]

    # Counted after the limit, so --limit shortens the run instead of only trimming it.
    payments = len({event["invoiceId"] for event in events})

    # One day of arrivals compressed into (payments / rate) seconds. Every gap between
    # two arrivals shrinks by the same factor, so late events stay late, proportionally.
    span = (parse_time(events[-1]["receivedAt"])
            - parse_time(events[0]["receivedAt"])).total_seconds()
    target = payments / args.rate
    speed = span / target if target > 0 else 1.0

    print(f"{len(events)} events of {payments} payments from {args.day}")
    print(f"replaying {span / 3600:.1f} h of arrivals in ~{target / 60:.1f} min "
          f"({speed:.0f}x real time, ~{args.rate:g} payments/s)")

    producer = Producer({
        "bootstrap.servers": args.broker,
        "linger.ms": 20,
        "compression.type": "snappy",
    })

    started = time.monotonic()
    first = parse_time(events[0]["receivedAt"])
    sent = 0

    for event in events:
        # Where this event belongs on the compressed clock.
        offset = (parse_time(event["receivedAt"]) - first).total_seconds() / speed
        behind = offset - (time.monotonic() - started)
        if behind > 0:
            time.sleep(behind)

        producer.produce(
            TOPIC,
            key=event["invoiceId"].encode(),
            value=json.dumps(event, ensure_ascii=False).encode(),
        )
        producer.poll(0)
        sent += 1
        if sent % 1000 == 0:
            print(f"  sent {sent}/{len(events)}", flush=True)

    producer.flush(30)
    elapsed = time.monotonic() - started
    print(f"sent {sent} events in {elapsed:.1f} s ({sent / elapsed:.1f} events/s)")


if __name__ == "__main__":
    main()
