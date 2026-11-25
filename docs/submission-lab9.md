# Lab 9 — The same system on Google Cloud, and what it would cost

Alina Yatsko · OneTwoThree · 2026-11-23

---

**I took the "no GCP account" route.** The Google Cloud project exists and its APIs are enabled,
but the free trial asks for a prepayment in this country, so there is no open billing account and
nothing in `gcp/` can be applied. Everything below is submitted against that route.

The evidence, before anything else:

```
$ gcloud billing projects describe onetwotree-511013
billingAccountName: ''
billingEnabled: false
name: projects/onetwotree-511013/billingInfo
projectId: onetwotree-511013

$ gcloud billing accounts list
ACCOUNT_ID            NAME                OPEN   MASTER_ACCOUNT_ID
016417-F815C4-0FB76B  My Billing Account  False
```

`OPEN: False` is the whole story: the account was created, the trial was never activated, and
`gcloud iam service-accounts list` on the project returns zero items because a service account
cannot be created without billing either.

## Completion status

| # | What the no-account route asks for | Status |
|---|---|---|
| 1 | `gcp/` Terraform configuration | ✅ 9 `.tf` files, `gcp/` |
| 1 | ADR with the Part 1 service choices | ✅ [`docs/adr/0008-google-cloud-equivalents.md`](adr/0008-google-cloud-equivalents.md) |
| 1 | `terraform init` and `terraform validate` output | ✅ [`docs/gcp/terraform-init-validate.txt`](gcp/terraform-init-validate.txt) |
| 2 | Backend image without the Lambda adapter, run as Cloud Run runs it | ✅ `back/Dockerfile.cloudrun` + `gcp/local-demo/compose.yaml` |
| 2 | The stack running, verified | ✅ [`docs/gcp/cloudrun-local-verification.txt`](gcp/cloudrun-local-verification.txt) — captured 2026-11-23 |
| 2 | Screenshot: frontend loads, one API call reads from the database | ⬜ **to take** — the stack is up again (2026-11-25); <http://localhost:8080> with the browser's network tab on `GET /api/meetings` |
| 3 | Cost table, with the free-tier assumptions | ✅ [`docs/lab9-costs.md`](lab9-costs.md) |
| 4 | Colab notebook, own copy, outputs saved, shared "anyone with the link can view" | ⬜ **to do** — needs a Google account only, no card; the link goes in [`docs/lab9-part4.md`](lab9-part4.md) |
| 4 | Looker Studio public dashboard over the OWID CO₂ dataset | ⬜ **to do** — line chart, geo chart, top-10 bar chart, one control; steps in [`docs/lab9-part4.md`](lab9-part4.md) |
| 4 | Three sentences: Markdown vs image, timings, when to pay for Document AI | ⬜ two of three **after** the notebook runs; the Document AI answer is written in [`docs/lab9-part4.md`](lab9-part4.md) |
| 4 | The prompt for invoice → JSON, written before the first run | ✅ [`docs/lab9-part4.md`](lab9-part4.md) — each rerun is ~3.5 min on the free CPU runtime |
| 4 | Lab 8 mapped onto BigQuery, Dataflow and Looker Studio | ✅ [`docs/lab9-part4.md`](lab9-part4.md) |

## Part 1 — The service choices

Decided row by row in [ADR 0008](adr/0008-google-cloud-equivalents.md), as `keep` / `replace` /
`drop`. The short version:

**Replaced** (moved to Google Cloud): S3 + CloudFront → Firebase Hosting; Lambda + function URL →
Cloud Run; ECR → Artifact Registry; Aurora Serverless v2 → Cloud SQL `db-f1-micro`; Secrets
Manager → Secret Manager; CloudWatch Logs → Cloud Logging; IAM roles → service accounts.

**Kept on AWS**: Cognito sign-in, the weekly report chain (Scheduler, SQS, S3, SES) and the
agenda parser on Bedrock.

**Dropped**: the WAF. CloudFront's Free plan bundled it; Cloud Armor needs a load balancer, which
bills by the hour. That is a real loss and it is recorded as one.

The three required answers:

- **The database.** Cloud SQL `db-f1-micro`, 10 GB SSD, stopped between demos. Firestore would
  make the line $0 and was rejected because the schema is relational *and used relationally* —
  `meeting_participants` is a join table, the week view joins across it, and the weekly report is
  a SQL aggregation. The saving is $9.37 a month against rewriting `app/models.py`, all of
  `app/services/`, four Alembic migrations and `app/reports/weekly.py`. Keeping the database on
  AWS and calling it across clouds was rejected on latency (25–30 ms per round trip, and the API
  opens a connection per request), egress charged on both sides, and the fact that Aurora sits in
  private subnets — so it would mean a public endpoint or a cross-cloud VPN.
- **E-mail.** SES stays, and partly for a security reason: SES authenticates with IAM, so there
  is no long-lived API key anywhere. Moving to SendGrid or Mailgun would *create* the exact class
  of credential Part 0 spends its length warning about. If it moved, the key would live in Secret
  Manager and reach Cloud Run through `value_source.secret_key_ref`, as the database password
  does — never a build argument, never in the SPA.
- **What would not move.** The agenda parser (the trial credit does not cover partner models on
  Vertex AI, so moving a feature that runs on credit starts costing cash), the weekly report (six
  pieces for a weekly job, and Google runs no transactional e-mail service, so a "full" migration
  still ends at SES), and sign-in (Cognito will not export password hashes, so migrating the pool
  costs every user a password reset).

