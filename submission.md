# Lab 5 — Weekly meetings report (event-driven on AWS)

Alina Yatsko · OneTwoThree · 2026-10-15

---

## Completion status

All eight steps were run end to end against the deployed stack. Every log line, metric and queue
state below was copied from the live account, not reconstructed.

| # | Step | Status |
|---|------|--------|
| 1 | Push commits | ✅ `2fd9681..3e171ba` |
| 2 | Report for a week with meetings, email delivered | ✅ W42 — 3 meetings, SES `Delivery` |
| 3 | `trigger=sqs` and `trigger=s3` log lines | ✅ captured |
| 4 | Scheduled firing, then cron restored | ✅ fired 21:01:48, cron restored and verified |
| 5 | DLQ after 3 failures, then redrive | ✅ 3 failures → DLQ → redrive → success |
| 6 | Double-send test | ✅ 2 runs, 0 extra emails (SES `Send` 5.0 → 5.0) |
| 7 | Final artifacts | ✅ below |
| 8 | Step 7 / class answers | ✅ below, based on the measured results |

One caveat, stated plainly: the email is **delivered but filed as Spam** by Gmail. That is a
DMARC alignment consequence of the sender address, explained in the answers — not a pipeline
failure. SES reports `Send 5.0 / Delivery 5.0 / Bounce 0 / Reject 0`.

---

## 1. Commit

| | |
|---|---|
Commit | `3e171ba` |
Message | `fix(reports): grant the builder s3:ListBucket so HeadObject returns 404` |
URL | https://github.com/alinaytsk/OneTwoThree/commit/3e171ba |
Repository | https://github.com/alinaytsk/OneTwoThree |

The feature itself landed in `2fd9681` (*Lab 5: weekly report*):
https://github.com/alinaytsk/OneTwoThree/commit/2fd9681

Files: `back/app/reports/weekly.py`, `back/app/reports/lambda_handler.py`,
`infra/lambda/report_mailer.py`, `infra/reports.yml`, `back/tests/test_weekly_report.py`,
plus `Makefile` targets (`report-now`, `aws-reports-*`).

---

## 2. Screenshot of the delivered email

<!-- paste the screenshot here -->

Find it with `in:anywhere subject:"Weekly meetings report"` — it is in **Spam**, see the answers.

---

## 3. Architecture

```
EventBridge Scheduler        cron(0 7 ? * MON *), Europe/Kyiv, FlexibleTimeWindow OFF
      │ SendMessage {"source": "schedule"}
      ▼
SQS meetings-report-requests  VisibilityTimeout 720s (6 × builder timeout)
      │                       maxReceiveCount 3 → meetings-report-requests-dlq
      │ EventSourceMapping, BatchSize 1
      ▼
Lambda report-builder        backend image, in the VPC (reads Aurora),
      │                      S3 via gateway endpoint — no NAT gateway
      │ PutObject reports/<week>.csv
      ▼
S3 meetings-reports-<account>  private, 90-day lifecycle
      │ ObjectCreated, prefix reports/, suffix .csv
      ▼
Lambda report-mailer         outside the VPC (needs SES), zip, stdlib + boto3
      ▼                      sesv2:SendEmail, Raw content, CSV attached
MAIL_TO
```

---

## 4. S3 contents

```
$ aws s3 ls s3://meetings-reports-896138901201/reports/ --recursive
2026-10-15 21:11:02        563 reports/2026-W01.csv
2026-10-15 20:29:56        563 reports/2026-W40.csv
2026-10-15 21:02:06        614 reports/2026-W41.csv
2026-10-15 20:50:05        696 reports/2026-W42.csv
```

| Object | Origin |
|---|---|
`2026-W01.csv` | the DLQ test — written after the redrive (step 5) |
`2026-W40.csv` | first manual run; empty week |
`2026-W41.csv` | written by the **scheduled** run (step 4) |
`2026-W42.csv` | the manual report with real data (step 2) |

### The W42 report

```csv
report,weekly meetings
week,2026-W42
period_start,2026-10-12T00:00:00+03:00
period_end,2026-10-19T00:00:00+03:00
timezone,Europe/Kyiv
previous_week,2026-W41
generated_at,2026-10-15T23:50:04+03:00

section,totals
metric,2026-W42,2026-W41,delta
meetings,3,1,2
hours,3.00,1.00,2.00

section,top 5 longest meetings
rank,title,starts_at,duration_hours,participants
1,Лаба,2026-10-17T11:00+03:00,1.00,0
2,сон,2026-10-17T17:00+03:00,1.00,0
3,пара,2026-10-18T15:00+03:00,1.00,0

section,by organiser (meeting owner)
name,email,meetings,hours
alinayatsko10@gmail.com,alinayatsko10@gmail.com,3,3.00

section,by participant
name,email,meetings,hours
(nobody),,0,0.00
```

