"""Send the same payment events to Kinesis instead of Redpanda.

The only real difference from the local producer is the client and the batching call:
put_records takes up to 500 records at a time, and the partition key does what the Kafka
key did - it decides the shard, so all events of one payment stay in order.

    python producer.py --day 2026-10-01 --limit 5000 --rate 60
    python producer.py --day 2026-10-01 --limit 3000 --rate 60 --fail-rate 0.30
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import boto3

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "stream"))
from producer import fail_some_payments, load_day, parse_time  # noqa: E402

BATCH = 500


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--day", default="2026-10-01")
    parser.add_argument("--stream", default="lab8-payments-stream")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--rate", type=float, default=60.0)
    parser.add_argument("--limit", type=int, default=5000)
    parser.add_argument("--fail-rate", type=float, default=0.0)
    args = parser.parse_args()

    events = load_day(args.day)
    if args.fail_rate:
        changed = fail_some_payments(events, args.fail_rate)
        print(f"turned {changed} payments into failures")
    if args.limit:
        events = events[: args.limit]

    payments = len({event["invoiceId"] for event in events})
    span = (parse_time(events[-1]["receivedAt"])
            - parse_time(events[0]["receivedAt"])).total_seconds()
    target = payments / args.rate
    speed = span / target if target else 1.0

    kinesis = boto3.client("kinesis", region_name=args.region)
    print(f"{len(events)} events of {payments} payments -> {args.stream} "
          f"({speed:.0f}x real time, ~{args.rate:g} payments/s)")

    started = time.monotonic()
    first = parse_time(events[0]["receivedAt"])
    sent = failed = 0

    for index in range(0, len(events), BATCH):
        chunk = events[index:index + BATCH]

        # Keep the batch on the compressed clock, by its last record.
        offset = (parse_time(chunk[-1]["receivedAt"]) - first).total_seconds() / speed
        behind = offset - (time.monotonic() - started)
        if behind > 0:
            time.sleep(behind)

        response = kinesis.put_records(
            StreamName=args.stream,
            Records=[
                {
                    # The newline is not decoration. Firehose concatenates the records it
                    # receives with nothing in between, so without it the object in S3 is
                    # one unbroken line of JSON and every reader returns zero rows.
                    "Data": json.dumps(event, ensure_ascii=False).encode() + b"\n",
                    "PartitionKey": event["invoiceId"],
                }
                for event in chunk
            ],
        )
        failed += response["FailedRecordCount"]
        sent += len(chunk) - response["FailedRecordCount"]
        print(f"  {sent}/{len(events)} sent"
              + (f", {failed} rejected" if failed else ""), flush=True)

    elapsed = time.monotonic() - started
    print(f"sent {sent} events in {elapsed:.1f} s ({sent / elapsed:.1f} events/s), "
          f"{failed} rejected")


if __name__ == "__main__":
    main()