## Part 2 — What is in `gcp/`, and what proves it

`gcp/` is a separate Terraform root module with its own state, so no single plan can touch both
clouds. Nine `.tf` files: providers and state, variables, APIs, IAM, Artifact Registry, Cloud SQL +
Secret Manager, Cloud Run, Firebase Hosting and outputs.

Three details worth pointing at:

1. **The adapter is gone, not merely unused.** `back/app/main.py` no longer imports Mangum — it
   moved to `app/lambda_handler.py`, which already had its own, and `back/serverless.yml` was
   corrected to point there. `back/Dockerfile.cloudrun` then installs an explicit dependency list
   that omits mangum, boto3 and anthropic, so the Cloud Run image *cannot* fall back to the Lambda
   path. The container listens on `$PORT`.
2. **Migrations are a Cloud Run job, not a cold-start step.** `compose.yaml` runs
   `alembic upgrade head` in the container's command; on Cloud Run several instances can start at
   once, and concurrent migrations against one database are a race. `google_cloud_run_v2_job` runs
   the same image with a different command instead.
3. **No code change for Cloud SQL.** `app/config.py` already builds its URL from `DB_*` parts, and
   libpq reads a host beginning with `/` as a socket directory — so `DB_HOST` simply carries
   `/cloudsql/<connection name>` and the application is none the wiser.

The local proof that the image is a Cloud Run image and not a Lambda one:

```bash
cd front && npm run build && cd ..     # with no VITE_API_URL: the SPA calls /api on its own origin
docker compose -f gcp/local-demo/compose.yaml up --build
```

Run on 2026-11-23, with the output in
[`docs/gcp/cloudrun-local-verification.txt`](gcp/cloudrun-local-verification.txt). What it shows:

- `PORT=8080` in the environment, and `uvicorn --port 8080` as PID 1 - the whole Cloud Run
  contract, and the reason no adapter is needed.
- `mangum: absent`, `boto3: absent`, `anthropic: absent` inside the running container. The image
  *cannot* fall back to the Lambda path.
- `migrate` listed by `ps -a` as `Exited (0)` and not by `ps` - a job that ran to completion,
  which is how `google_cloud_run_v2_job` behaves.
- `GET /api/meetings` through the Hosting rewrite returning three rows read from PostgreSQL,
  each with its participants resolved across the `meeting_participants` join table - the join
  that Firestore would not have.

- <http://localhost:8080> — nginx standing in for Firebase Hosting, rewriting `/api/**` exactly as
  `firebase.json` does
- <http://localhost:8081/api/docs> — the API as Cloud Run exposes it, started with `PORT=8080` and
  nothing else

## Part 3 — The cost table

Full version, with every assumption stated before the numbers, in
[`docs/lab9-costs.md`](lab9-costs.md). The totals:

| Profile | AWS | Google Cloud | Cheaper |
| --- | --- | --- | --- |
| Nobody | ≈ $0.30 | ≈ $1.70 | AWS, by $1.40 |
| Class demos, 10 × 2 h | ≈ $1.50 | ≈ $1.91 | AWS, by $0.41 |
| Office hours, 8 h × 22 days | ≈ $10.86 | ≈ $3.55 | **Google Cloud, by $7.31** |
| Busy around the clock | ≈ $44.10 | ≈ $9.37 | **Google Cloud, by $34.73** |

**Which single line decides it:** the database, in all four profiles. Every other line is $0 or a
rounding error — the API never leaves either cloud's free tier at this traffic. Aurora charges for
*use* ($0 at rest, $0.06/h at 0.5 ACU); `db-f1-micro` charges for *existence* ($0.0105/h, flat).
The crossover is around **30 active hours a month**.

**Where the Aurora trap lives on GCP:** not in Cloud SQL, which cannot surprise anyone — it is the
same price every month by construction. It is in **Cloud Run's cold-start knob**. Scaled to zero
the API is free; set `min_instance_count = 1` or allocate CPU always, and billing stops following
requests and starts following the clock: **$61.14 a month**, six times the entire Google Cloud
bill in the busiest profile, for an app that may serve nobody. That is Aurora's trap with the sign
flipped — on AWS a latency fix stops the database pausing, on GCP it stops the container scaling to
zero. `gcp/run.tf` pins both settings the safe way with a comment saying why.

## Part 4 — The demos, without a bill

Written up in [`docs/lab9-part4.md`](lab9-part4.md): what replaces each billed demo, the two
links, the prompt used for invoice → JSON, the three sentences, and Lab 8 mapped onto BigQuery,
Dataflow and Looker Studio.

The substitutions, in one line each: DuckDB over a public dataset instead of BigQuery; Tesseract
and EasyOCR instead of the Vision API; Qwen3-VL 2B through Ollama turning a scanned invoice into
Markdown and then into JSON instead of Document AI; Looker Studio over `owid-co2-data.csv`, which
needs a Google account and no card.

## Clean up

Nothing to clean up on Google Cloud: with no billing account, nothing was ever created. The
project, its enabled APIs and the BigQuery sandbox cost nothing.

Had it been applied, the line that matters is the one `gcp/outputs.tf` prints as
`stop_database_command` — `db-f1-micro` does not pause when idle the way Aurora does, and a
forgotten instance is $7.67 a month for an app nobody opened. Storage is billed while stopped, so
stopping saves about 78%; `terraform destroy` saves the rest.
