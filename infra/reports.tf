# Was infra/reports.yml (Lab 5): the weekly meetings report, event driven. EventBridge Scheduler
# puts a message on SQS every Monday; a builder Lambda inside the VPC writes the CSV to S3
# through the gateway endpoint; the ObjectCreated notification invokes a mailer Lambda outside
# the VPC that sends it through SES.
#
# Two things change in the translation, both of them noted in the lab:
#
#   * The bucket's versioning, encryption, lifecycle, ownership, public-access block, policy and
#     notification are separate resources here. In the template they were properties of
#     AWS::S3::Bucket. Same configuration, more resources.
#   * The template could not let the bucket reference the mailer's permission and the permission
#     reference the bucket, so the bucket name was spelled out by hand to break the cycle. Here
#     aws_s3_bucket_notification is its own resource, so the cycle never forms and every
#     reference can be a real one.

# =====================================================================
# Storage
# =====================================================================
resource "aws_s3_bucket" "reports" {
  bucket = local.reports_bucket_name

  tags = {
    Name = "${var.project_name}-reports"
  }
}

# Private: ACLs disabled, no public access, encrypted at rest. Reports name people.
resource "aws_s3_bucket_ownership_controls" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-reports"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    expiration {
      days = var.report_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Nothing but the two roles in this stack may touch the bucket, over TLS only.
resource "aws_s3_bucket_policy" "reports" {
  bucket = aws_s3_bucket.reports.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        local.reports_bucket_arn,
        "${local.reports_bucket_arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# The write that triggers the mail.
resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.mailer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "reports/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.mailer_s3]
}

# The builder has no internet route, so S3 is reached over a gateway endpoint: a prefix-list
# route in the private route table, free of charge, no NAT gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.backend["VpcId"]
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [local.backend["PrivateRouteTableId"]]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Resource = [
        local.reports_bucket_arn,
        "${local.reports_bucket_arn}/*",
      ]
    }]
  })
}

# =====================================================================
# Queue: the Scheduler writes here, the builder reads
# =====================================================================
resource "aws_sqs_queue" "report_requests_dlq" {
  name = "${var.project_name}-report-requests-dlq"

  # 14 days, the maximum - a failed Monday stays inspectable.
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "report_requests" {
  name = "${var.project_name}-report-requests"

  # A Lambda event source needs the visibility timeout to be at least the function timeout;
  # 6x is what AWS recommends, so a slow run is not redelivered while it is still working.
  visibility_timeout_seconds = var.queue_visibility_timeout
  message_retention_seconds  = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.report_requests_dlq.arn
    maxReceiveCount     = 3
  })
}

