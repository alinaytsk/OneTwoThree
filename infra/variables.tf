variable "region" {
  type        = string
  default     = "us-east-1"
  description = "Everything is deployed here: CloudFront takes custom-domain certificates only from us-east-1."
}

variable "project_name" {
  type        = string
  default     = "meetings"
  description = "Name prefix for the reports and parser resources, and the value of their PROJECT_NAME tag."
}

# --- Lab 4's standalone pool (was infra/auth.yaml, stack demo-auth) -------------------------
# Its own prefix, because that stack was deployed with the template's default, "demo". The pool,
# the client and the managed login domain are all named from it, and a name change here is a new
# resource rather than an imported one - so it stays "demo" until somebody deliberately rebuilds.
variable "auth_project_name" {
  type        = string
  default     = "demo"
  description = "Name prefix of the Lab 4 Cognito pool. Must keep matching the deployed names."
}

variable "google_client_id" {
  type        = string
  description = "OAuth client ID from Google Cloud, for the pool's Google identity provider."
}

variable "google_client_secret" {
  type        = string
  sensitive   = true
  description = "OAuth client secret from Google Cloud. Set as a sensitive workspace variable, never in terraform.tfvars."
}

variable "auth_callback_urls" {
  type        = list(string)
  description = "Where managed login may send users back after signing in."
  default = [
    "https://dm3js9endd52u.cloudfront.net/",
    "http://localhost:5173/",
    "https://dm3js9endd52u.cloudfront.net/auth/callback",
    "http://localhost:5173/auth/callback",
  ]
}

variable "auth_logout_urls" {
  type        = list(string)
  description = "Where managed login may send users after signing out."
  default = [
    "https://dm3js9endd52u.cloudfront.net/",
    "http://localhost:5173/",
  ]
}

# --- The backend stack this one reads from --------------------------------------------------
variable "backend_stack_name" {
  type        = string
  default     = "meetings-backend"
  description = <<-EOT
    The CloudFormation stack that still owns the VPC, the database and the API Lambda. It is not
    translated here (the lab translates auth, reports and ai); its outputs are read with the
    aws_cloudformation_stack data source in data.tf.
  EOT
}

variable "image_uri" {
  type        = string
  description = "Backend image, including tag. The report builder and the agenda parser both run it, on different commands."
}

variable "architecture" {
  type        = string
  default     = "arm64"
  description = "Must match the platform the image was built for."

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

# --- Weekly report (was infra/reports.yml) ---------------------------------------------------
variable "builder_timeout" {
  type        = number
  default     = 120
  description = "Seconds the builder may take: room for Aurora to resume from 0 ACU plus two weeks of queries."
}

variable "queue_visibility_timeout" {
  type        = number
  default     = 720
  description = "6x builder_timeout, the SQS rule for Lambda event sources."

  validation {
    condition     = var.queue_visibility_timeout >= var.builder_timeout
    error_message = "queue_visibility_timeout must be at least builder_timeout; AWS recommends 6x."
  }
}

variable "report_timezone" {
  type        = string
  default     = "Europe/Kyiv"
  description = "Zone the ISO week boundaries are taken in, and that the schedule fires in."
}

variable "report_retention_days" {
  type        = number
  default     = 90
  description = "Days before a report object is deleted from the bucket."
}

variable "log_retention_days" {
  type        = number
  default     = 7
  description = "Retention of the Lambda log groups."
}

variable "mail_from" {
  type        = string
  description = "Sender of the weekly report. Verified in SES."
}

variable "mail_to" {
  type        = string
  description = "Comma-separated recipients. In the SES sandbox each one must be verified too."
}

variable "ses_domain" {
  type        = string
  default     = ""
  description = "Domain to create an SES identity for. Empty means the sender is verified by hand, which is the case today."
}

# --- Agenda parser (was infra/ai.yml) --------------------------------------------------------
variable "cors_origins" {
  type        = list(string)
  description = "Browser origins allowed on the parser's function URL."
  default = [
    "http://localhost:3000",
    "http://localhost:5173",
    "https://dm3js9endd52u.cloudfront.net",
  ]
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Pool whose ID tokens the parser accepts: the application's pool, not Lab 4's."
}

variable "cognito_client_id" {
  type        = string
  description = "App client the accepted tokens are issued for."
}

variable "parser_model" {
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
  description = "Bedrock model id. A base id for the Messages API, an inference profile id for invoke_model."
}

variable "parser_backend" {
  type        = string
  default     = "invoke_model"
  description = "Which Bedrock endpoint the model is called through: mantle or invoke_model."

  validation {
    condition     = contains(["mantle", "invoke_model"], var.parser_backend)
    error_message = "parser_backend must be mantle or invoke_model."
  }
}

variable "parser_effort" {
  type        = string
  default     = ""
  description = "output_config.effort for the model. Empty sends no output_config at all, which models before the 5 family require."
}

variable "parser_price_in_per_mtok" {
  type        = string
  default     = "3"
  description = "USD per million input tokens, used for the cost in the parser's log line."
}

variable "parser_price_out_per_mtok" {
  type        = string
  default     = "15"
  description = "USD per million output tokens."
}

variable "parser_price_source" {
  type        = string
  default     = "public-list"
  description = "Where those prices came from, logged with every parse: bedrock-rate-card or public-list."
}

variable "parser_max_chars" {
  type        = number
  default     = 10000
  description = "Longer pastes are rejected with 413 before the model is called."
}

variable "parser_timezone" {
  type        = string
  default     = "Europe/Kyiv"
  description = "Timezone relative dates are resolved in."
}

variable "parser_timeout" {
  type        = number
  default     = 30
  description = "Seconds. A parse takes 2-8 s; 30 leaves room for the one retry."
}

variable "parser_memory_size" {
  type        = number
  default     = 1024
  description = "MB. Buys cold-start speed: at 512 the import of the AWS signing stack hit Lambda's 10 s init limit."
}

variable "budget_limit_usd" {
  type        = number
  default     = 5
  description = "Monthly account spend above which an email is sent."
}

variable "budget_email" {
  type        = string
  description = "Where budget alerts go. The address verified in SES for Lab 5."
}
