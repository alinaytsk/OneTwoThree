"""Read the payments topic, drop repeats, and alert when failures pass 10%.

Three things happen here, and they are easy to confuse:

  dedupe      the same event delivered twice is one event
  windowing   events are grouped by their own time (modifiedDate), not by arrival
  waiting     a window stays open for `--lateness` seconds of event time after it ends,
              because about 2% of events arrive up to ten minutes late

A window closes when the watermark - the latest event time seen, which only moves
forward - passes window_end + lateness. Anything for a window already closed is counted
as rejected: too late to change a number that has already been reported.

    python consumer.py
    python consumer.py --group analytics --lateness 0      # experiment 4
"""

from __future__ import annotations

import argparse
import json
import signal
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from confluent_kafka import Consumer, KafkaError

TOPIC = "payments"
WINDOW = timedelta(minutes=1)
ALERT_THRESHOLD = 0.10

running = True


def stop(_signum, _frame) -> None:
    global running
    running = False


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def window_start(moment: datetime) -> datetime:
    return moment.replace(second=0, microsecond=0)


class Windows:
    """Counts of terminal events per minute and payment method, closed by a watermark."""

    def __init__(self, lateness: timedelta) -> None:
        self.lateness = lateness
        self.counts: dict[datetime, dict[str, list[int]]] = defaultdict(
            lambda: defaultdict(lambda: [0, 0])  # [terminal events, failures]
        )
        self.watermark = datetime.min.replace(tzinfo=timezone.utc)
        self.closed_through = datetime.min.replace(tzinfo=timezone.utc)
        self.rejected_late = 0
        self.alerts = 0

    def add(self, event: dict) -> None:
        # Only a terminal status says whether a payment failed; created and processing
        # are on the way there and would dilute the share.
        if event["status"] not in ("success", "failure"):
            return

        moment = parse_time(event["modifiedDate"])
        self.watermark = max(self.watermark, moment)
        start = window_start(moment)

        if start < self.closed_through:
            self.rejected_late += 1
            return

        bucket = self.counts[start][event["paymentMethod"]]
        bucket[0] += 1
        if event["status"] == "failure":
            bucket[1] += 1

    def close_ready(self) -> None:
        """Report every window whose end plus the grace period is behind the watermark."""
        ready = sorted(
            start for start in self.counts
            if start + WINDOW + self.lateness <= self.watermark
        )
        for start in ready:
            self.report(start, self.counts.pop(start))
            self.closed_through = max(self.closed_through, start + WINDOW)

    def flush(self) -> None:
        for start in sorted(self.counts):
            self.report(start, self.counts.pop(start))

    def report(self, start: datetime, methods: dict[str, list[int]]) -> None:
        label = start.strftime("%H:%M")
        parts = []
        for method in sorted(methods):
            total, failed = methods[method]
            share = failed / total if total else 0.0
            parts.append(f"{method} {share:6.1%} ({failed}/{total})")
            if share > ALERT_THRESHOLD:
                self.alerts += 1
                print(f"  ALERT  {label}  {method}: failure rate {share:.1%} "
                      f"({failed} of {total}) is above {ALERT_THRESHOLD:.0%}")
        print(f"[{label}] " + " | ".join(parts), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--broker", default="localhost:19092")
    parser.add_argument("--group", default="payments-analytics")
    parser.add_argument("--lateness", type=float, default=120.0,
                        help="seconds of event time to wait for late events")
    parser.add_argument("--from-start", action="store_true",
                        help="read the topic from the beginning instead of resuming")
    args = parser.parse_args()

    signal.signal(signal.SIGINT, stop)

    consumer = Consumer({
        "bootstrap.servers": args.broker,
        "group.id": args.group,
        "auto.offset.reset": "earliest" if args.from_start else "latest",
        "enable.auto.commit": True,
    })
    consumer.subscribe([TOPIC])

    windows = Windows(timedelta(seconds=args.lateness))
    # In production this set lives in Redis or Flink state with a TTL: here it grows for
    # as long as the process runs, which is exactly the problem the lab asks about.
    seen: set[tuple[str, str, str]] = set()
    read = duplicates = 0

    print(f"group={args.group}  lateness={args.lateness:g}s  "
          f"window={WINDOW.total_seconds():.0f}s  (ctrl-c to stop)")

    try:
        while running:
            message = consumer.poll(1.0)
            if message is None:
                windows.close_ready()
                continue
            if message.error():
                if message.error().code() != KafkaError._PARTITION_EOF:
                    print("error:", message.error())
                continue

            event = json.loads(message.value())
            read += 1

            identity = (event["invoiceId"], event["status"], event["modifiedDate"])
            if identity in seen:
                duplicates += 1
                continue
            seen.add(identity)

            windows.add(event)
            windows.close_ready()
    finally:
        windows.flush()
        consumer.close()
        print(f"\nread {read} events, {duplicates} of them repeats "
              f"({duplicates / read:.2%})" if read else "\nread nothing")
        print(f"rejected as late: {windows.rejected_late}")
        print(f"alerts raised: {windows.alerts}")
        print(f"distinct events remembered: {len(seen)}")


if __name__ == "__main__":
    main()