---

## 5. CloudWatch log lines

Both functions log one `key=value` line per run. Logs Insights query:

```
fields @timestamp, @message
| filter @message like /report-builder triggered/
| parse @message "trigger=* source=* week=* key=*" as trigger, source, week, key
| sort @timestamp desc
```

### `trigger=sqs` — builder, invoked through the queue

```
2026-10-15T21:12:05.518Z  9159b47e-9bdd-5706-ab5d-d735d80fc942
report-builder triggered trigger=sqs source=manual week=2026-W42 key=reports/2026-W42.csv
```

The run that actually produced the W42 report:

```
2026-10-15T20:49:46.286Z  68e9dcda-1444-5d22-aec1-bf912ae5808a
report-builder triggered trigger=sqs source=manual week=2026-W42 key=reports/2026-W42.csv
2026-10-15T20:50:04.539Z  68e9dcda-1444-5d22-aec1-bf912ae5808a
report-builder wrote trigger=sqs source=manual week=2026-W42 key=reports/2026-W42.csv bytes=696
```

### `trigger=s3` — mailer, invoked by the ObjectCreated notification

```
2026-10-15T20:50:06.618Z  e0aa5b8a-49d5-476f-aae5-a614439371e4
report-mailer triggered trigger=s3 key=reports/2026-W42.csv bucket=meetings-reports-896138901201
2026-10-15T20:50:07.097Z  e0aa5b8a-49d5-476f-aae5-a614439371e4
report-mailer sent trigger=s3 key=reports/2026-W42.csv week=2026-W42 message_id=010001a141545017-ccf6a388-1e15-4d28-b16c-6fa2785291c7-000000
```

### `source=schedule` — builder, started by EventBridge Scheduler

The schedule was temporarily switched to `rate(5 minutes)` at 21:01:06 UTC and fired 42 s later:

```
2026-10-15T21:01:48.369Z  46dc24c1-eec8-5e24-a4e1-478aafbb0968
report-builder triggered trigger=sqs source=schedule week=2026-W41 key=reports/2026-W41.csv
2026-10-15T21:02:05.093Z  46dc24c1-eec8-5e24-a4e1-478aafbb0968
report-builder wrote trigger=sqs source=schedule week=2026-W41 key=reports/2026-W41.csv bytes=614
2026-10-15T21:02:06.662Z  db5bab15-0af8-4cb7-b1ca-0b5eb7eb96dc
report-mailer triggered trigger=s3 key=reports/2026-W41.csv bucket=meetings-reports-896138901201
```

Two points this proves beyond the trigger itself:

* **The week was computed by the handler, not passed in.** The Scheduler target sends
  `{"source": "schedule"}` with no week, and the builder derived the previous ISO week,
  `2026-W41`. `build_weekly_report` never decides what "last week" means — that is the division
  of responsibility the task requires.
* **It reads `trigger=sqs source=schedule`, not `trigger=schedule`.** The Scheduler targets the
  queue rather than invoking the function, so the transport is SQS and only the origin is the
  schedule. `trigger=schedule` is reserved for direct invocation, which this design does not use.

Cron restored immediately after the single firing, verified against the original snapshot:

```
expr:   cron(0 7 ? * MON *)      tz:     Europe/Kyiv
state:  ENABLED                  window: OFF
target: arn:aws:sqs:us-east-1:896138901201:meetings-report-requests
input:  {"source": "schedule"}
```

---

## 6. DLQ test (step 5)

A temporary fault was deployed that made `build_weekly_report` raise for `2026-W01` only. The
queue's visibility timeout was lowered from 720 s to 60 s for the duration so the three retries
took minutes rather than ~25 minutes; it was restored afterwards.

```
21:05:13  report-builder triggered trigger=sqs source=manual week=2026-W01 key=reports/2026-W01.csv
21:05:13  [ERROR] RuntimeError: deliberate failure for 2026-W01: exercising the SQS redrive policy
21:06:10  report-builder triggered ... week=2026-W01            ← attempt 2
21:06:10  [ERROR] RuntimeError: deliberate failure for 2026-W01 ...
21:07:10  report-builder triggered ... week=2026-W01            ← attempt 3
21:07:10  [ERROR] RuntimeError: deliberate failure for 2026-W01 ...
```

