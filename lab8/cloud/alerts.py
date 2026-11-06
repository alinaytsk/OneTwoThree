"""The real-time half of the cloud pipeline: watch the failure rate, publish an alert.

This is the cheap stand-in for Flink in the Uklon diagram. It sees one batch of Kinesis
records at a time and has no state between invocations, so it judges each batch on its
own. That is honest about what it can do: a batch is a few hundred events over at most
30 seconds, which is a short window, not a sliding one. Anything that has to remember
across batches - a session, a per-minute window that spans invocations - needs somewhere
to keep state: DynamoDB, or Flink proper.
"""

from __future__ import annotations

import base64
import json
import os
from collections import defaultdict

import boto3

sns = boto3.client("sns")

TOPIC_ARN = os.environ["ALERT_TOPIC_ARN"]
THRESHOLD = float(os.environ.get("FAILURE_THRESHOLD", "0.10"))
# Below this many terminal events a share means nothing: 1 failure out of 3 is 33%.
MINIMUM_EVENTS = 20


def handler(event, _context):
    per_method: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    read = 0

    for record in event["Records"]:
        payload = json.loads(base64.b64decode(record["kinesis"]["data"]))
        read += 1
        if payload.get("status") not in ("success", "failure"):
            continue
        counts = per_method[payload.get("paymentMethod", "unknown")]
        counts[0] += 1
        if payload["status"] == "failure":
            counts[1] += 1

    alerts = []
    for method, (total, failed) in sorted(per_method.items()):
        if total < MINIMUM_EVENTS:
            continue
        share = failed / total
        if share > THRESHOLD:
            alerts.append(
                f"{method}: {share:.1%} of {total} payments failed ({failed} failures)"
            )

    if alerts:
        body = (
            "Payment failure rate above "
            f"{THRESHOLD:.0%} in the last batch of {read} events:\n\n"
            + "\n".join(alerts)
        )
        sns.publish(TopicArn=TOPIC_ARN, Subject="Payment failures above threshold",
                    Message=body)

    # One JSON line per batch, so CloudWatch Logs Insights can chart it later.
    print(json.dumps({
        "records": read,
        "methods": {m: {"total": t, "failed": f} for m, (t, f) in per_method.items()},
        "alerts": len(alerts),
    }))
    return {"records": read, "alerts": len(alerts)}
