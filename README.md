# Meetings App

Monorepo with a FastAPI backend (`back/`), a React + shadcn/ui frontend (`front/`) and PostgreSQL,
all started with Docker Compose. See meetings in a week or day calendar, add them (title, time,
description, participants, call link, place), edit and remove them.

## Run everything

```bash
make up          # = cp .env.example .env (first time) + docker compose up --build --wait, then
                 #   docker compose watch: rebuilds backend/frontend when their files change
make start       # the same without watching (returns once the stack is healthy)
make help        # all targets: logs, test, lint, format, clean, aws-*
```

- App: http://localhost:3000 (sign in / sign up; the calendar is at `/home`). Until Cognito is set
  up (see [Sign-in](#sign-in-cognito)), nothing is checked: any valid form opens the calendar and
  everyone is one local user.
- API docs: http://localhost:3000/api/docs (or http://localhost:8000/api/docs directly)

If a host port is already taken, change `DB_PORT`, `BACKEND_PORT` or `FRONTEND_PORT` in `.env`.
`SEED=true` inserts 5 sample participants on first start. `docker compose down -v` wipes the database.

## Layout

```
compose.yaml      # db, backend, frontend
back/             # FastAPI + SQLAlchemy 2 + Alembic
  app/
    main.py       # app, CORS, error handlers
    lambda_handler.py # AWS Lambda entry point (Mangum) + migrate action
    models.py     # User, Meeting (owner_id → users), Participant, meeting_participants
    auth.py       # Cognito ID-token verification, current user
    schemas.py    # Pydantic request/response models
    services/     # business logic
    routers/      # /api/meetings, /api/participants, /api/health
    reports/      # weekly report: weekly.py (CSV from the DB), lambda_handler.py (builder Lambda)
  alembic/        # migrations (run on container start; on AWS via `make aws-backend-migrate`)
  Dockerfile.lambda # AWS Lambda image
  tests/
front/            # Vite + React + TypeScript + Tailwind + shadcn/ui
  src/
    pages/        # LoginPage (/), SignUpPage (/signup), ConfirmPage (/confirm), AuthCallbackPage
                  # (/auth/callback, Google), HomePage (/home, the calendar; needs sign-in)
    components/   # MeetingsCalendar, MeetingFormDialog, DeleteMeetingDialog, ParticipantsMultiSelect
    components/ui # generated shadcn components
    hooks/        # TanStack Query hooks
    lib/calendar.ts # date helpers and the overlap layout for the calendar
    lib/auth.ts   # Cognito sign-in/up, session and token refresh, Google (Hosted UI + PKCE)
    lib/api.ts    # typed fetch wrapper (VITE_API_URL = backend origin, empty = same origin)
  nginx.conf      # serves the SPA, proxies /api to backend
infra/            # CloudFormation: cognito, auth, backend-ecr, backend (Lambda + Aurora), frontend (S3 + CloudFront),
                  # reports.yml (S3 + SQS + Scheduler + 2 Lambdas + SES)
  lambda/         # report_mailer.py — the mailer Lambda, deployed as a zip, not in the backend image
```

## API

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/health` | Liveness + DB check (no sign-in needed) |
| GET | `/api/me` | The signed-in user (created on first request) |
| PATCH | `/api/me` | Update the user's `name` |
| GET | `/api/meetings` | List meetings with participants, by start time |
| GET | `/api/meetings/{id}` | One meeting |
| POST | `/api/meetings` | Create a meeting |
| PUT | `/api/meetings/{id}` | Replace a meeting (same body as POST) |
| DELETE | `/api/meetings/{id}` | Delete a meeting |
| GET | `/api/participants?q=` | List/search participants |
| POST | `/api/participants` | Create a participant (409 on duplicate email) |
| DELETE | `/api/participants/{id}` | Delete a participant |

Everything except `/api/health` needs `Authorization: Bearer <Cognito ID token>`. Meetings are
personal: each belongs to the user who created it (`owner_id`), and other users get 404 for it. The
participant directory is shared. All IDs are UUIDs. A meeting needs a title, `starts_at` and `ends_at` (ISO 8601 with a timezone, end after start)
and at least one of `call_link` or `place`.

## Sign-in (Cognito)

The browser signs in with a Cognito user pool directly: email + password (sign-up sends a 6-digit
code to confirm the email) and, once configured, Google through the Cognito Hosted UI. The API
verifies the ID token's signature, issuer, audience and expiry against the pool's public keys and
stores the user in the `users` table (keyed by the token's `sub`), where extra profile data lives.

```bash
make aws-cognito-deploy   # user pool + app client + Hosted UI domain; prints the lines for .env
make aws-cognito-env      # print them again
```

Paste the printed `COGNITO_*` lines into `.env` and run `make up`. The local backend and frontend
then use the real user pool. With `COGNITO_USER_POOL_ID` empty, auth is off: no token is checked and
every request acts as one local user (`dev@localhost`).

**Google sign-in** (off until configured): create an OAuth client ID (type "Web application") in
Google Cloud with the redirect URI `https://<COGNITO_DOMAIN>/oauth2/idpresponse`, set
`GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in `.env`, then run `make aws-cognito-deploy` again and
copy `COGNITO_GOOGLE_ENABLED=true` into `.env`. On AWS, run `make aws-frontend-publish` to rebuild the
frontend with it. Until then the Google button shows as "coming soon".

On AWS the Lambda has no internet access, so `aws-backend-stack` downloads the pool's JWKS and passes
it in as `COGNITO_JWKS`. Cognito does not rotate user pool signing keys. Meetings created before
accounts existed have no owner, so nobody sees them.

## Local development

Backend (needs a Postgres, e.g. `docker compose up -d db`):

```bash
cd back
uv sync
DATABASE_URL=postgresql+psycopg://meetings:meetings@localhost:5432/meetings uv run alembic upgrade head
DATABASE_URL=postgresql+psycopg://meetings:meetings@localhost:5432/meetings uv run uvicorn app.main:app --reload
```

Frontend (Vite proxies `/api` to `http://localhost:8000`, override with `VITE_API_PROXY`):

```bash
cd front
npm install
npm run dev        # http://localhost:5173
```

## Tests

```bash
# backend: uses a separate database (created once)
docker compose exec db psql -U meetings -c "CREATE DATABASE meetings_test"
cd back && TEST_DATABASE_URL=postgresql+psycopg://meetings:meetings@localhost:5432/meetings_test uv run pytest

# frontend
cd front && npm test
```

## Code style

CI (`.github/workflows/code-style.yml`) runs on every push to `main` and on pull requests:

| Part | Tools | Run locally | Auto-fix |
| --- | --- | --- | --- |
| `back/` | Ruff (lint + format) | `uv run ruff check . && uv run ruff format --check .` | `uv run ruff check --fix . && uv run ruff format .` |
| `front/` | ESLint, Prettier, `tsc` | `npm run lint && npm run format:check && npm run typecheck` | `npm run format` |

Config lives in `back/pyproject.toml` (`[tool.ruff]`), `front/eslint.config.js` and `front/.prettierrc.json`.

## Deploy to AWS (backend on Lambda + Aurora Serverless, frontend on CloudFront)

Everything is deployed to **us-east-1**. CloudFront accepts custom-domain certificates only from that region. Infrastructure is CloudFormation in `infra/`:

- `infra/cognito.yaml`: Cognito user pool (email + password, self sign-up with email code), public app client, Hosted UI domain, and Google as an identity provider when `GOOGLE_CLIENT_ID` is set.
- `infra/backend-ecr.yaml`: ECR repository for the backend's Lambda container image (`back/Dockerfile.lambda`).
- `infra/backend.yaml`: VPC with private subnets, Aurora Serverless v2 PostgreSQL (scales to 0 ACU when idle), and a Lambda function with a public **function URL**, which is the backend URL.
- `infra/frontend.yaml`: private S3 bucket and CloudFront distribution for the SPA on the **flat-rate Free plan** ($0/month, with the WAF web ACL the plan requires), with an optional custom domain.

Every resource carries the tag `PROJECT_NAME=<project>`. It is set in the templates and as a stack tag, and `cert.sh` puts it on the ACM certificate. Some resource types can't be tagged in AWS at all: function URLs, Lambda permissions, the bucket policy, the CloudFront origin access control, Route 53 records and the pricing plan subscription.

```mermaid
flowchart LR
    B[Browser] -->|HTTPS| CF[CloudFront + WAF<br/>Free plan, optional custom domain]
    CF --> S3[(S3<br/>built SPA)]
    B -->|HTTPS, CORS| URL[Lambda function URL]
    URL --> L[Lambda<br/>FastAPI via Mangum<br/>private subnets]
    L -->|:5432| DB[(Aurora Serverless v2<br/>PostgreSQL, private subnets)]
    L -. image .-> ECR[ECR]
```

1. Put credentials into `.env` (an IAM user or role allowed to use CloudFormation, EC2/VPC, Lambda, ECR, RDS, Secrets Manager, S3, CloudFront, WAF, Pricing Plan Manager, ACM, Route 53, IAM and CloudWatch Logs):

   ```
   AWS_ACCESS_KEY_ID=...
   AWS_SECRET_ACCESS_KEY=...
   ```

2. Optionally copy `infra/backend.params.example.env` to `infra/backend.params.env` to override stack parameters (memory, Aurora capacity, seeding, …).
3. Deploy. The first run takes about 15 minutes, mostly waiting for Aurora and CloudFront:

   ```bash
   make aws-deploy   # = aws-cognito-deploy, aws-backend-deploy, then aws-frontend-deploy
   ```

   The steps run in this order:

   1. **Cognito** (`make aws-cognito-deploy`): user pool, app client and Hosted UI domain. Redirect URLs cover localhost and the site's origins. It prints the `.env` lines for local use.
   2. **Backend** (`make aws-backend-deploy`): ECR stack → build and push the Lambda image → backend stack → `aws-backend-migrate` invokes the function with `{"action": "migrate"}` to run Alembic and seeding. It prints the function URL (`https://<id>.lambda-url.us-east-1.on.aws/`).
   3. **Frontend** (`make aws-frontend-deploy`): frontend stack → `npm run build` with `VITE_API_URL=<function URL>` and the `VITE_COGNITO_*` IDs → upload to S3 and invalidate CloudFront → allow the site's origin in the backend's `CORS_ORIGINS` and as a Cognito redirect URL. It prints the site URL.

Other targets: `make aws-backend-outputs`, `aws-backend-status`, `aws-backend-logs`, `aws-backend-health`, `aws-backend-migrate`, `aws-frontend-outputs`, `aws-frontend-publish` (rebuild and upload the frontend only), `aws-destroy`. Use `ARCH=amd64` to build an x86 Lambda instead of Graviton (`arm64`, the default). Use `CLOUDFRONT_PLAN=PAY_AS_YOU_GO` if the account can't subscribe to the Free plan (accounts on the AWS Free Tier are not eligible, and each account gets at most 3 free plans).

`front/.env.production.local` is deliberately not in git: Vite's `.env*.local` files hold
machine-specific build values. Nothing is lost by that, because `aws-frontend-publish` passes the
same values on its own, read from the live stack outputs. To rebuild the frontend against the
`demo-auth` pool from `infra/auth.yaml` instead of the default one, run
`make aws-frontend-publish COGNITO_STACK=demo-auth`.

### Custom domain for the frontend (optional)

By default the site is served on its `*.cloudfront.net` domain. To add a custom domain (default `onetwothree.dobosevych.com`, override with `FRONTEND_DOMAIN=app.example.com`), deploy once and then run:

```bash
make aws-frontend-cert        # 1. request the ACM certificate (free, us-east-1) and set up DNS validation
make aws-frontend-https       # 2. wait until it is issued, attach it to CloudFront, allow it in CORS, set up DNS
make aws-frontend-https-check # 3. curl https://onetwothree.dobosevych.com/
```

- **Domain's zone in Route 53 (same account):** the zone is found automatically. The validation record and alias `A`/`AAAA` records to CloudFront are created for you.
- **Any other DNS provider:** step 1 prints a validation `CNAME` to add there. Step 2 prints the `CNAME <domain> → <id>.cloudfront.net` record to add.

`make aws-frontend-cert-status` and `make aws-frontend-dns` show the records again. Once the certificate is issued, every later `make aws-deploy` keeps the domain. The backend stays on its function URL.

**Cost.** There is no load balancer, NAT gateway or public IPv4 address. Lambda and function URLs fit in the always-free tier for a small app. CloudFront runs on the flat-rate Free plan, which costs $0 with no overage charges and also covers its WAF web ACL (a per-IP rate limit). Requests that WAF blocks don't count toward the plan's allowance. Aurora Serverless v2 has no free tier. With `DbMinCapacity=0` it pauses after 5 idle minutes, and then you pay only for storage (about $0.10/GB-month). While active it costs about $0.12 per ACU-hour. The first request after a pause waits about 15 seconds while Aurora resumes. The DB credentials secret costs $0.40/month. Run `make aws-destroy` when you are done. It keeps a final Aurora snapshot.

On AWS the backend reads `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` and `DB_PASSWORD` instead of `DATABASE_URL`. The password is generated in Secrets Manager and resolved into the function's environment at deploy time, so the VPC needs no internet access. `DB_NULL_POOL=true` closes connections after each request, because idle connections from warm Lambdas would stop Aurora from pausing. Migrations do not run on cold start. `make aws-backend-migrate` runs them, and every `aws-backend-deploy` calls it.

## Weekly meetings report (event driven)

Every Monday at 07:00 Europe/Kyiv a CSV report for the week that just ended is built and emailed.
Nothing polls; each step is triggered by the previous one.

```
EventBridge Scheduler          cron(0 7 ? * MON *), Europe/Kyiv, FlexibleTimeWindow OFF
      │ SendMessage  {"source": "schedule"}
      ▼
SQS meetings-report-requests   maxReceiveCount 3 → meetings-report-requests-dlq
      │ EventSourceMapping, BatchSize 1
      ▼
Lambda meetings-report-builder backend image, CMD app.reports.lambda_handler.handler
      │                        in the VPC (it reads Aurora), S3 over the gateway endpoint
      │ PutObject  reports/<week>.csv
      ▼
S3 meetings-reports-<account>  private, objects expire after 90 days
      │ ObjectCreated, prefix reports/, suffix .csv
      ▼
Lambda meetings-report-mailer  outside the VPC (it needs SES), zip, stdlib + boto3
      │ sesv2:SendEmail, Raw content, CSV attached
      ▼
MAIL_TO
```

The queue sits between the schedule and the builder on purpose: the schedule targets SQS rather
than invoking the function, so retries, the DLQ and a manual `make report-now` all work the same
way, and a cold Aurora cannot make the schedule itself fail.

**What is in the report.** Meetings and total hours for the week, the same two numbers for the
previous week with the delta, the five longest meetings (title, start, duration, participant
count), and a breakdown per person. The schema has no organiser/member tables, so "organiser"
means the owner of the meeting (`meetings.owner_id`) and "members" are its participants.

Week boundaries are Monday 00:00 to the next Monday 00:00 in `REPORT_TIMEZONE`, not UTC.
`build_weekly_report(week)` never decides what "last week" is — the week is always passed in, so
any past week can be rebuilt and the same week always produces the same file,
`reports/<week>.csv` (`report_key(week)`, shared by both Lambdas).

### Deploy

The reports stack reads the VPC, subnets, security group, route table and database from the
backend stack's outputs. The route table and those outputs were added for this feature, so an
existing backend stack has to be updated once:

```bash
make aws-backend-stack KEEP_IMAGE=1    # adds the private route table + network outputs
```

Then set the mail addresses in `.env` (`MAIL_FROM`, `MAIL_TO`, optionally `SES_DOMAIN`) and:

```bash
make aws-reports-deploy                # stack, then the mailer handler zip
make report-now WEEK=2026-W40          # build one week immediately (FORCE=1 to overwrite)
make aws-reports-status                # schedule, queue depth, what is in the bucket
make aws-reports-logs                  # tail the builder (FN=mailer for the other one)
make aws-reports-get WEEK=2026-W40     # print a built report
make aws-reports-destroy               # empty the bucket and delete the stack
```

Three things are worth knowing about this deploy:

- **The builder runs the image the API is already running.** `aws-reports-stack` reads it from
  the deployed backend Lambda rather than from `$(TAG)`, because `TAG` is derived from the working
  tree: with uncommitted changes it names an image nobody pushed, and Lambda then fails the stack
  with *Source image does not exist*. The architecture is read from the same place, so it cannot
  disagree with the image. To use a freshly built image, run `make aws-backend-push` and pass
  `IMAGE_URI=<uri>`.
- **The mailer code is uploaded separately.** `infra/reports.yml` carries only a placeholder for
  it, because inline CloudFormation code is capped at 4 KB and the handler is easier to review as
  a file. `make aws-reports-mailer-code` zips `infra/lambda/report_mailer.py` and uploads it;
  `aws-reports-deploy` runs both steps. CloudFormation restores the placeholder on every stack
  update, so re-run that target (or the whole `aws-reports-deploy`) after changing the stack.
- **SES verification is manual.** With `SES_DOMAIN` set, the stack creates the domain identity;
  `make aws-reports-dkim` then prints the three `CNAME` records to publish in that domain's DNS
  by hand. Until they resolve, the identity stays unverified and SES refuses to send. A new
  account is also in the **SES sandbox**, where every `MAIL_TO` address must be verified
  separately and the daily quota is 200 messages — request production access to lift that.

### Logs

Both functions log one `key=value` line per run, so CloudWatch Logs Insights can group them:

```
fields @timestamp, @message
| filter @message like /report-builder triggered/
| parse @message "trigger=* source=* week=* key=*" as trigger, source, week, key
| sort @timestamp desc
```

`trigger` is the transport (`schedule` for a direct invocation, `sqs`, `manual`) and `source` is
what asked for the report (`schedule`, `manual`), so the Monday runs appear as
`trigger=sqs source=schedule`.

### Idempotency and loops

The builder calls `HeadObject` before writing and skips a week whose report already exists
(`FORCE=1` / `{"force": true}` overrides). So a redelivered SQS message does not write the object
a second time, and therefore does not fire a second email.

The mailer only ever reads: its role has `s3:GetObject` and no `PutObject`, and it writes nothing
back under `reports/`. A write there would match the same notification filter that invoked it and
the function would keep emailing itself.

### Cost

The S3 gateway endpoint, SQS, EventBridge Scheduler and SES all stay inside their free
allowances at this volume (one report a week, a few KB each): the gateway endpoint is free,
SQS gives a million requests a month, Scheduler 14 million invocations, and SES $0.10 per
thousand emails. The report adds no always-on cost — and specifically no NAT gateway, which is
the whole reason the mailer lives outside the VPC.
