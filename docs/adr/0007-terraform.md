# 7. Terraform for the infrastructure, HCP Terraform for the state

Date: 2026-10-31

Status: Accepted

## Context

Labs 4, 5 and 6 each added a CloudFormation template: `infra/auth.yaml` (a Cognito pool),
`infra/reports.yml` (the weekly report) and `infra/ai.yml` (the agenda parser). They worked.
Three things about them had started to cost us:

- **The project already reaches outside AWS.** Google sign-in needs an OAuth client in Google
  Cloud, with the Cognito callback URL in its authorised list. When that URL was missing, the
  symptom was `Error 400: redirect_uri_mismatch` and the fix was a click in a console nobody
  can review. The repository has a GitHub side too: branch protection, the Actions workflow.
  CloudFormation stops at the edge of one AWS account.
- **There is one environment.** Everything is named `meetings-*`, and a second environment would
  mean copying templates and editing names. The playground in Part 1 showed the alternative in
  twenty lines: a `settings` map keyed by `dev`/`stage`/`prod`, one `.tfvars` per environment.
- **The templates had grown workarounds for the tool.** `reports.yml` spells the bucket name out
  by hand instead of referencing the bucket, because the bucket's notification needs the
  mailer's permission and the permission needs the bucket's ARN - a cycle CloudFormation cannot
  break. In Terraform the notification is its own resource and the cycle never forms.

## Decision

**Terraform**, one root module in `infra/`, with the state in **HCP Terraform** and applies
performed there rather than from a laptop.

The three templates became `auth.tf`, `reports.tf` and `ai.tf`. 28 CloudFormation resources
became 43 Terraform ones; the whole difference is two structural things the provider forces:
the S3 bucket's versioning, encryption, lifecycle, ownership, public-access block, policy and
notification are separate resources, and IAM inline policies and managed-policy attachments are
separate from the role.

**The existing resources were adopted, not rebuilt.** Every resource in the three templates got
`DeletionPolicy: Retain`, the templates were deployed once more, and only then were the stacks
deleted - so the stacks disappeared and the resources stayed. `import` blocks then handed them
to Terraform: **38 imported, 4 created, 18 changed, 0 destroyed**, and the plan right after that
says `No changes`. Nobody lost an account or a report. The four that were created fresh are the
three `aws_lambda_permission`s and the `aws_s3_bucket_notification`: a permission holds no data
and CloudFormation had given them generated statement IDs, and the notification is written as a
whole configuration, so re-applying it reproduces exactly what was there. The statements the
deleted stacks left behind were removed by hand afterwards.

**The alternatives, and why they lost:**

- **Staying on CloudFormation.** Free, no state to protect, supported by AWS on launch day for
  new services, and rollback is automatic. It cannot describe the Google OAuth client or the
  GitHub repository, which is where this project's next infrastructure bug will come from.
- **AWS CDK.** Real code, real loops, and it still compiles to CloudFormation - so it inherits
  both the good parts (state is AWS's problem) and the limit (one cloud). It also puts a
  language runtime between the description and the diff: `cdk diff` is further from the API
  calls than `terraform plan` is.
- **OpenTofu.** The same files and commands, an open licence, and a real answer to the BSL
  change. We stay on Terraform because HCP Terraform's free tier gives us remote state, locking
  and runs without hosting anything, and the course uses it. The files are compatible, so this
  is reversible: `TF=tofu make infra-plan` already works, and the Makefile reads the binary from
  `command -v` rather than hard-coding it.

**What stays in CloudFormation:** the VPC, Aurora, the API Lambda, the ECR repository, the
application's Cognito pool and the CloudFront site. They work, nothing outside AWS touches them,
and `infra/data.tf` reads what it needs from the backend stack's outputs with the
`aws_cloudformation_stack` data source. Migrating them is a separate decision with its own risk.

## Consequences

### Who can change the infrastructure, and how

A change to `infra/*.tf` goes: branch → pull request → the plan appears as a check → review →
merge → HCP Terraform applies. That is the only path that is supposed to be used, and the
Makefile is built to keep it that way: it has `make infra-plan`, `make infra-fmt` and
`make infra-output`, and **no `terraform apply` anywhere**. The `aws cloudformation deploy`
targets for the three stacks are gone.

Two roads still exist, as before: GitHub Actions deploys the application, HCP Terraform deploys
the infrastructure. When a change needs both - a new environment variable for a Lambda, say -
the infrastructure goes first, because the application deploy only replaces the image and would
otherwise come up against a function that has no such variable.

Applying from a laptop is still possible and is for emergencies. It is also how the migration
itself was done, because the state did not exist yet.

### Where the secrets end up

- **The Google client secret** is a `sensitive` variable, set in the HCP Terraform workspace,
  never in `terraform.tfvars`. Plans print `(sensitive value)`. It is also in the state, because
  `sensitive = true` hides a value from the plan output, not from the state file. Cognito never
  returns it on read, so the provider would show it as changed on every plan; `ignore_changes`
  on that one key is what makes `No changes` reachable, and rotating the secret means changing
  it in Google Cloud and here and removing that line for one apply.
- **The database password** is new in the state. CloudFormation resolved
  `{{resolve:secretsmanager:...}}` at deploy time and never stored the value; Terraform reads
  the secret with a data source to put it in the builder's environment, so it lands in the state
  file in clear text. That is the single strongest reason the state belongs in HCP Terraform
  rather than on a laptop or in Git: it is encrypted at rest there, access is per-user, and
  every version is kept.
- **The state** also holds every ARN, every policy document and the full configuration of the
  user pool. `.gitignore` keeps `*.tfstate*` out of the repository in all three Terraform
  folders.

### What happens if HCP Terraform is down

Nothing that is already deployed stops: AWS keeps running the Lambdas, the queue and the bucket
regardless. What stops is *changing* the infrastructure - plans and applies queue up, and the
state cannot be read or locked. Three ways out, in increasing order of desperation:

1. **Wait.** Infrastructure changes are rarely the thing that cannot wait an hour.
2. **An application fix instead.** The GitHub Actions pipeline is independent of HCP Terraform,
   so anything that is a code change still ships.
3. **A console change, deliberately.** If an incident genuinely needs an infrastructure change
   now, make it in the console and **write the same change into `infra/*.tf` in the same hour**.
   The next plan will otherwise offer to undo it - which is what drift detection is for, and
   also what makes an undocumented 23:00 fix disappear at the next merge.

The bootstrap is the one piece that must not depend on HCP Terraform, and does not:
`tf-bootstrap/` keeps a local state and holds the IAM OIDC provider plus the role HCP Terraform
assumes. That role carries `PowerUserAccess` - everything except IAM - plus a narrow inline
policy granting 16 IAM actions on `role/meetings-*` and `role/demo-*` only, which is what the
module actually manages. Its trust is pinned to one workspace, `meetings-dev` in
`Default Project`, so no other workspace in the organisation can assume it.

### What we gave up

Automatic rollback. A CloudFormation update that fails puts the stack back; a Terraform apply
that fails stops where it is, with some resources created and some not. The state records what
succeeded, so the next apply continues - but the window where the world is half-changed is real,
and it is the reason to read the plan rather than skim it.

We also took on the state. It is ours to protect, back up and not lose. In exchange, every plan
compares the files with the real world, which CloudFormation only does when asked.
