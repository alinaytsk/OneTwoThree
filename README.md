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
    models.py     # User, Meeting (owner_id → users, agenda + ai_suggestion JSONB), Participant,
                  # meeting_participants
    auth_tokens.py # Cognito ID-token checking (no FastAPI, no DB: the parser reuses it)
    auth.py       # the current user as a FastAPI dependency
    schemas.py    # Pydantic request/response models
    services/     # business logic
    routers/      # /api/meetings (+ /agenda), /api/participants, /api/health
    reports/      # weekly report: weekly.py (CSV from the DB), lambda_handler.py (builder Lambda)
    ai/           # agenda parser: agenda.py (the pure function), agenda_lambda.py (its Lambda),
                  # hello.py (`make llm-hello`)
  alembic/        # migrations (run on container start; on AWS via `make aws-backend-migrate`)
  Dockerfile.lambda # AWS Lambda image
  tests/
front/            # Vite + React + TypeScript + Tailwind + shadcn/ui
  src/
    pages/        # LoginPage (/), SignUpPage (/signup), ConfirmPage (/confirm), AuthCallbackPage
                  # (/auth/callback, Google), HomePage (/home, the calendar; needs sign-in)
    components/   # MeetingsCalendar, MeetingFormDialog, DeleteMeetingDialog, ParticipantsMultiSelect,
                  # PasteAgendaPanel (paste + Parse + Cancel), AgendaFields (the agenda form)
    components/ui # generated shadcn components
    hooks/        # TanStack Query hooks
    lib/calendar.ts # date helpers and the overlap layout for the calendar
    lib/auth.ts   # Cognito sign-in/up, session and token refresh, Google (Hosted UI + PKCE)
    lib/api.ts    # typed fetch wrapper (VITE_API_URL = backend origin, empty = same origin)
    lib/parser.ts # the agenda parser's own URL (VITE_PARSER_URL) and its error codes
    lib/agenda.ts # the agenda draft: values plus which fields are still the model's suggestion
  nginx.conf      # serves the SPA, proxies /api to backend
infra/            # One Terraform root module + the CloudFormation that has not moved
  versions.tf     # providers, the HCP Terraform backend
  variables.tf    # project_name, image_uri, google_client_secret (sensitive), ...
  data.tf         # account id, region, outputs of the backend stack, the database secret
  auth.tf         # Cognito pool, Google provider, app client, managed login   (was auth.yaml)
  reports.tf      # bucket, queues, builder, schedule, mailer, SES identity    (was reports.yml)
  ai.tf           # agenda parser, its function URL, the budget                (was ai.yml)
  outputs.tf      # everything the Makefile and the frontend build read
  cognito.yaml backend-ecr.yaml backend.yaml frontend.yaml   # still CloudFormation
  lambda/         # report_mailer.py — zipped and deployed by Terraform
tf-bootstrap/     # the IAM OIDC provider and the role HCP Terraform assumes (local state)
tf-playground/    # the Part 1 exercise module; disposable
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
| PUT | `/api/meetings/{id}/agenda` | Save the agenda: `items`, `action_items`, and for a parsed one `ai_suggestion` + `model` + `prompt_version` |
| DELETE | `/api/meetings/{id}` | Delete a meeting |
| GET | `/api/participants?q=` | List/search participants |
| POST | `/api/participants` | Create a participant (409 on duplicate email) |
| DELETE | `/api/participants/{id}` | Delete a participant |

Everything except `/api/health` needs `Authorization: Bearer <Cognito ID token>`. Meetings are
personal: each belongs to the user who created it (`owner_id`), and other users get 404 for it. The
participant directory is shared. All IDs are UUIDs. A meeting needs a title, `starts_at` and `ends_at` (ISO 8601 with a timezone, end after start)
and at least one of `call_link` or `place`.

