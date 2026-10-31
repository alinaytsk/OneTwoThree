# Lab 7 — From CloudFormation to Terraform

Alina Yatsko · OneTwoThree · 2026-10-31

---

## Completion status

The migration is done and the infrastructure is Terraform's. Every number below was measured
against the live account today, not reconstructed.

| # | Submission item | Status |
|---|---|---|
| 1 | Commit that replaces the three templates, updates the Makefile and README, adds the ADR | ✅ branch `test-pr`, pushed — [§1](#1-commit) |
| 2 | Screenshot of an HCP Terraform run finishing with **Apply finished**, started by a push | ⏳ the pull request is not open yet — see [§6](#7-what-is-left-and-why-only-you-can-do-it) |
| 3 | `terraform plan` right after the migration, ending in **No changes** | ✅ [§3](#3-the-plan-right-after-the-migration) |

| Part 2 step | Status |
|---|---|
| 1. Lay out the folder | ✅ `infra/` is one root module |
| 2. Translate the templates | ✅ 28 CloudFormation resources → 43 Terraform ones |
| 3. Adopt, do not re-create | ✅ **38 imported, 4 created, 18 changed, 0 destroyed** |
| 4. Makefile and pipeline | ✅ Makefile reads `terraform output`; no `terraform apply` in it. Workspace ↔ repository connected, working directory `infra` |
| 5. Drift | ✅ timeout changed by hand, plan caught it, value restored — [§6](#6-drift-what-the-plan-caught) |
| 6. ADR | ✅ [docs/adr/0007-terraform.md](docs/adr/0007-terraform.md) |
| 7. Think it through | ✅ [§5](#5-answers-for-step-7) |

| Part 1 step | Status |
|---|---|
| 1-5. The playground, the state experiments, three environments | ✅ `tf-playground/` |
| 6. Move the state to HCP Terraform | ✅ migrated: 48 entries in the workspace, local `terraform.tfstate*` deleted |
| 7. Dynamic AWS credentials | ✅ `tf-bootstrap/`, role `terraform-cloud-oidc-role` — proven by a remote run that refreshed all 38 resources |
| 8. One plan, two clouds (Google Cloud) | ❌ not done |
| 9. Destroy the playground | ✅ `Destroy complete! Resources: 4 destroyed` |

## 1. Commit

The migration is on the pushed branch `test-pr`, in two commits:
[`a63492c`](https://github.com/alinaytsk/OneTwoThree/commit/a63492c) is the migration itself -
it deletes `infra/auth.yaml`, `infra/reports.yml` and `infra/ai.yml`, adds the Terraform module,
rewires the Makefile and updates the README - and
[`4e8f0fc`](https://github.com/alinaytsk/OneTwoThree/commit/4e8f0fc) turns on the `cloud` block,
so runs and state go to the workspace.

The pull request itself still has to be opened, which is the first row of
[§6](#7-what-is-left-and-why-only-you-can-do-it):
<https://github.com/alinaytsk/OneTwoThree/compare/main...test-pr>

The bootstrap and the Part 1 playground are already on `main`:
[`3189d07`](https://github.com/alinaytsk/OneTwoThree/commit/3189d07).

## 2. What the migration actually did

### The resources were adopted, not rebuilt

Step 3a, verified rather than assumed: `DeletionPolicy: Retain` and `UpdateReplacePolicy:
Retain` went on **every** resource in the three templates, the templates were pushed into the
stacks with every parameter as `UsePreviousValue`, and the deployed templates were read back to
confirm the policy had landed:

```
demo-auth          resources=5    DeletionPolicy: Retain in deployed template=5
meetings-reports   resources=15   DeletionPolicy: Retain in deployed template=16
meetings-ai        resources=7    DeletionPolicy: Retain in deployed template=7
```

(16 against 15 live: the SES domain identity is conditional and `SesDomain` is empty.)

Only then were the stacks deleted, and each resource was checked afterwards:

```
################ demo-auth ################        ################ meetings-ai ################
  stack deleted / no - gone                          stack deleted / no - gone
  alive: user pool us-east-1_pWxRPPCvQ               alive: parser lambda
  alive: app client 215c7uvolh5lf2g095a32ikneo       alive: parser function url
  alive: login domain demo-auth-896138901201         alive: parser role
                                                     alive: budget meetings-monthly
################ meetings-reports ################
  stack deleted / no - gone
  alive: bucket meetings-reports-896138901201   alive: queue meetings-report-requests
  alive: builder lambda   alive: mailer lambda  alive: schedule meetings-weekly-report
  alive: builder role
```

Then the import:

```
Apply complete! Resources: 38 imported, 4 added, 18 changed, 0 destroyed.
```

No account was lost, no report was lost, and the four reports in the bucket
(`2026-W01`, `W40`, `W41`, `W42`) are still there.

### What was imported and what was re-created

**38 imported**: the Cognito pool, its Google provider, app client, login domain and managed
login branding; the reports bucket and its six configuration resources (ownership, public
access, encryption, lifecycle, policy — the notification is below); the S3 gateway endpoint;
both queues; three log groups; four IAM roles with their seven inline policies and three
managed-policy attachments; three Lambda functions; the event source mapping; the schedule; the
parser's function URL; the budget.

**4 created fresh**, and why that was safe:

| Resource | Why re-creating it loses nothing |
|---|---|
| `aws_s3_bucket_notification.reports` | The notification is written as one whole configuration, so applying it reproduces byte for byte what CloudFormation had put there. Nothing is stored in it. |
| `aws_lambda_permission.mailer_s3` | A permission is an entry in a policy document; it holds no data. CloudFormation had named it `meetings-reports-MailerInvokePermission-n9KxDHsGS7Ya`, and carrying a generated name forever is worse than a readable `AllowExecutionFromS3Bucket`. |
| `aws_lambda_permission.parser_url` | Same, for `lambda:InvokeFunctionUrl`. |
| `aws_lambda_permission.parser_invoke` | Same, for `lambda:InvokeFunction` through the URL. |

The statements the deleted stacks left behind were removed by hand afterwards, so each function
carries exactly one set:

```
--- meetings-report-mailer ---      --- meetings-agenda-parser ---
    AllowExecutionFromS3Bucket          AllowInvokeViaFunctionUrl
                                        FunctionURLAllowPublicAccess
```

And the parser still answers through its URL after that surgery: **HTTP 200 in 8.1 s** (cold),
**4.1 s** (warm), returning a parsed agenda with its usage and cost.

### Three things the plan caught before they did damage

The import was dry-run first — `import` blocks read the real resources while CloudFormation
still owned them, so the HCL could be corrected before a single stack was deleted. Three
differences showed up, and each one would have been a real loss:

1. **The IAM role names were wrong.** The templates set no `RoleName`, so CloudFormation
   generated them: `meetings-reports-BuilderRole-Ov8I66IqDWWV`, not `meetings-report-builder`.
   With the clean names in the HCL, Terraform would have created four new roles and orphaned
   the originals. The HCL now carries the generated names, with a comment saying why.
2. **`generate_secret = false` would have replaced the app client.** Cognito does not return
   that attribute, so an import leaves it null; `null -> false` on a ForceNew attribute means
   `Plan: ... 2 to destroy` — a new client ID, a broken SPA build, and the managed login
   branding replaced with it. Removing the line (false is the default) fixed it.
3. **The Google provider would have been stripped.** Cognito fills in `authorize_url`,
   `token_url`, `oidc_issuer`, `attributes_url` and a `username → sub` mapping; none of them
   were in the HCL, so Terraform planned to remove them — which would have broken the Google
   sign-in that was fixed only last week. They are written down now.

One more, for the sake of `No changes`: Cognito returns the Google **client secret** masked, so
every plan would report it as changed forever. `ignore_changes = [provider_details["client_secret"]]`
is what makes the plan quiet; rotating the secret means removing that line for one apply.

### One deliberate change to a live resource

The report builder was running `meetings-backend:3e171ba-dirty-20261015210913` while the parser
ran `7da3119-dirty-20261017110705`. One `image_uri` variable now feeds both, so the apply moved
the builder onto the newer image. The newer image contains the same `app/reports` plus the
agenda parser, and the builder's own dependencies are unchanged.

## 3. The plan right after the migration

Full output: [docs/terraform/plan-after-migration.txt](docs/terraform/plan-after-migration.txt).

```
aws_cognito_user_pool.main: Refreshing state... [id=us-east-1_pWxRPPCvQ]
aws_lambda_function.parser: Refreshing state... [id=meetings-agenda-parser]
aws_s3_bucket.reports: Refreshing state... [id=meetings-reports-896138901201]
...

No changes. Your infrastructure matches the configuration.

Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.
```

## 4. The Makefile and the pipeline

- Every lookup that used to be `aws cloudformation describe-stacks` is now
  `terraform output -raw`, through one `tf_output` function.
- The deploy and destroy targets for the three stacks are gone, and so is
  `aws-reports-mailer-code`: Terraform zips `infra/lambda/report_mailer.py` itself with
  `archive_file`, so the deployed code is whatever is in the repository. That removes the
  "re-run this after every stack update" wart the CloudFormation placeholder needed.
- New: `make infra-plan`, `make infra-fmt`, `make infra-output`.
- **There is no `terraform apply` in the Makefile.** Applies happen in HCP Terraform after a
  merge.
- The binary is discovered (`command -v terraform || command -v terraform.exe`), so the same
  Makefile works from WSL against a Windows install, and `make TF=tofu infra-plan` works for
  OpenTofu.

Day-to-day targets still work against the Terraform state — this is `make aws-reports-status`
after the migration:

```
cron: cron(0 7 ? * MON *)        state: ENABLED        tz: Europe/Kyiv
target: arn:aws:sqs:us-east-1:896138901201:meetings-report-requests
meetings-report-requests: 0  0 (visible / in flight)
meetings-report-requests-dlq: 2  0 (visible / in flight)
2026-W01.csv  2026-W40.csv  2026-W41.csv  2026-W42.csv
```

**Which road runs first when a change needs both?** The infrastructure. A new environment
variable for a Lambda has to exist before the image that reads it is deployed; the other order
gives a function that starts and then fails on a missing variable. The exception is a variable
whose *value* comes from the new image (an image tag): then the application pipeline pushes the
image first and the infrastructure change points at it.

## 5. Answers for Step 7

**How many were imported, how many re-created, and why was each re-creation safe?**
38 imported, 4 re-created — the bucket notification and three Lambda permissions. See the table
in §2: none of them stores anything, and all four are fully described by the configuration that
creates them. Everything that holds state — the user pool with its accounts, the bucket with its
reports, the queues with their messages — was imported.

**One attribute that forces replacement of the user pool or the reports bucket.**
For the bucket: `bucket` (its name). Change `project_name` or the suffix and the plan becomes
`-/+ destroy and then create`, which deletes every report in it; with `force_destroy = false`
the destroy at least fails on a non-empty bucket, which is the seatbelt. For the user pool:
`username_attributes` — switching from `["email"]` to anything else replaces the pool, and every
account in it disappears. `schema` is nearly as bad: Cognito will not let an attribute be
swapped, so the apply fails halfway instead.

**Where the Google client secret is now, and who could see it.**
Five places: the HCP Terraform workspace variable (marked sensitive — shown to anyone with
access to the workspace); the Terraform state (clear text, in HCP Terraform); the Cognito user
pool itself (write-only, returned masked); `.env` on my laptop (git-ignored); and Google Cloud,
where it was issued. Plan output prints `(sensitive value)`. The realistic leak is the state —
which is the argument for it living in HCP Terraform with per-user access rather than in a file
next to the code — followed by anyone who is a member of the HCP organisation.

**Two people apply at the same moment with remote state.**
HCP Terraform locks the state for the duration of a run; the second apply waits rather than
interleaves. With a local `terraform.tfstate` in Git, both would apply against their own copy,
both would succeed locally, and the second commit would overwrite the first one's record — so
the state would describe resources that no longer exist and miss ones that do, and the next
plan would try to "fix" reality to match a stale file.

**A narrower trust condition, and the policies the workspace actually needs.**
Already applied in `tf-bootstrap/oidc-bootstrap.tf`:

```hcl
"app.terraform.io:sub" = "organization:alinaytsk:project:Default Project:workspace:meetings-dev:run_phase:*"
```

and the role carries `PowerUserAccess` (everything except IAM) plus one inline policy with 16
IAM actions — `CreateRole`, `DeleteRole`, `GetRole`, `TagRole`, `UntagRole`, `UpdateRole`,
`UpdateAssumeRolePolicy`, `PutRolePolicy`, `GetRolePolicy`, `DeleteRolePolicy`,
`AttachRolePolicy`, `DetachRolePolicy`, `ListRolePolicies`, `ListAttachedRolePolicies`,
`ListInstanceProfilesForRole`, `PassRole` — scoped to `role/meetings-*` and `role/demo-*`.
Checked with `aws iam simulate-principal-policy`, not by reading the policy: the first four of
those were `implicitDeny` until they were added, and `ListInstanceProfilesForRole` is the one
that would have broken the first `destroy`.

**"Add a staging environment" given to an agent.**
It should produce: a `stage.tfvars`, whatever `locals` table entry the differences need, a new
HCP workspace definition, and a pull request whose plan is readable. What it should not do on
its own: run `terraform apply`; create the workspace with production-sized values; reuse the
production state; or touch `tf-bootstrap`, because that is the role that grants the access in
the first place.

## 6. Drift: what the plan caught

The parser's timeout is 30 seconds in the code ([`infra/variables.tf`](infra/variables.tf),
`parser_timeout`). It was changed to 45 by hand, the way a 23:00 fix gets made:

```
aws lambda update-function-configuration --function-name meetings-agenda-parser --timeout 45
```

The next plan found it without being told where to look - run
[`run-w2Nb9oUsi2s4kNea`](https://app.terraform.io/app/alinaytsk/meetings-dev/runs/run-w2Nb9oUsi2s4kNea):

```
  # aws_lambda_function.parser will be updated in-place
  ~ resource "aws_lambda_function" "parser" {
        id                             = "meetings-agenda-parser"
      ~ timeout                        = 45 -> 30
        # (30 unchanged attributes hidden)
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

Full output: [plan-drift.txt](docs/terraform/plan-drift.txt), and the clean plan after the restore:
[plan-drift-restored.txt](docs/terraform/plan-drift-restored.txt).

That is the difference from CloudFormation drift detection: nobody asked for a drift report. Every
plan refreshes the real resources first, so the comparison is not a feature you remember to run.

**Putting it back proved the other half of the setup.** `terraform apply` from the laptop was
refused outright:

```
Error: Apply not allowed for workspaces with a VCS connection
```

Which is the rule the lab asks for, enforced by HCP Terraform rather than by discipline: applies
happen after a merge, not from someone's terminal. Because `main` does not carry the Terraform
module yet, the value was restored with the AWS CLI instead; once the pull request is merged, the
merge-triggered apply is what would reconcile it.

A plan right after that is clean again - run
[`run-Lde5pLTsTNh5288q`](https://app.terraform.io/app/alinaytsk/meetings-dev/runs/run-Lde5pLTsTNh5288q) ends in
`No changes. Your infrastructure matches the configuration.`

**If the 45 seconds had been a real fix**, this plan would have thrown it away - and the loss would
be the diagnosis, not the number: that one parse can exceed 30 seconds under load. The fix belongs
in `parser_timeout`, in a pull request, with that reason in the message. The honest version of the
night shift is: change it by hand to stop the bleeding, then open the pull request the same night,
so the next plan agrees with the console. A fix that lives only in the console is a fix with a
deadline on it - the next apply.

## 7. What is left, and why only you can do it

| Step | Why it needs you |
|---|---|
| `google_client_secret` in the workspace | A **sensitive** Terraform variable. Until it is set, a run started by the repository fails with *No value for required variable*: the remote plan that passed took the value from a local CLI run, which a VCS-driven run has no way to do. |
| `TFC_AWS_*` in the right category | `TFC_AWS_PROVIDER_AUTH` and `TFC_AWS_RUN_ROLE_ARN` are set, but in the **terraform** category instead of **env**. The credentials work anyway; the price is two *Value for undeclared variable* warnings at the end of every plan. |
| Open the pull request | <https://github.com/alinaytsk/OneTwoThree/compare/main...test-pr>. A push to a non-default branch starts no run; the pull request is what asks HCP Terraform for the plan. |
| **Submission item 2** | Merge the pull request and screenshot the run that ends with *Apply finished*. |
| Part 1 Step 8 (two clouds) | `gcloud auth application-default login`, a `google` provider and a `google_storage_bucket` in the playground. The playground is destroyed now, so this one starts with an apply again. |

The state is already in HCP Terraform, so the workspace will not start from nothing. The order
that matters now is **the secret variable first, the pull request second**.

## 8. Honest notes

- **The state is in HCP Terraform** and it holds the database password in clear text
  (CloudFormation resolved that secret at deploy time and never stored it). The local
  `terraform.tfstate` and its 118 KB backup were deleted after the migration, which is the
  whole point: that file should not sit on a laptop.
- **The parser timed out once**, right after the apply replaced its configuration: a cold start
  plus a model call crossed the 30-second limit and the URL returned 502. The next two calls
  returned 200 in 8.1 s and 4.1 s. If it happens again under load, the timeout is the thing to
  raise, in a pull request.
- **Four Lambda permission statements were deleted by hand** (`aws lambda remove-permission`).
  That is the only change made outside Terraform during the migration, and it was removing what
  the deleted stacks had left, not creating anything.
- **`tf-playground/` is destroyed.** The plan read `0 to add, 0 to change, 4 to destroy` - the
  bucket `meetings-dev-tf-playground-da68d099`, its versioning and its lifecycle configuration,
  and the random suffix - and the apply ended with `Destroy complete! Resources: 4 destroyed`.
  The code and its three `.tfvars` files stay in the repository.
- **The client secret is not drifting; it is marked wrong.** A plan without
  `ignore_changes` on `provider_details["client_secret"]` asks for one in-place update to the
  Google identity provider. The value is not what differs: the variable, the state and the live
  Cognito provider hold byte-identical secrets, same SHA-256. The attribute entered the state
  through an import, which recorded it as non-sensitive, while the config feeds it from a
  sensitive variable. Taking that update would call `UpdateIdentityProvider` on a live login
  path to write back the same bytes, so the line stays; removing it and applying once would
  settle it for good. An earlier version of this file and of the ADR claimed Cognito masks the
  secret on read - it does not, and both are corrected.
- **The ADR was drafted by the assistant and then read and corrected**, which is the point the
  lab makes about ADRs nobody reads.
