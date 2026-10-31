# Everything the Makefile and the frontend build read. The names match the CloudFormation
# outputs they replace, so `terraform output -raw <name>` can stand in for the
# describe-stacks lookups one at a time.

# --- Lab 4's pool (was the demo-auth stack) --------------------------------------------------
output "auth_user_pool_id" {
  description = "ID of the Lab 4 Cognito user pool."
  value       = aws_cognito_user_pool.main.id
}

output "auth_user_pool_client_id" {
  description = "Public app client used by the SPA."
  value       = aws_cognito_user_pool_client.web.id
}

output "auth_domain_prefix" {
  description = "Prefix of the managed login domain."
  value       = aws_cognito_user_pool_domain.main.domain
}

output "auth_hosted_ui_domain" {
  description = "Domain of the managed login / OAuth endpoints."
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${local.region}.amazoncognito.com"
}

output "auth_issuer" {
  description = "Issuer (iss) of the pool's tokens; its JWKS is at <issuer>/.well-known/jwks.json."
  value       = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "auth_login_url" {
  description = "Full managed login URL."
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${local.region}.amazoncognito.com"
}

# --- Weekly report ---------------------------------------------------------------------------
output "reports_bucket_name" {
  value = aws_s3_bucket.reports.bucket
}

output "report_requests_queue_url" {
  description = "Queue `make report-now WEEK=...` sends to."
  value       = aws_sqs_queue.report_requests.url
}

output "report_requests_queue_arn" {
  value = aws_sqs_queue.report_requests.arn
}

output "report_requests_dlq_url" {
  description = "Where a report that failed three times ends up."
  value       = aws_sqs_queue.report_requests_dlq.url
}

output "builder_function_name" {
  value = aws_lambda_function.builder.function_name
}

output "mailer_function_name" {
  value = aws_lambda_function.mailer.function_name
}

output "builder_log_group_name" {
  value = aws_cloudwatch_log_group.builder.name
}

output "mailer_log_group_name" {
  value = aws_cloudwatch_log_group.mailer.name
}

output "schedule_name" {
  value = aws_scheduler_schedule.weekly_report.name
}

# --- Agenda parser -----------------------------------------------------------------------------
output "parser_url" {
  description = "Function URL the frontend is built with (VITE_PARSER_URL)."
  value       = aws_lambda_function_url.parser.function_url
}

output "parser_function_name" {
  value = aws_lambda_function.parser.function_name
}

output "parser_log_group_name" {
  value = aws_cloudwatch_log_group.parser.name
}

output "parser_model" {
  value = var.parser_model
}

output "parser_backend" {
  value = var.parser_backend
}

output "budget_name" {
  value = aws_budgets_budget.monthly.name
}