Parsing pasted text is **not** in this table: it is a separate function URL with its own deployment, outside the VPC, which stores nothing — see [Paste an agenda](#paste-an-agenda-claude-on-bedrock).

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

Everything is deployed to **us-east-1**. CloudFront accepts custom-domain certificates only from that region.

Infrastructure lives in `infra/`, in two halves. **Terraform** owns the Cognito pool from Lab 4,
the weekly report and the agenda parser; its state is in HCP Terraform and applies happen there
after a merge, never from a laptop (see [docs/adr/0007-terraform.md](docs/adr/0007-terraform.md)).
**CloudFormation** still owns the rest:

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

    B -->|parse: pasted text + ID token| PURL[Lambda function URL<br/>CORS on the site's origin]
    PURL --> P[Agenda parser Lambda<br/>no VPC, no database]
    P -->|Messages API| BR[Claude on Bedrock<br/>anthropic.claude-opus-5-5]
    P -. same image .-> ECR

    subgraph VPC[VPC, no NAT gateway]
        L
        DB
    end
```

Two paths, on purpose. **Parse** goes browser -> parser function -> Bedrock and comes back as
JSON the form fills itself in from; nothing is stored. **Save** goes browser -> API -> Aurora,
the way every other write does. The parser is outside the VPC because it needs Bedrock and the
Cognito JWKS and needs no database - so the component that reads pasted, untrusted text has no
route to the meetings data. See
[docs/adr/0006-llm-agenda-parsing.md](docs/adr/0006-llm-agenda-parsing.md).

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
same values on its own, read from the live stack outputs. The Lab 4 pool (`demo-users`, with
Google sign-in) is Terraform's now and lives in `infra/auth.tf`; `terraform output
auth_user_pool_id` and `auth_user_pool_client_id` give the values to build against it.

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

## Changing the infrastructure

`infra/` is one Terraform root module. The state is in HCP Terraform (workspace `meetings-dev`,
working directory `infra`), which also runs the applies: a pull request gets a plan as a check,
and a merge to `main` applies it. Nobody runs `terraform apply` from a laptop, and the Makefile
has no target that would.

```bash
make infra-plan      # read what would change. This is the review
make infra-fmt       # terraform fmt + validate, before every commit
make infra-output    # bucket, queues, function names, the parser URL
```

| Who owns what | Where |
| --- | --- |
| Cognito pool from Lab 4, weekly report, agenda parser | Terraform, `infra/*.tf` |
| VPC, Aurora, API Lambda, ECR, the app's Cognito pool, CloudFront site | CloudFormation, `infra/*.yaml` |
| The IAM role HCP Terraform assumes | Terraform, `tf-bootstrap/`, local state, applied by hand |

The two halves meet in `infra/data.tf`, which reads the backend stack's outputs with the
`aws_cloudformation_stack` data source, so the report builder gets the VPC, the subnets and the
database endpoint without anyone copying them between files.

**Credentials.** HCP Terraform has no AWS keys. Each run signs an OIDC token, AWS trusts
`app.terraform.io` through an IAM OIDC provider, and the run exchanges the token for temporary
credentials of one role - the same mechanism GitHub Actions uses. The role is
`terraform-cloud-oidc-role`, its trust is pinned to this one workspace, and it carries
`PowerUserAccess` plus 16 IAM actions limited to `role/meetings-*` and `role/demo-*`.

**Secrets.** `terraform.tfvars` holds non-secret values only. The Google client secret is a
sensitive variable in the workspace. Note that the database password now lands in the state file
(CloudFormation never stored it), which is why the state lives in HCP Terraform and
`*.tfstate*` is in `.gitignore` in every Terraform folder.

## Paste an agenda (Claude on Bedrock)

On the meeting dialog, next to the agenda form, is a box to paste an email or notes into and a
**Parse** button. Four seconds later the form is filled in, every field the model filled carries
a **suggested** mark until you edit it, and **Save** stores the agenda through the API - together
with what the model proposed, so the two can be compared later.

```
Browser  --- POST pasted text + Cognito ID token --->  parser function URL (AuthType NONE)
                                                        |
                                            verifies the ID token itself (JWKS, Lab 4 code)
                                            rejects over 10 000 characters with 413
                                                        |
                                                        v
                                        Claude on Bedrock, tool `record_agenda`
                                        validated with Pydantic, one retry on failure
                                                        |
Browser  <--- agenda JSON + model + prompt_version + usage ---+
   |
   +--- PUT /api/meetings/{id}/agenda --->  API (in the VPC)  --->  Aurora
        agenda + ai_suggestion + model + prompt_version
```

The parser Lambda runs the **same backend image** as the API on a different command
(`app.ai.agenda_lambda.handler`), with **no `VpcConfig`**, no database credentials, and one IAM
action: `bedrock-mantle:CreateInference`. It writes nothing anywhere - the model fills in a
form, a person checks it, and the person saves it.

| Target | What it does |
| --- | --- |
| `make llm-hello` | One Bedrock call through the Anthropic Messages API: answer, `stop_reason`, usage. Run this first - it is where missing model access shows up. |
| `make parse TEXT="..."` | Runs `parse_agenda` locally and prints the JSON and the usage. |
| `make infra-plan` | Plans `infra/`. The parser, its URL and the budget are `infra/ai.tf` now; applies happen in HCP Terraform after a merge. |
| `make parse-live TEXT="..."` | Signs in as `TEST_EMAIL` and parses through the **deployed** Lambda: real tokens, latency and cost. |
| `make aws-ai-logs` | Tails the parser's log group - one JSON line per parse. |
| `make infra-output` | Parser URL, function name, model, budget, and everything else Terraform knows. |

**Model access.** Anthropic models on Bedrock need enabling once per account: Bedrock ->
us-east-1 -> Model catalog -> the model -> request access (a use-case form, then the Marketplace
terms). Until that is done every call answers
`403 permission_error: ... is not available for this account`, which is exactly what
`make llm-hello` prints.

**Settings** (stack parameters, and `PARSER_*` in the environment - nothing is hard-coded):

| Setting | Default | Why it is a setting |
| --- | --- | --- |
| `PARSER_MODEL` | `anthropic.claude-opus-5-5` | `anthropic.claude-haiku-5-5` is ~40x cheaper per token; swapping it is a parameter, not a code change. |
| `PARSER_EFFORT` | `low` | Extraction needs no deep reasoning; low keeps latency and output tokens down. |
| `PARSER_MAX_CHARS` | `10000` | Rejected with 413 **before** the model is called. |
| `PARSER_PRICE_IN_PER_MTOK` / `..._OUT_...` | `4` / `20` | The prices the logged `cost_usd` is computed from; they move with the model. |
| `PARSER_TIMEZONE` | `Europe/Kyiv` | Where "next Tuesday after lunch" is resolved. |
| `AI_BUDGET_USD` | `5` | AWS Budgets alarm, emailed to `MAIL_TO` at 80% actual and 100% forecast. |

**Cost.** One parse is a few tenths of a cent, most of it the fixed system prompt and tool
schema rather than the paste. Every parse logs its own `cost_usd`, so the monthly bill is a
Logs Insights query rather than an estimate:

```
fields @timestamp, @message
| filter @message like /agenda-parse/
| parse @message '"cost_usd":*,' as cost
| stats sum(cost), avg(latency_ms), count() by model, prompt_version
```

**Comparing prompt versions.** Every saved agenda keeps `ai_suggestion` (what the model
proposed), `ai_model` and `ai_prompt_version` next to the agenda the user kept. Grouping the
difference between the two by `ai_prompt_version` is how `agenda-v2` is shown to be better than
`agenda-v1`, on real data, without replaying a single parse.

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
make infra-plan                        # read the plan; HCP Terraform applies it after a merge
make report-now WEEK=2026-W40          # build one week immediately (FORCE=1 to overwrite)
make aws-reports-status                # schedule, queue depth, what is in the bucket
make aws-reports-logs                  # tail the builder (FN=mailer for the other one)
make aws-reports-get WEEK=2026-W40     # print a built report
```

Three things are worth knowing about this deploy:

- **The image is a Terraform variable.** The builder runs the backend image, so that image has
  to contain `app/reports`. `make aws-backend-push` builds and pushes it; `image_uri` in
  `infra/terraform.tfvars` names the tag the builder and the parser run. Point it at an image
  that predates the feature and the apply is green while every run dies on *No module named
  'app.reports'*, so the tag is changed in a pull request like any other infrastructure change.
- **The mailer code is deployed by Terraform.** `infra/reports.tf` zips
  `infra/lambda/report_mailer.py` with the `archive_file` data source and gives the function its
  `source_code_hash`, so the deployed code is whatever is in the repository. The CloudFormation
  template could only carry a 4 KB placeholder, which had to be overwritten by a separate
  `make` target after every stack update; that target is gone.
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
