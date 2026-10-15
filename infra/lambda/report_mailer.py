"""Mailer Lambda: email the weekly report CSV that just landed in S3.

Deliberately not the backend image. This function sits *outside* the VPC because it has to
reach SES, and the VPC has no NAT gateway; it also has to stay small, so it uses the standard
library plus the boto3 that the Lambda runtime already ships. Nothing here imports `app.*`.

It never writes to the reports/ prefix. If it did, its own PutObject would fire the same
ObjectCreated notification that invoked it and the function would email itself forever.

Each run logs one line Logs Insights can take apart:

  fields @timestamp, @message
  | filter @message like /report-mailer/
  | parse @message "trigger=* key=*" as trigger, key
"""

import logging
import os
from email.message import EmailMessage
from typing import Any
from urllib.parse import unquote_plus

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

MAIL_FROM = os.environ.get("MAIL_FROM", "")
MAIL_TO = [address.strip() for address in os.environ.get("MAIL_TO", "").split(",") if address.strip()]
SUBJECT_PREFIX = os.environ.get("MAIL_SUBJECT_PREFIX", "Weekly meetings report")
# Guard, not a router: the notification is already filtered to this prefix, and honouring it
# here too means a stray notification can never make the function act on another prefix.
REPORT_PREFIX = os.environ.get("REPORT_PREFIX", "reports/")

s3 = boto3.client("s3")
ses = boto3.client("sesv2")


def _log(message: str, **fields: Any) -> None:
    logger.info("%s %s", message, " ".join(f"{key}={value}" for key, value in fields.items()))


def _week_from_key(key: str) -> str:
    """reports/2026-W40.csv -> 2026-W40 (the same convention as weekly.report_key)."""
    name = key.rsplit("/", 1)[-1]
    return name[:-4] if name.endswith(".csv") else name


def _build_message(week: str, filename: str, csv_bytes: bytes) -> EmailMessage:
    message = EmailMessage()
    message["Subject"] = f"{SUBJECT_PREFIX} - {week}"
    message["From"] = MAIL_FROM
    message["To"] = ", ".join(MAIL_TO)
    message.set_content(
        f"Weekly meetings report for ISO week {week} is attached as {filename}.\n\n"
        "Meeting counts, total hours, the change against the previous week, the five longest\n"
        "meetings and a per-person breakdown are all in the file.\n"
    )
    message.add_attachment(
        csv_bytes,
        maintype="text",
        subtype="csv",
        filename=filename,
        # The builder writes UTF-8 with a BOM so the attachment opens correctly in Excel.
        params={"charset": "utf-8"},
    )
    return message


def _send(week: str, key: str, csv_bytes: bytes) -> None:
    message = _build_message(week, key.rsplit("/", 1)[-1], csv_bytes)
    response = ses.send_email(
        FromEmailAddress=MAIL_FROM,
        Destination={"ToAddresses": MAIL_TO},
        Content={"Raw": {"Data": message.as_bytes()}},
    )
    _log("report-mailer sent", trigger="s3", key=key, week=week, message_id=response.get("MessageId"))


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    if not MAIL_FROM or not MAIL_TO:
        raise RuntimeError("MAIL_FROM and MAIL_TO must be set")

    sent, skipped = [], []
    # S3 may batch several objects into one notification; record 0 is the usual case.
    for record in event.get("Records") or []:
        bucket = record["s3"]["bucket"]["name"]
        # Keys arrive URL-encoded in S3 events, and "+" means a space, hence unquote_plus.
        key = unquote_plus(record["s3"]["object"]["key"])
        _log("report-mailer triggered", trigger="s3", key=key, bucket=bucket)

        if not key.startswith(REPORT_PREFIX) or not key.endswith(".csv"):
            _log("report-mailer skipped", trigger="s3", key=key, reason="unexpected-key")
            skipped.append(key)
            continue

        csv_bytes = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        _send(_week_from_key(key), key, csv_bytes)
        sent.append(key)

    return {"sent": sent, "skipped": skipped, "recipients": len(MAIL_TO)}
