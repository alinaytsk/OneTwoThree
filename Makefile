# Meetings App — local Docker Compose workflow and AWS deployment (CloudFormation).
# Run `make` or `make help` to list targets.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# .env holds compose settings and AWS credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# optionally AWS_SESSION_TOKEN). Only the keys defined in .env are exported.
-include .env
export $(shell sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env 2>/dev/null)

# ---------------------------------------------------------------------------
# Settings (override on the command line, e.g. `make aws-deploy ARCH=amd64`)
# ---------------------------------------------------------------------------
PROJECT     ?= meetings
# Everything is deployed to us-east-1: CloudFront takes custom-domain certificates only from there.
# (Set here, not in .env; `make … AWS_REGION=…` still overrides it for the backend.)
AWS_REGION  := us-east-1
export AWS_REGION
export AWS_DEFAULT_REGION := $(AWS_REGION)

# arm64 (Graviton, cheaper; native on Apple Silicon) or amd64
ARCH        ?= arm64
# Lambda only picks up a new image when its URI changes, so uncommitted builds get a unique tag.
ifndef TAG
TAG         := $(shell git describe --always --dirty=-dirty-$$(date +%Y%m%d%H%M%S) 2>/dev/null || date +%Y%m%d%H%M%S)
endif

# Terraform owns auth, the weekly report and the agenda parser (infra/*.tf). The VPC, the
# database, the API Lambda, the ECR repository, the application's Cognito pool and the site are
# still CloudFormation; `infra/data.tf` reads the backend stack's outputs.
# `terraform` on Linux and macOS, `terraform.exe` when make runs under WSL or Git Bash against
# a Windows install. Override with `make TF=tofu ...` for OpenTofu.
TF                ?= $(shell command -v terraform 2>/dev/null || command -v terraform.exe 2>/dev/null || echo terraform)
TF_DIR            := infra

BACKEND_ECR_STACK := $(PROJECT)-backend-ecr
BACKEND_STACK     := $(PROJECT)-backend
BACKEND_FUNCTION  := $(PROJECT)-backend
BACKEND_PARAMS    := infra/backend.params.env
FRONTEND_STACK    := $(PROJECT)-frontend
COGNITO_STACK     := $(PROJECT)-cognito
REPORTS_QUEUE     := $(PROJECT)-report-requests
# Every resource gets this tag (in the templates and as a stack tag).
STACK_TAGS        := PROJECT_NAME=$(PROJECT)

# CloudFront flat-rate Free plan ($0/month); PAY_AS_YOU_GO if the account can't subscribe (AWS Free Tier
# accounts, or 3 free plans already in use).
CLOUDFRONT_PLAN   ?= FREE

# Optional custom domain for the frontend (`make aws-frontend-https`); empty = CloudFront domain only.
FRONTEND_DOMAIN   ?= onetwothree.dobosevych.com
CERT_SH           := PROJECT_NAME=$(PROJECT) infra/scripts/cert.sh
# Browser origins the API always allows besides the frontend's (local development).
CORS_LOCAL        ?= http://localhost:3000,http://localhost:5173

# --- Weekly report. The infrastructure is infra/reports.tf; these are only for the CLI. ---
# MAIL_FROM and MAIL_TO belong in .env; the sender has to be verified in SES first.
REPORT_TIMEZONE   ?= Europe/Kyiv
# Optional: creates the SES domain identity, whose DKIM records are published by hand.
SES_DOMAIN        ?=

# --- Agenda parser. The infrastructure is infra/ai.tf; these drive `make parse` locally. ---
PARSER_FUNCTION   := $(PROJECT)-agenda-parser
# Model id on Bedrock. Override to compare: `make parse PARSER_MODEL=anthropic.claude-haiku-5-5 TEXT=...`
PARSER_MODEL      ?= anthropic.claude-opus-5-5
# How that model is called: `mantle` (the Messages API on Bedrock, base model ids) or
# `invoke_model` (the older bedrock-runtime path, the one that takes `us.`-prefixed
# cross-region inference profile ids and pre-5 model versions).
PARSER_BACKEND    ?= mantle
# Empty for a model before the 5 family: they reject output_config outright.
PARSER_EFFORT     ?= low
# Bedrock prices of $(PARSER_MODEL) in USD per million tokens; they go into the logged cost.
# The defaults are Opus 5.5's, read from this account's own Marketplace rate card
# (`aws bedrock list-foundation-model-agreement-offers --model-id anthropic.claude-opus-5-5`),
# which is why PARSER_PRICE_SOURCE says bedrock-rate-card. Change all three together.
PARSER_PRICE_IN   ?= 4
PARSER_PRICE_OUT  ?= 20
PARSER_PRICE_SOURCE ?= bedrock-rate-card
# `make ... PROFILE=sonnet45` runs everything against Claude Sonnet 4.5 through the older
# bedrock-runtime path - the one model this account can call while Opus 5.5 access is pending.
# Its $3/$15 is the published list price, NOT a rate confirmed against this account (the model
# has no Marketplace offer to read, and Cost Explorer only shows actuals a day later), hence
# price_source=public-list in every line it produces.
ifeq ($(PROFILE),sonnet45)
PARSER_BACKEND      := invoke_model
PARSER_MODEL        := us.anthropic.claude-sonnet-4-5-20250929-v1:0
PARSER_EFFORT       :=
PARSER_PRICE_IN     := 3
PARSER_PRICE_OUT    := 15
PARSER_PRICE_SOURCE := public-list
endif
# The five test pastes of `make parse-table`, and where their full answers are written.
PARSE_INPUTS      ?= docs/agenda-tests/inputs.json
PARSE_RESULTS     ?= docs/agenda-tests/results.json