Message reached the DLQ ~170 s after being sent. **DLQ contents:**

```json
[{ "body": "{\"week\": \"2026-W01\", \"source\": \"manual\"}", "received": "4" }]
```

The body survived intact. No partial object was written to S3.

**Redrive.** The fault was removed, the image redeployed, and the message moved back with the
native redrive API:

```
$ aws sqs start-message-move-task --source-arn <dlq> --destination-arn <main>
{"Status": "COMPLETED", "ApproximateNumberOfMessagesMoved": 1, "ApproximateNumberOfMessagesToMove": 1}
```

```
21:10:45  report-builder triggered trigger=sqs source=manual week=2026-W01 key=reports/2026-W01.csv
21:11:01  report-builder wrote     trigger=sqs source=manual week=2026-W01 key=reports/2026-W01.csv bytes=563
21:11:03  report-mailer  triggered trigger=s3 key=reports/2026-W01.csv
21:11:04  report-mailer  sent      trigger=s3 key=reports/2026-W01.csv week=2026-W01 message_id=010001a141677df8-...
```

DLQ is empty again (all counters 0). Queue attributes restored:

```json
{"VisibilityTimeout": "720",
 "RedrivePolicy": "{\"deadLetterTargetArn\":\"...-dlq\",\"maxReceiveCount\":3}",
 "MessageRetentionPeriod": "345600"}
```

---

## 7. Double-send test (step 6)

`make report-now WEEK=2026-W42` run twice in a row, two seconds apart, with the report already
in S3.

```
21:12:05  report-builder triggered trigger=sqs source=manual week=2026-W42 key=reports/2026-W42.csv
21:12:05  report-builder skipped   trigger=sqs source=manual week=2026-W42 key=reports/2026-W42.csv reason=exists
21:12:07  report-builder triggered trigger=sqs source=manual week=2026-W42 key=reports/2026-W42.csv
21:12:07  report-builder skipped   trigger=sqs source=manual week=2026-W42 key=reports/2026-W42.csv reason=exists
```

**Result: zero extra emails.** Four independent confirmations:

| Evidence | Value |
|---|---|
Builder outcome | `skipped … reason=exists` both times (87 ms, 14 ms) |
Mailer invocations | none — last entry is 21:11, before the test |
`2026-W42.csv` timestamp | `20:50:05`, unchanged |
SES `Send` before → after | **5.0 → 5.0** |

The builder calls `HeadObject` on `reports/<week>.csv` before writing and returns early if it
exists. No write means no `ObjectCreated` notification, which means the mailer is never invoked.
Idempotency is enforced at the object, not in the mailer.

---

## 8. Answers — Step 7 and "What we discuss in class"

### Where would you store "this report has already been sent", and what is the mailer's idempotency key?

The builder is already idempotent, and this was **measured** (section 7): a second and third
request for the same week logged `reason=exists`, wrote nothing and sent nothing. That protection
lives in S3 itself — the object is the record of "this week is done" — so no extra store is needed
for the builder.

The mailer has no equivalent protection. S3 notifications are at-least-once, so a duplicate
notification would send a duplicate email. That state belongs in a **DynamoDB table** keyed by the
idempotency key with a ~90-day TTL: `PutItem` with
`ConditionExpression: attribute_not_exists(pk)` *before* `send_email`, treating
`ConditionalCheckFailedException` as "already sent". A cheaper variant without a new table is a
marker object written with `PutObject` + `IfNoneMatch: "*"` — but it must live **outside** the
`reports/` prefix, or it re-triggers the notification that invoked the mailer.

The key must **not** be the week alone: a corrected, rebuilt report would then never be re-sent.
The right key is `(bucket, key, versionId)` with bucket versioning on, otherwise
`(bucket, key, eTag)`. S3 puts both in the event record, so a duplicate notification carries an
identical key while genuinely new content carries a different one. `s3:object.sequencer`
additionally orders events for the same key.

### Three ways the builder could reach SES, with rough cost (us-east-1)

The builder sits in a VPC with no NAT gateway, so it cannot reach SES at all.

1. **NAT gateway** — simplest to reason about, most expensive. Needs a public subnet, an IGW and
   a default route. $0.045/h ≈ **$33/month**, plus $0.045/GB and ~$3.65/month for the public IPv4
   address → **~$36/month** to move a few kilobytes a week.
