# Lab 9, Part 3 - the same app on both clouds, and what it costs

AWS prices in `us-east-1`, Google Cloud prices in `us-central1`, on-demand list prices in USD,
excluding tax, 730 hours to the month. The AWS figures continue Lab 4's; the Google Cloud
figures come from the lab's price list and the
[Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator).

Services are those chosen in [ADR 0008](adr/0008-google-cloud-equivalents.md): Firebase Hosting,
Cloud Run, Cloud SQL for PostgreSQL `db-f1-micro`, Artifact Registry, Secret Manager. Sign-in,
the weekly report and the agenda parser stay on AWS in both columns and are left out of both -
they are not part of what moved.

## The assumptions, stated before the numbers

These are the parts a reader has to be able to disagree with.

**Traffic.** During an *active* hour the app serves **500 API requests**, each taking **150 ms**
of CPU at **1 vCPU and 512 MiB**. That is a seminar group clicking around a calendar, not a
load test. The four profiles are Lab 4's:

| Profile | Active hours / month | Requests / month |
| --- | --- | --- |
| 1. Nobody | 0 | 0 |
| 2. Class demos, 10 x 2 h | 20 | 10,000 |
| 3. Office hours, 8 h x 22 days | 176 | 88,000 |
| 4. Busy around the clock | 730 | 365,000 |

**Free tiers counted as available.** Both clouds' perpetual free tiers are applied; neither the
AWS 12-month new-account tier nor the $300 Google trial credit is, because neither survives the
project.

- Cloud Run: 2M requests, 180,000 vCPU-seconds, 360,000 GiB-seconds a month.
- AWS Lambda: 1M requests and 400,000 GB-seconds a month.
- Firebase Hosting free plan: 10 GB stored, 360 MB/day out. CloudFront Free plan: 1 TB out,
  10M requests, WAF included.
- Artifact Registry 0.5 GB, Secret Manager 6 active versions: both inside the free tier for one
  image and one password.

**Storage.** 10 GB SSD on Cloud SQL, because that is the smallest PostgreSQL instance Google
will sell. About 1 GB on Aurora, which bills what is used. This asymmetry is not a measurement -
it is the minimum each cloud charges for.

**Database running time.** The Cloud SQL instance is assumed to run only during active hours and
to be stopped otherwise. This is the optimistic reading and it is flagged again below, because
it depends on a human remembering.

## The table

| Line | AWS | Google Cloud |
| --- | --- | --- |
| Frontend + CDN + HTTPS | CloudFront Free plan, WAF included - **$0** | Firebase Hosting free plan - **$0** |
| API, profile 1 | Lambda, idle - **$0** | Cloud Run, scaled to zero - **$0** |
| API, profiles 2-4 | within the Lambda free tier - **$0** | within the Cloud Run free tier - **$0** |
| Database compute, profile 1 | Aurora paused - **$0** | `db-f1-micro` stopped - **$0** |
| Database compute, profile 2 | 20 h x 0.5 ACU x $0.12 - **$1.20** | 20 h x $0.0105 - **$0.21** |
| Database compute, profile 3 | 176 h x 0.5 ACU x $0.12 - **$10.56** | 176 h x $0.0105 - **$1.85** |
| Database compute, profile 4 | 730 h x 0.5 ACU x $0.12 - **$43.80** | 730 h x $0.0105 - **$7.67** |
| Database storage | ~1 GB at $0.10/GB - **$0.10** | 10 GB SSD at $0.17/GB - **$1.70** |
| Registry, secrets, logs | a few cents | free tier - **$0** |

### Totals

| Profile | AWS | Google Cloud | Cheaper |
| --- | --- | --- | --- |
| 1. Nobody | **≈ $0.30** | **≈ $1.70** | AWS, by $1.40 |
| 2. Class demos | **≈ $1.50** | **≈ $1.91** | AWS, by $0.41 |
| 3. Office hours | **≈ $10.86** | **≈ $3.55** | **Google Cloud, by $7.31** |
| 4. Busy around the clock | **≈ $44.10** | **≈ $9.37** | **Google Cloud, by $34.73** |