LAMBDA_ARCH  = $(if $(filter arm64,$(ARCH)),arm64,x86_64)
HASH        := \#
COMMA       := ,
# $(shell) does not inherit exported variables in GNU make < 4.4 (macOS ships 3.81),
# so AWS lookups inside $(shell) load .env themselves.
# The CRs are stripped because a .env written on Windows has CRLF line endings, and `.` keeps
# the CR inside the value: the credentials then end in ^M, every aws call fails to authenticate,
# and the error is hidden by the 2>/dev/null below, so lookups just come back empty. make itself
# drops the CR when it parses .env, which is why recipes work while these lookups do not.
LOAD_ENV    := set -a; [ -f .env ] && . <(tr -d '\r' < .env); set +a; export AWS_REGION=$(AWS_REGION) AWS_DEFAULT_REGION=$(AWS_REGION);
AWS_SHELL   := $(LOAD_ENV) aws
# Recursive (=) so they are looked up only when a recipe needs them, after the stacks exist.
stack_output = $(shell $(AWS_SHELL) cloudformation describe-stacks --stack-name $(1) \
                 --query "Stacks[0].Outputs[?OutputKey=='$(2)'].OutputValue" --output text 2>/dev/null)
ECR_URI      = $(call stack_output,$(BACKEND_ECR_STACK),RepositoryUri)
ECR_REGISTRY = $(firstword $(subst /, ,$(ECR_URI)))
BACKEND_PARAMS_ARGS = $(shell [ -f $(BACKEND_PARAMS) ] && grep -v -e '^[[:space:]]*$(HASH)' -e '^[[:space:]]*$$' $(BACKEND_PARAMS))
backend_output  = $(call stack_output,$(BACKEND_STACK),$(1))
frontend_output = $(call stack_output,$(FRONTEND_STACK),$(1))
cognito_output  = $(call stack_output,$(COGNITO_STACK),$(1))
# The reports and the parser are Terraform's now, so their values come from the state rather
# than from a stack. One shell-out per lookup, resolved only when a recipe needs it.
tf_output       = $(shell cd $(TF_DIR) && $(TF) output -raw $(1) 2>/dev/null)
PARSER_URL      = $(call tf_output,parser_url)
API_URL          = $(call backend_output,ApiUrl)
FRONTEND_ORIGINS = $(call frontend_output,SiteOrigins)
CORS_ORIGINS_AWS = $(CORS_LOCAL)$(if $(FRONTEND_ORIGINS),$(COMMA)$(FRONTEND_ORIGINS))
# Cognito may redirect back (Google sign-in) to every origin the API allows.
COGNITO_CALLBACK_URLS = $(subst $(COMMA),/auth/callback$(COMMA),$(CORS_ORIGINS_AWS))/auth/callback
COGNITO_LOGOUT_URLS   = $(subst $(COMMA),/$(COMMA),$(CORS_ORIGINS_AWS))/
COGNITO_POOL_ID   = $(call cognito_output,UserPoolId)
COGNITO_CLIENT    = $(call cognito_output,UserPoolClientId)
FRONTEND_CERT_ARN = $(if $(FRONTEND_DOMAIN),$(shell $(LOAD_ENV) $(CERT_SH) arn $(FRONTEND_DOMAIN) 2>/dev/null))
FRONTEND_ZONE_ID  = $(shell $(LOAD_ENV) $(CERT_SH) zone-id $(FRONTEND_DOMAIN) 2>/dev/null)
# The custom domain is attached once its certificate is issued; until then only the CloudFront domain serves.
FRONTEND_DOMAIN_ARGS = $(if $(FRONTEND_CERT_ARN),CertificateArn=$(FRONTEND_CERT_ARN) DomainName=$(FRONTEND_DOMAIN) HostedZoneId=$(FRONTEND_ZONE_ID))