2. **VPC interface endpoint (PrivateLink)** — $0.01/h per endpoint **per AZ**; two AZs here →
   **~$15/month** plus $0.01/GB, and traffic never leaves the AWS network. Caveat: SES publishes
   an interface endpoint for SMTP (`com.amazonaws.<region>.email-smtp`) in most regions, while
   availability for the SES v2 API varies by region — with SMTP only you would send via `smtplib`
   with SMTP credentials rather than `sesv2.send_email`.
3. **Split architecture (implemented)** — **$0/month**. The S3 gateway endpoint is free, the
   mailer runs outside the VPC, and S3 `ObjectCreated` is the bus between the halves. The price is
   one extra Lambda invocation per report and the loss of a single place that knows whether the
   mail was sent — which is exactly why idempotency has to be made explicit, as above.

### How would you make a presigned S3 link that lives a week?

SigV4 caps `X-Amz-Expires` at **7 days**, but the real lifetime is bounded by *what signed it*. A
Lambda execution role provides temporary STS credentials valid for hours: the
`X-Amz-Security-Token` in the URL dies with the session and the link returns `ExpiredToken` long
before the week is out. Hence: not via the Lambda role.

For a genuine 7 days you must sign with a **long-lived credential** — an IAM user restricted to
`s3:GetObject` on `reports/*`, its access key in Secrets Manager, the mailer signing with it
explicitly (no session token). The cost is a long-lived key that needs rotating.

The cleaner answer avoids long-lived AWS credentials entirely: a **CloudFront signed URL** in
front of the bucket (OAC + trusted key group). Expiry is arbitrary, it is signed with an RSA
private key that is not an AWS credential, and revoking it breaks nothing else. This project
already runs a CloudFront distribution for the frontend. The third option is to hand out no link
at all — the current design attaches the CSV, which never expires and needs no signature.

### What actually went wrong, and what it taught (worth discussing in class)

Five failures, every one found by deploying rather than by reading the template:

1. **S3 answers `403`, not `404`, for a missing object.** The builder role had `s3:GetObject` but
   not `s3:ListBucket`. S3 deliberately refuses to reveal whether an object exists to a caller
   that cannot list the bucket, so `HeadObject` on a *missing* key returns `403 Forbidden`. The
   idempotency check only treated `404` as "absent", so it raised — and only on the path that
   matters, creating a report that does not exist yet. It stayed hidden because earlier runs
   either passed `force=true` (short-circuiting the check) or targeted a week whose report already
   existed, where `GetObject` alone is enough for `HeadObject` to answer `200`.
   **Lesson: a permission check can fail in only one direction and still look fine in testing.**
2. **A green stack with the wrong code inside.** Pointing the builder at the image the API Lambda
   was already running produced a stack that deployed successfully and then failed every
   invocation with `No module named 'app.reports'` — that image predated the feature.
   **Lesson: CloudFormation success says nothing about the contents of a container image.**
3. **DMARC alignment.** Sending `From: …@gmail.com` through SES means SPF and DKIM align to
   `amazonses.com`, not `gmail.com`, so DMARC fails and Gmail files the mail as Spam. SES still
   reports `Delivery`, because SMTP delivery succeeded. **Lesson: delivery and inbox placement
   are different things, and a provider metric only measures the first.** The correct fix is a
   domain identity with published DKIM CNAMEs; unavailable here because no Route 53 zone for the
   domain exists in this account.
4. **Scheduler → SQS, not Lambda.** Because the schedule targets the queue, retries, the DLQ and
   a manual `make report-now` all share one path, and a cold Aurora cannot make the schedule
   itself fail. The visible consequence is that scheduled runs log `trigger=sqs source=schedule`.
5. **Aurora Serverless v2 scaling to zero costs ~18 s on the first request.** Measured repeatedly:
   queue → written was 18 s cold (21:01:48 → 21:02:05) versus 87 ms when the report already
   existed and no database was touched. The builder timeout is 120 s precisely to absorb this.

---

## Reproducing

```bash
make aws-reports-deploy                # build + push the image, stack, mailer code
make report-now WEEK=2026-W42          # one report on demand (FORCE=1 to overwrite)
make aws-reports-status                # schedule, queue depth, bucket contents
make aws-reports-logs                  # tail the builder (FN=mailer for the other)
make aws-reports-get WEEK=2026-W42     # print a built report
```

Unit tests run locally against the compose database, no AWS:

```bash
make test-back      # 45 tests, 16 of them for the weekly report
```