# =====================================================================
# Builder Lambda: backend image, inside the VPC, writes the CSV to S3
# =====================================================================
resource "aws_cloudwatch_log_group" "builder" {
  name              = "/aws/lambda/${var.project_name}-report-builder"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "builder" {
  name = "${var.project_name}-report-builder"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Logs plus the network interfaces Lambda needs to join the VPC.
resource "aws_iam_role_policy_attachment" "builder_vpc_access" {
  role       = aws_iam_role.builder.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "builder_write_reports" {
  name = "write-reports"
  role = aws_iam_role.builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # PutObject writes the report; GetObject covers the HeadObject that makes a rerun a no-op.
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${local.reports_bucket_arn}/reports/*"
      },
      # Without ListBucket, S3 answers HeadObject on a missing key with 403 rather than 404, and
      # the rerun check reads that 404. Bucket ARN, not /*: ListBucket is a bucket-level action.
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.reports_bucket_arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "builder_consume_report_requests" {
  name = "consume-report-requests"
  role = aws_iam_role.builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      Resource = aws_sqs_queue.report_requests.arn
    }]
  })
}

resource "aws_lambda_function" "builder" {
  function_name = "${var.project_name}-report-builder"
  package_type  = "Image"
  image_uri     = var.image_uri
  architectures = [var.architecture]
  memory_size   = 512
  timeout       = var.builder_timeout
  role          = aws_iam_role.builder.arn

  image_config {
    # Same image as the API, different entry point.
    command = ["app.reports.lambda_handler.handler"]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.builder.name
  }

  # In the VPC because the meetings database is; S3 is reached over the gateway endpoint.
  vpc_config {
    subnet_ids         = split(",", local.backend["PrivateSubnetIds"])
    security_group_ids = [local.backend["BackendSecurityGroupId"]]
  }

  environment {
    variables = {
      REPORTS_BUCKET  = local.reports_bucket_name
      REPORT_TIMEZONE = var.report_timezone
      DB_HOST         = local.backend["DbEndpoint"]
      DB_PORT         = local.backend["DbPort"]
      DB_NAME         = local.backend["DbName"]
      DB_USER         = local.backend["DbUsername"]
      DB_PASSWORD     = jsondecode(data.aws_secretsmanager_secret_version.db.secret_string)["password"]
      # Close connections after each run so Aurora can pause again.
      DB_NULL_POOL = "true"
    }
  }

  depends_on = [aws_iam_role_policy_attachment.builder_vpc_access]
}

resource "aws_lambda_event_source_mapping" "builder" {
  event_source_arn = aws_sqs_queue.report_requests.arn
  function_name    = aws_lambda_function.builder.arn
  # One report per invocation: a batch would hide which week failed.
  batch_size = 1
  enabled    = true
}

# =====================================================================
# Schedule: Monday 07:00 Europe/Kyiv -> a message on the queue
# =====================================================================
resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-weekly-report-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # Keeps any other account from using this role through the Scheduler service.
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_send" {
  name = "send-report-request"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.report_requests.arn
    }]
  })
}

resource "aws_scheduler_schedule" "weekly_report" {
  name        = "${var.project_name}-weekly-report"
  description = "Monday 07:00 Kyiv - queue a report for the week that just ended."
  state       = "ENABLED"

  schedule_expression = "cron(0 7 ? * MON *)"
  # Named zone, not a UTC offset, so the hour stays 07:00 across the DST change.
  schedule_expression_timezone = var.report_timezone

  flexible_time_window {
    # The report is cheap and nobody else contends for the hour; run it on the minute.
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.report_requests.arn
    role_arn = aws_iam_role.scheduler.arn
    # The queue is the target rather than the function: a retry, a DLQ and a manual
    # `make report-now` all come for free, and the schedule never waits on a cold Aurora.
    input = jsonencode({ source = "schedule" })

    retry_policy {
      maximum_retry_attempts = 3
    }
  }
}

# =====================================================================
# Mailer Lambda: outside the VPC (it needs SES), outside the backend image
# =====================================================================
resource "aws_cloudwatch_log_group" "mailer" {
  name              = "/aws/lambda/${var.project_name}-report-mailer"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "mailer" {
  name = "${var.project_name}-report-mailer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Logs only - no VPC access execution role, this function is not in the VPC.
resource "aws_iam_role_policy_attachment" "mailer_basic" {
  role       = aws_iam_role.mailer.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "mailer_read_reports" {
  name = "read-reports"
  role = aws_iam_role.mailer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # Read-only, and only under reports/: the mailer must not be able to write back into the
      # prefix that invokes it.
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "${local.reports_bucket_arn}/reports/*"
    }]
  })
}

resource "aws_iam_role_policy" "mailer_send_mail" {
  name = "send-mail"
  role = aws_iam_role.mailer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
      Condition = {
        StringEquals = { "ses:FromAddress" = var.mail_from }
      }
    }]
  })
}

# The template could only carry a 4 KB placeholder, so `make aws-reports-mailer-code` had to
# upload the real handler after every stack update. Terraform zips the source itself, so the
# deployed code is whatever is in the repository and that Makefile target goes away.
data "archive_file" "mailer" {
  type        = "zip"
  source_file = "${path.module}/lambda/report_mailer.py"
  output_path = "${path.module}/.build/report_mailer.zip"
}

resource "aws_lambda_function" "mailer" {
  function_name = "${var.project_name}-report-mailer"
  runtime       = "python3.12"
  handler       = "report_mailer.handler"
  architectures = ["arm64"]
  memory_size   = 256
  timeout       = 60
  role          = aws_iam_role.mailer.arn

  # No vpc_config on purpose: SES has no gateway endpoint and the VPC has no NAT gateway.
  filename         = data.archive_file.mailer.output_path
  source_code_hash = data.archive_file.mailer.output_base64sha256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.mailer.name
  }

  environment {
    variables = {
      MAIL_FROM           = var.mail_from
      MAIL_TO             = var.mail_to
      MAIL_SUBJECT_PREFIX = "[${var.project_name}] Weekly meetings report"
      REPORT_PREFIX       = "reports/"
    }
  }
}

# S3 is allowed to invoke the mailer.
resource "aws_lambda_permission" "mailer_s3" {
  statement_id   = "AllowExecutionFromS3Bucket"
  function_name  = aws_lambda_function.mailer.function_name
  action         = "lambda:InvokeFunction"
  principal      = "s3.amazonaws.com"
  source_account = local.account_id
  source_arn     = local.reports_bucket_arn
}

# =====================================================================
# SES identity
# =====================================================================
# Creating the identity returns three DKIM CNAME records that have to be published by hand.
# Empty ses_domain (the case today) means no identity: the sender is verified on its own.
resource "aws_sesv2_email_identity" "mail_domain" {
  count = var.ses_domain == "" ? 0 : 1

  email_identity = var.ses_domain

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}