# A stack whose first create failed is left in ROLLBACK_COMPLETE (holding no resources) and can't be
# updated; delete it so the next deploy creates it again.
define clear_failed_stack
	@if [ "$$(aws cloudformation describe-stacks --stack-name $(1) --query 'Stacks[0].StackStatus' --output text 2>/dev/null)" = ROLLBACK_COMPLETE ]; then \
	  echo "Stack $(1) is in ROLLBACK_COMPLETE after a failed create; deleting it before deploying again"; \
	  aws cloudformation delete-stack --stack-name $(1) && aws cloudformation wait stack-delete-complete --stack-name $(1); \
	fi
endef

TEST_DB_URL := postgresql+psycopg://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@localhost:$(or $(DB_PORT),5432)/meetings_test

##@ Local (Docker Compose)

.env:
	cp .env.example .env
	@echo "Created .env from .env.example — review it (ports, AWS credentials)."

.PHONY: up
up: start ## Start the stack, then rebuild backend/frontend whenever their files change (Ctrl+C stops watching)
	@echo "Watching back/ and front/ for changes — Ctrl+C stops watching, containers keep running."
	docker compose watch --no-up

.PHONY: start
start: .env ## Build and start db, backend and frontend in the background, without watching
	docker compose up -d --build --wait
	@echo "App: http://localhost:$(or $(FRONTEND_PORT),3000)   API docs: http://localhost:$(or $(FRONTEND_PORT),3000)/api/docs"

.PHONY: down
down: ## Stop all containers (data is kept)
	docker compose down

.PHONY: clean
clean: ## Stop containers and delete the database volume
	docker compose down -v --remove-orphans

.PHONY: restart
restart: down start ## Restart the stack

.PHONY: logs
logs: ## Follow logs of all services (SERVICE=backend to narrow)
	docker compose logs -f $(SERVICE)

.PHONY: ps
ps: ## Show container status
	docker compose ps

##@ Quality

.PHONY: test
test: test-back test-front ## Run all tests

.PHONY: test-back
test-back: .env ## Backend tests (starts the db container, creates meetings_test)
	docker compose up -d --wait db
	docker compose exec -T db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -tAc \
	  "SELECT 1 FROM pg_database WHERE datname = 'meetings_test'" | grep -q 1 || \
	  docker compose exec -T db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c "CREATE DATABASE meetings_test"
	cd back && TEST_DATABASE_URL=$(TEST_DB_URL) uv run pytest -q

.PHONY: test-front
test-front: ## Frontend tests
	cd front && npm test

