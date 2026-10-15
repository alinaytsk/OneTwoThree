"""Builder Lambda: turn an ISO week into a CSV object in S3.

Runs from the backend image (it needs the models and the database), so it lives in the VPC
and reaches S3 through the gateway endpoint - there is no NAT gateway and no route to SES
from here. Writing the object is the whole job; the mailer Lambda reacts to that write.

Three event shapes arrive:

  schedule  EventBridge Scheduler invoking the function directly: {"week": ..., "source": "schedule"}
  sqs       the queue the Scheduler actually targets:  {"Records": [{"body": "<json>", ...}]}
  manual    aws lambda invoke --payload '{"week": "2026-W40"}'

Each run logs one line that CloudWatch Logs Insights can take apart:

  fields @timestamp, @message
  | filter @message like /report-builder triggered/
  | parse @message "trigger=* source=* week=* key=*" as trigger, source, week, key
  | sort @timestamp desc
"""

import json
import logging
import os
from typing import Any

import boto3
from botocore.exceptions import ClientError

from app.reports.weekly import build_weekly_report, current_week, previous_week, report_key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET = os.getenv("REPORTS_BUCKET", "")

_s3 = boto3.client("s3")


def _log(message: str, **fields: Any) -> None:
    """One line, `key=value` pairs - greppable by eye and parseable by Logs Insights."""
    logger.info("%s %s", message, " ".join(f"{key}={value}" for key, value in fields.items()))


def parse_event(event: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """Work out which of the three triggers fired, and the payload it carried."""
    records = event.get("Records") or []
    if records and (records[0].get("eventSource") == "aws:sqs" or "body" in records[0]):
        body = records[0].get("body") or "{}"
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            # A hand-written message body of just the week is still worth honouring.
            payload = {"week": body.strip()}
        if not isinstance(payload, dict):
            payload = {"week": str(payload)}
        return "sqs", payload
    if event.get("source") == "schedule":
        return "schedule", event
    return "manual", event


def _exists(bucket: str, key: str) -> bool:
    try:
        _s3.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return False
        raise


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    trigger, payload = parse_event(event)
    # No week given (the weekly schedule sends none): report the week that just ended.
    week = payload.get("week") or previous_week(current_week())
    key = report_key(week)
    # A rerun of the same week is a no-op by default, so the mailer is not triggered twice.
    force = bool(payload.get("force"))

    # `trigger` is the transport, `source` what put the message there: the weekly schedule
    # targets the queue, so its runs show up as trigger=sqs source=schedule.
    source = payload.get("source", "unknown")
    _log("report-builder triggered", trigger=trigger, source=source, week=week, key=key)

    if not BUCKET:
        raise RuntimeError("REPORTS_BUCKET is not set")

    if not force and _exists(BUCKET, key):
        _log("report-builder skipped", trigger=trigger, source=source, week=week, key=key, reason="exists")
        return {"status": "exists", "week": week, "key": key, "trigger": trigger, "source": source}

    body = build_weekly_report(week)
    _s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=body,
        ContentType="text/csv; charset=utf-8",
        # Read back by the mailer, which puts it in the subject line without opening the file.
        Metadata={"week": week, "trigger": trigger, "source": source},
    )
    _log("report-builder wrote", trigger=trigger, source=source, week=week, key=key, bytes=len(body))
    return {
        "status": "written",
        "week": week,
        "key": key,
        "trigger": trigger,
        "source": source,
        "bytes": len(body),
    }