And the number that matters more than any of them: **Google Cloud with the database left running
is ≈ $9.37 in every profile, including the one where nobody opens the app.**

## Which line decides it

The database. In all four profiles, every other line is either $0 or a rounding error - the API
never leaves the free tier on either cloud at this traffic, and the frontend is free on both.

The two clouds are priced on opposite assumptions:

- **Aurora Serverless v2 charges for use.** $0 at rest, $0.06/hour at 0.5 ACU. Cheap when idle,
  and it keeps charging as long as something keeps it awake.
- **`db-f1-micro` charges for existence.** $0.0105/hour, flat, whether it serves 500 requests an
  hour or none. Three and a half times cheaper per busy hour, and infinitely more expensive per
  idle one.

So the crossover sits between profile 2 and profile 3. Below roughly **30 active hours a month**
AWS wins; above it Google Cloud wins, and the gap widens fast. At profile 4 Aurora costs almost
five times the Cloud SQL instance.

Storage pulls the other way all the way through: $1.70 against $0.10, because Google's floor is
10 GB and Amazon bills the 1 GB actually used. That $1.60 is what makes AWS cheaper in the two
idle profiles - not the compute.

## Where the Aurora trap lives on the GCP side

Lab 4's lesson was that Aurora Serverless can cost *more* than a fixed instance when something -
a health check, a pooled connection, a monitoring probe - keeps it from pausing. The pricing
model that looks cheapest is the one most sensitive to a mistake.

Google Cloud has the same trap, and it is not in Cloud SQL. `db-f1-micro` has no autoscaler and
no pause, so it cannot surprise anyone: it is the same price every month by construction. The
sensitive service is **Cloud Run**, and the trap is **the knob you turn to kill cold starts**.

Scaled to zero with `cpu_idle = true`, Cloud Run is free at this traffic. Set
`min_instance_count = 1`, or allocate CPU always instead of per-request, and billing stops
following requests and starts following wall-clock time:

```
730 h = 2,628,000 seconds of allocated CPU
  vCPU:   (2,628,000 - 180,000 free) x $0.000024  = $58.75
  memory: (1,314,000 -   360,000 free) x $0.0000025 = $2.39
                                                      -------
                                                      $61.14 / month
```

**$0 becomes $61.14 from one line of Terraform** - six times the entire Google Cloud bill in the
busiest profile, for an app that may serve nobody. That is exactly Aurora's trap with the sign
flipped: on AWS a latency fix stops the database pausing, on GCP a latency fix stops the
container scaling to zero. `gcp/run.tf` therefore pins `min_instance_count = 0` and
`cpu_idle = true`, with a comment saying why.

Two smaller ones, for completeness:

- **The instance nobody stopped.** The $1.70-versus-$9.37 difference above is entirely a human
  remembering to run one command. `gcp/outputs.tf` prints it as `stop_database_command` for that
  reason. This is the most common surprise on a student's bill and it is not a pricing trap at
  all - it is a fixed-price resource behaving exactly as advertised.
- **`disk_autoresize`.** Cloud SQL storage grows automatically and never shrinks, and it is
  billed while the instance is stopped. Turned off in `gcp/database.tf`.

## If the database line had to be $0

Firestore, at this traffic, costs nothing: 50,000 document reads a day free is about 1.5 million
a month, and nothing here approaches that. [ADR 0008](adr/0008-google-cloud-equivalents.md)
explains why we did not take it - the schema is relational and used relationally, so the saving
is $9.37 a month against rewriting `app/models.py`, all of `app/services/`, the four Alembic
migrations and the weekly report's SQL aggregation.

The trade is the same on both clouds: DynamoDB with its 25 GB free against Aurora, Firestore
against Cloud SQL. Neither cloud makes relational data free, and both make it cheap if you give
up relations.