.PHONY: lint
lint: ## Code style checks (same as CI)
	cd back && uv run ruff check . && uv run ruff format --check .
	cd front && npm run lint && npm run format:check && npm run typecheck
	uvx cfn-lint infra/*.yaml infra/*.yml

.PHONY: format
format: ## Auto-format backend and frontend
	cd back && uv run ruff check --fix . && uv run ruff format .
	cd front && npm run format

##@ AWS backend (Lambda + Aurora Serverless v2 via CloudFormation)

.PHONY: aws-check
aws-check: ## Verify AWS credentials from .env work
	@aws sts get-caller-identity --query '[Account, Arn]' --output text \
	  || { echo "AWS credentials missing/invalid: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in .env"; exit 1; }

.PHONY: aws-backend-deploy
aws-backend-deploy: aws-check aws-backend-ecr aws-backend-push aws-backend-stack aws-backend-migrate ## Deploy backend: ECR, image, Aurora, Lambda + function URL, migrations
	@echo
	@echo "API:      $(API_URL)"
	@echo "API docs: $(call backend_output,ApiDocsUrl)"

.PHONY: aws-backend-ecr
aws-backend-ecr: ## Create/update the ECR repository stack
	$(call clear_failed_stack,$(BACKEND_ECR_STACK))
	aws cloudformation deploy --stack-name $(BACKEND_ECR_STACK) --template-file infra/backend-ecr.yaml \
	  --parameter-overrides ProjectName=$(PROJECT) --tags $(STACK_TAGS) --no-fail-on-empty-changeset

.PHONY: aws-backend-login
aws-backend-login: ## Log Docker in to ECR
	@test -n "$(ECR_URI)" || { echo "ECR repository not found: run \`make aws-backend-ecr\` first (and check AWS credentials in .env)"; exit 1; }
	aws ecr get-login-password | docker login --username AWS --password-stdin $(ECR_REGISTRY)

.PHONY: aws-backend-push
aws-backend-push: aws-backend-login ## Build the Lambda image for linux/$(ARCH) and push it with tag $(TAG)
	@# Building for an architecture the daemon cannot emulate fails deep inside the build with
	@# "exec /bin/sh: exec format error", which says nothing about the cause. Check up front.
	@docker buildx ls | grep -q "linux/$(ARCH)" || { \
	  echo "This Docker cannot build linux/$(ARCH): no emulation registered for it."; \
	  echo "Register it once per boot:  docker run --privileged --rm tonistiigi/binfmt --install $(ARCH)"; \
	  echo "Or build natively instead:  make $@ ARCH=$(if $(filter arm64,$(ARCH)),amd64,arm64)"; exit 1; }
	docker buildx build --platform linux/$(ARCH) --provenance=false -f back/Dockerfile.lambda \
	  -t $(ECR_URI):$(TAG) -t $(ECR_URI):latest --push back

.PHONY: aws-backend-stack
aws-backend-stack: ## Create/update the backend stack (VPC, Aurora, Lambda) with image tag $(TAG); KEEP_IMAGE=1 keeps the current image
	$(call clear_failed_stack,$(BACKEND_STACK))
	@test -n "$(ECR_URI)" || { echo "ECR repository not found: run \`make aws-backend-ecr\` first (and check AWS credentials in .env)"; exit 1; }
	@test -n "$(COGNITO_POOL_ID)" || { echo "Cognito not deployed: run \`make aws-cognito-deploy\` first"; exit 1; }
	@# The function has no internet route, so the pool's signing keys are passed in with the stack.
	jwks=$$(curl -fsS "$(call cognito_output,Issuer)/.well-known/jwks.json") && \
	aws cloudformation deploy --stack-name $(BACKEND_STACK) --template-file infra/backend.yaml \
	  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --tags $(STACK_TAGS) \
	  --parameter-overrides ProjectName=$(PROJECT) $(if $(KEEP_IMAGE),,ImageUri=$(ECR_URI):$(TAG)) \
	    Architecture=$(LAMBDA_ARCH) "CorsOrigins=$(CORS_ORIGINS_AWS)" \
	    CognitoUserPoolId=$(COGNITO_POOL_ID) CognitoClientId=$(COGNITO_CLIENT) "CognitoJwks=$$jwks" \
	    $(BACKEND_PARAMS_ARGS)

.PHONY: aws-backend-migrate
aws-backend-migrate: ## Run Alembic migrations (and seeding) inside the Lambda
	@resp=$$(mktemp); \
	err=$$(aws lambda invoke --function-name $(BACKEND_FUNCTION) --cli-binary-format raw-in-base64-out \
	  --payload '{"action": "migrate"}' --cli-read-timeout 0 --query FunctionError --output text "$$resp"); \
	echo "Migrations: $$(cat "$$resp")"; rm -f "$$resp"; \
	[ "$$err" = None ] || { echo "Migration failed ($$err): make aws-backend-logs"; exit 1; }

.PHONY: aws-backend-outputs
aws-backend-outputs: ## Show backend stack outputs (API URL, DB endpoint, ...)
	@aws cloudformation describe-stacks --stack-name $(BACKEND_STACK) \
	  --query "Stacks[0].Outputs[].[OutputKey, OutputValue]" --output table

.PHONY: aws-backend-status
aws-backend-status: ## Show Lambda and Aurora status
	@aws lambda get-function-configuration --function-name $(BACKEND_FUNCTION) \
	  --query "{state:State, lastUpdate:LastUpdateStatus, image:CodeSha256, memory:MemorySize, timeout:Timeout}" --output yaml
	@aws rds describe-db-clusters --db-cluster-identifier $(PROJECT)-db \
	  --query "DBClusters[0].{status:Status, capacity:ServerlessV2ScalingConfiguration}" --output yaml

.PHONY: aws-backend-logs
aws-backend-logs: ## Tail backend logs from CloudWatch
	aws logs tail /aws/lambda/$(BACKEND_FUNCTION) --follow --since 30m

.PHONY: aws-backend-health
aws-backend-health: ## Call /api/health on the function URL (the first call after a pause wakes Aurora, ~15 s)
	curl -fsS --max-time 60 $(API_URL)api/health && echo

.PHONY: aws-backend-destroy
aws-backend-destroy: aws-check ## Delete backend stacks (a final Aurora snapshot is kept)
	@read -p "Delete stacks $(BACKEND_STACK) and $(BACKEND_ECR_STACK) in $(AWS_REGION)? [y/N] " ok && [ "$$ok" = y ]
	aws cloudformation delete-stack --stack-name $(BACKEND_STACK)
	aws cloudformation wait stack-delete-complete --stack-name $(BACKEND_STACK)
	aws cloudformation delete-stack --stack-name $(BACKEND_ECR_STACK)
	aws cloudformation wait stack-delete-complete --stack-name $(BACKEND_ECR_STACK)
	@echo "Done. Remove the final snapshot with: aws rds describe-db-cluster-snapshots --snapshot-type manual"

##@ AWS frontend (S3 + CloudFront on the flat-rate Free plan, built with the backend URL)

.PHONY: aws-frontend-deploy
aws-frontend-deploy: aws-check aws-frontend-stack aws-frontend-publish aws-frontend-cors ## Deploy frontend: stack, build with the API URL, upload, allow its origin in the API and Cognito
	@echo
	@echo "Site: $(call frontend_output,SiteUrl)"

.PHONY: aws-frontend-stack
aws-frontend-stack: ## Create/update the frontend stack (S3, CloudFront + WAF on the Free plan, custom domain once its certificate is issued)
	$(call clear_failed_stack,$(FRONTEND_STACK))
	aws cloudformation deploy --stack-name $(FRONTEND_STACK) --template-file infra/frontend.yaml \
	  --no-fail-on-empty-changeset --tags $(STACK_TAGS) \
	  --parameter-overrides ProjectName=$(PROJECT) PricingPlan=$(CLOUDFRONT_PLAN) \
	    $(or $(FRONTEND_DOMAIN_ARGS),CertificateArn= DomainName= HostedZoneId=)

.PHONY: aws-frontend-publish
aws-frontend-publish: ## Build the SPA with VITE_API_URL=<function URL>, upload it, invalidate CloudFront
	@# Vite fills import.meta.env from .env files only, so the build values are written to
	@# front/.env.production.local (git-ignored); passing them on the command line is ignored.
	@api="$(API_URL)"; bucket="$(call frontend_output,BucketName)"; dist="$(call frontend_output,DistributionId)"; \
	[ -n "$$api" ] || { echo "Backend not deployed: run \`make aws-backend-deploy\` first"; exit 1; }; \
	[ -n "$$bucket" ] || { echo "Frontend stack not found: run \`make aws-frontend-stack\` first"; exit 1; }; \
	[ -n "$(COGNITO_POOL_ID)" ] || { echo "Cognito not deployed: run \`make aws-cognito-deploy\` first"; exit 1; }; \
	echo "Building frontend with VITE_API_URL=$$api" && \
	printf '%s\n' \
	  "VITE_API_URL=$$api" \
	  "VITE_PARSER_URL=$(PARSER_URL)" \
	  "VITE_COGNITO_REGION=$(AWS_REGION)" \
	  "VITE_COGNITO_USER_POOL_ID=$(COGNITO_POOL_ID)" \
	  "VITE_COGNITO_CLIENT_ID=$(COGNITO_CLIENT)" \
	  "VITE_COGNITO_DOMAIN=$(call cognito_output,HostedUiDomain)" \
	  "VITE_COGNITO_GOOGLE=$(call cognito_output,GoogleEnabled)" > front/.env.production.local && \
	(cd front && npm ci --no-audit --no-fund && npm run build) && \
	aws s3 sync front/dist "s3://$$bucket" --delete --exclude index.html \
	  --cache-control "public,max-age=31536000,immutable" && \
	aws s3 cp front/dist/index.html "s3://$$bucket/index.html" --cache-control "no-cache" && \
	aws cloudfront create-invalidation --distribution-id "$$dist" --paths "/*" \
	  --query "Invalidation.Status" --output text

.PHONY: aws-frontend-cors
aws-frontend-cors: ## Allow the frontend's origins in the backend's CORS settings and as Cognito redirect URLs (keeps the current image)
	@$(MAKE) --no-print-directory aws-backend-stack KEEP_IMAGE=1
	@$(MAKE) --no-print-directory aws-cognito-stack

.PHONY: aws-frontend-outputs
aws-frontend-outputs: ## Show frontend stack outputs (site URL, bucket, distribution)
	@aws cloudformation describe-stacks --stack-name $(FRONTEND_STACK) \
	  --query "Stacks[0].Outputs[].[OutputKey, OutputValue]" --output table

.PHONY: aws-frontend-destroy
aws-frontend-destroy: aws-check ## Empty the bucket and delete the frontend stack
	@read -p "Delete stack $(FRONTEND_STACK) in $(AWS_REGION)? [y/N] " ok && [ "$$ok" = y ]
	@bucket="$(call frontend_output,BucketName)"; [ -z "$$bucket" ] || aws s3 rm "s3://$$bucket" --recursive --quiet
	aws cloudformation delete-stack --stack-name $(FRONTEND_STACK)
	aws cloudformation wait stack-delete-complete --stack-name $(FRONTEND_STACK)

##@ AWS frontend custom domain (FRONTEND_DOMAIN, optional)

.PHONY: aws-frontend-cert
aws-frontend-cert: aws-check ## Request (or reuse) the ACM certificate for FRONTEND_DOMAIN (us-east-1) and set up DNS validation
	@$(CERT_SH) request $(FRONTEND_DOMAIN)

.PHONY: aws-frontend-cert-status
aws-frontend-cert-status: ## Show the certificate status and its DNS validation record
	@$(CERT_SH) status $(FRONTEND_DOMAIN)

.PHONY: aws-frontend-https
aws-frontend-https: aws-frontend-cert ## Attach FRONTEND_DOMAIN: wait for the certificate, add it to CloudFront, update CORS, set up DNS
	@$(CERT_SH) wait $(FRONTEND_DOMAIN)
	@$(MAKE) --no-print-directory aws-frontend-stack
	@$(MAKE) --no-print-directory aws-frontend-cors
	@$(MAKE) --no-print-directory aws-frontend-dns

.PHONY: aws-frontend-dns
aws-frontend-dns: ## Show the DNS record that points FRONTEND_DOMAIN at CloudFront
	@if [ -n "$(FRONTEND_ZONE_ID)" ]; then \
	  echo "Route 53 alias $(FRONTEND_DOMAIN) -> CloudFront is managed by stack $(FRONTEND_STACK) (zone $(FRONTEND_ZONE_ID))."; \
	else \
	  echo "Add this record at the DNS provider of $(FRONTEND_DOMAIN):"; echo; \
	  echo "  Type:  CNAME"; echo "  Name:  $(FRONTEND_DOMAIN)"; \
	  echo "  Value: $(call frontend_output,DistributionDomain)"; \
	fi
	@echo; echo "Site: $(call frontend_output,SiteUrl)   (check: make aws-frontend-https-check)"

.PHONY: aws-frontend-https-check
aws-frontend-https-check: ## Check that https://FRONTEND_DOMAIN answers
	@echo "DNS: $$(dig +short $(FRONTEND_DOMAIN) | tr '\n' ' ')"
	curl -fsS -o /dev/null -w "%{http_code} %{url_effective}\n" https://$(FRONTEND_DOMAIN)/

##@ AWS auth (Cognito user pool; Google sign-in once GOOGLE_CLIENT_ID/SECRET are set in .env)

.PHONY: aws-cognito-deploy
aws-cognito-deploy: aws-check aws-cognito-stack aws-cognito-env ## Deploy Cognito, then print the lines to add to .env
	@echo "Then: \`make up\` for local sign-in; on AWS \`make aws-deploy\` (or aws-backend-stack KEEP_IMAGE=1 + aws-frontend-publish)."

.PHONY: aws-cognito-stack
aws-cognito-stack: ## Create/update the Cognito stack (redirect URLs = local origins + the site's)
	$(call clear_failed_stack,$(COGNITO_STACK))
	@# Not echoed: the command line would show the Google client secret.
	@echo "Deploying $(COGNITO_STACK) (Google sign-in: $(if $(GOOGLE_CLIENT_ID),on,off))"
	@aws cloudformation deploy --stack-name $(COGNITO_STACK) --template-file infra/cognito.yaml \
	  --no-fail-on-empty-changeset --tags $(STACK_TAGS) \
	  --parameter-overrides ProjectName=$(PROJECT) "CallbackUrls=$(COGNITO_CALLBACK_URLS)" \
	    "LogoutUrls=$(COGNITO_LOGOUT_URLS)" "GoogleClientId=$(GOOGLE_CLIENT_ID)" \
	    "GoogleClientSecret=$(GOOGLE_CLIENT_SECRET)"

.PHONY: aws-cognito-env
aws-cognito-env: ## Print the .env lines for the deployed user pool (replace the empty COGNITO_* ones)
	@test -n "$(COGNITO_POOL_ID)" || { echo "Cognito stack not found: run \`make aws-cognito-deploy\` first"; exit 1; }
	@echo
	@echo "Add to .env (replacing the empty COGNITO_* lines):"
	@echo
	@echo "COGNITO_REGION=$(AWS_REGION)"
	@echo "COGNITO_USER_POOL_ID=$(COGNITO_POOL_ID)"
	@echo "COGNITO_CLIENT_ID=$(COGNITO_CLIENT)"
	@echo "COGNITO_DOMAIN=$(call cognito_output,HostedUiDomain)"
	@echo "COGNITO_GOOGLE_ENABLED=$(call cognito_output,GoogleEnabled)"
	@echo

.PHONY: aws-cognito-outputs
aws-cognito-outputs: ## Show Cognito stack outputs (pool, client, Hosted UI domain)
	@aws cloudformation describe-stacks --stack-name $(COGNITO_STACK) \
	  --query "Stacks[0].Outputs[].[OutputKey, OutputValue]" --output table

.PHONY: aws-cognito-destroy
aws-cognito-destroy: aws-check ## Delete the Cognito stack — ALL user accounts are deleted with it
	@read -p "Delete stack $(COGNITO_STACK) and every user account in it? [y/N] " ok && [ "$$ok" = y ]
	aws cloudformation delete-stack --stack-name $(COGNITO_STACK)
	aws cloudformation wait stack-delete-complete --stack-name $(COGNITO_STACK)

##@ Weekly report (Terraform: infra/reports.tf)

.PHONY: report-now
report-now: ## Build one week's report immediately: make report-now WEEK=2026-W40 [FORCE=1]
	@test -n "$(WEEK)" || { echo "Usage: make report-now WEEK=2026-W40 [FORCE=1]   (this week: $$(date +%G-W%V))"; exit 1; }
	@url="$(call tf_output,report_requests_queue_url)"; \
	[ -n "$$url" ] || url=$$(aws sqs get-queue-url --queue-name $(REPORTS_QUEUE) --query QueueUrl --output text); \
	[ -n "$$url" ] || { echo "Queue $(REPORTS_QUEUE) not found"; exit 1; }; \
	body='{"week": "$(WEEK)", "source": "manual"$(if $(FORCE),$(COMMA) "force": true)}'; \
	echo "aws sqs send-message --queue-url $$url --message-body '$$body'"; \
	aws sqs send-message --queue-url "$$url" --message-body "$$body" --query MessageId --output text
	@echo "Queued. Watch it: make aws-reports-logs   Fetch it: make aws-reports-get WEEK=$(WEEK)"

.PHONY: aws-reports-get
aws-reports-get: ## Download a built report: make aws-reports-get WEEK=2026-W40
	@test -n "$(WEEK)" || { echo "Usage: make aws-reports-get WEEK=2026-W40"; exit 1; }
	aws s3 cp "s3://$(call tf_output,reports_bucket_name)/reports/$(WEEK).csv" -

.PHONY: aws-reports-logs
aws-reports-logs: ## Tail both report Lambdas (FN=builder or FN=mailer for one of them)
	aws logs tail /aws/lambda/$(PROJECT)-report-$(or $(FN),builder) --follow --since 30m

.PHONY: aws-reports-status
aws-reports-status: ## Show the schedule, what is in the queues and the reports in the bucket
	@aws scheduler get-schedule --name $(call tf_output,schedule_name) \
	  --query "{state:State, cron:ScheduleExpression, tz:ScheduleExpressionTimezone, target:Target.Arn}" --output yaml
	@for q in $(REPORTS_QUEUE) $(REPORTS_QUEUE)-dlq; do \
	  url=$$(aws sqs get-queue-url --queue-name $$q --query QueueUrl --output text 2>/dev/null) || continue; \
	  echo "$$q: $$(aws sqs get-queue-attributes --queue-url $$url \
	    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
	    --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' --output text) (visible / in flight)"; \
	done
	@aws s3 ls "s3://$(call tf_output,reports_bucket_name)/reports/" || true

.PHONY: aws-reports-dkim
aws-reports-dkim: ## Print the DKIM CNAME records to publish for SES_DOMAIN
	@test -n "$(SES_DOMAIN)" || { echo "Set SES_DOMAIN in .env (or verify the sender address by hand in SES)"; exit 1; }
	@echo "Publish these three CNAMEs in the DNS of $(SES_DOMAIN), then wait for Status=SUCCESS:"
	@aws sesv2 get-email-identity --email-identity $(SES_DOMAIN) \
	  --query "DkimAttributes.Tokens" --output text | tr '\t' '\n' | \
	  while read -r t; do echo "  $$t._domainkey.$(SES_DOMAIN).  CNAME  $$t.dkim.amazonses.com."; done

##@ AI agenda parser (Claude on Bedrock + a Lambda outside the VPC)

# What `make llm-hello` / `make parse` put in the environment, so a local run and the deployed
# Lambda read exactly the same settings (back/app/config.py).
PARSER_ENV = PARSER_MODEL=$(PARSER_MODEL) PARSER_BACKEND=$(PARSER_BACKEND) PARSER_EFFORT=$(PARSER_EFFORT) BEDROCK_REGION=$(AWS_REGION) PARSER_TIMEZONE=$(REPORT_TIMEZONE) PARSER_PRICE_IN_PER_MTOK=$(PARSER_PRICE_IN) PARSER_PRICE_OUT_PER_MTOK=$(PARSER_PRICE_OUT) PARSER_PRICE_SOURCE=$(PARSER_PRICE_SOURCE)

.PHONY: llm-hello
llm-hello: ## One Bedrock call through the Anthropic Messages API: prints answer, stop_reason, usage
	cd back && $(PARSER_ENV) uv run python -m app.ai.hello $(if $(PROMPT),"$(PROMPT)",)

.PHONY: parse
parse: ## Parse pasted text locally, without the Lambda: make parse TEXT="..."
	@test -n "$(TEXT)" || { echo 'Usage: make parse TEXT="Sprint planning on Tuesday 15:00 ..."'; exit 1; }
	cd back && $(PARSER_ENV) uv run python -m app.ai.agenda "$(TEXT)"

.PHONY: aws-ai-token
aws-ai-token: ## Print a Cognito ID token for TEST_EMAIL/TEST_PASSWORD (what parse-live signs in with)
	@test -n "$(TEST_EMAIL)" -a -n "$(TEST_PASSWORD)" || { echo "Set TEST_EMAIL and TEST_PASSWORD in .env"; exit 1; }
	@aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH \
	  --client-id $(COGNITO_CLIENT) \
	  --auth-parameters USERNAME=$(TEST_EMAIL),PASSWORD=$(TEST_PASSWORD) \
	  --query AuthenticationResult.IdToken --output text

.PHONY: parse-live
parse-live: ## Parse through the DEPLOYED Lambda: make parse-live TEXT="..." (real tokens, latency, cost)
	@test -n "$(TEXT)" || { echo 'Usage: make parse-live TEXT="..."'; exit 1; }
	@url="$(PARSER_URL)"; [ -n "$$url" ] && [ "$$url" != None ] || \
	  { echo "Parser stack not found: run 'make aws-ai-deploy'"; exit 1; }; \
	  token=$$($(MAKE) -s aws-ai-token) || exit 1; \
	  python3 -c 'import json, sys; print(json.dumps({"text": sys.argv[1]}))' "$(TEXT)" | \
	  curl -sS -X POST "$$url" -H "Authorization: Bearer $$token" \
	    -H 'Content-Type: application/json' --data-binary @- \
	    -w 'HTTP %{http_code} in %{time_total}s'

.PHONY: parse-table
parse-table: ## Run every input in $(PARSE_INPUTS) through the deployed Lambda and print the results table
	@url="$(PARSER_URL)"; [ -n "$$url" ] && [ "$$url" != None ] || \
	  { echo "Parser stack not found: run 'make aws-ai-deploy'"; exit 1; }; \
	  token=$$($(MAKE) -s aws-ai-token) || exit 1; \
	  python3 infra/scripts/parse_table.py --url "$$url" --token "$$token" \
	    --inputs $(PARSE_INPUTS) --out $(PARSE_RESULTS)

.PHONY: aws-ai-logs
aws-ai-logs: ## Tail the parser's logs (one JSON line per parse)
	aws logs tail /aws/lambda/$(PARSER_FUNCTION) --follow --since 30m

.PHONY: infra-plan
infra-plan: ## Plan the Terraform in $(TF_DIR). Read it; applies happen in HCP Terraform after a merge
	cd $(TF_DIR) && $(TF) plan

.PHONY: infra-fmt
infra-fmt: ## Format and validate the Terraform
	cd $(TF_DIR) && $(TF) fmt && $(TF) validate

.PHONY: infra-output
infra-output: ## Show every Terraform output (bucket, queues, functions, parser URL, ...)
	cd $(TF_DIR) && $(TF) output

##@ AWS (all parts)

.PHONY: aws-deploy
aws-deploy: aws-cognito-deploy aws-backend-deploy aws-frontend-deploy ## Deploy everything: Cognito, backend, then the frontend built with their IDs and URL

.PHONY: aws-destroy
aws-destroy: aws-frontend-destroy aws-backend-destroy aws-cognito-destroy ## Delete everything on AWS (each stack asks first)

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n"} \
	  /^[a-zA-Z_.-]+:.*?##/ { printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
