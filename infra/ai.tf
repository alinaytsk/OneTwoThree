# Was infra/ai.yml (Lab 6): the "Paste an agenda" parser. One Lambda running the backend image
# on a different command, with a public function URL the browser calls directly, and Claude on
# Bedrock behind it.
#
# No vpc_config, on purpose: the function needs Bedrock and the Cognito JWKS, both public
# endpoints, and needs no database. The component the browser can hand 10 000 characters of
# untrusted text to has no route to the meetings data.
#
# Keeping it outside the VPC also keeps a Bedrock interface endpoint off the bill ($7.30 a
# month), which is the comparison the Lab 6 submission makes against the per-parse cost.

locals {
  parser_name = "${var.project_name}-agenda-parser"

  # Only on the bedrock-runtime path. The Messages API on Bedrock has its own single action and
  # takes no inference profile.
  uses_inference_profile = var.parser_backend == "invoke_model"

  inference_profile_arn = "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:inference-profile/${var.parser_model}"
}

resource "aws_cloudwatch_log_group" "parser" {
  name              = "/aws/lambda/${local.parser_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "parser" {
  name = "${var.project_name}-agenda-parser"

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
resource "aws_iam_role_policy_attachment" "parser_basic" {
  role       = aws_iam_role.parser.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "parser_bedrock" {
  name = "invoke-claude-on-bedrock"
  role = aws_iam_role.parser.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # The Messages API on Bedrock ("Mantle") is one action, and it does not take a model ARN
      # as its resource - the model is named in the request body - so "*" is the only resource
      # this can be written against. The blast radius is bounded by the action itself:
      # inference, nothing else.
      Effect   = "Allow"
      Action   = "bedrock-mantle:CreateInference"
      Resource = "*"
    }]
  })
}

# Only when parser_backend = invoke_model. A cross-region inference profile needs BOTH halves:
# InvokeModel on the profile itself, and InvokeModel on the foundation models it routes to.
# The condition is what keeps the second statement tight - the role can reach those models only
# through this one profile, never directly.
resource "aws_iam_role_policy" "parser_inference_profile" {
  count = local.uses_inference_profile ? 1 : 0

  name = "invoke-claude-through-an-inference-profile"
  role = aws_iam_role.parser.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:GetInferenceProfile",
        ]
        Resource = local.inference_profile_arn
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "arn:${local.partition}:bedrock:*::foundation-model/*"
        Condition = {
          StringEquals = { "bedrock:InferenceProfileArn" = local.inference_profile_arn }
        }
      },
    ]
  })
}

resource "aws_lambda_function" "parser" {
  function_name = local.parser_name
  package_type  = "Image"
  image_uri     = var.image_uri
  architectures = [var.architecture]
  memory_size   = var.parser_memory_size
  timeout       = var.parser_timeout
  role          = aws_iam_role.parser.arn

  image_config {
    # Same image as the API and the report builder, different entry point.
    command = ["app.ai.agenda_lambda.handler"]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.parser.name
  }

  environment {
    variables = {
      PARSER_MODEL              = var.parser_model
      PARSER_BACKEND            = var.parser_backend
      PARSER_EFFORT             = var.parser_effort
      PARSER_MAX_CHARS          = tostring(var.parser_max_chars)
      PARSER_TIMEZONE           = var.parser_timezone
      PARSER_PRICE_IN_PER_MTOK  = var.parser_price_in_per_mtok
      PARSER_PRICE_OUT_PER_MTOK = var.parser_price_out_per_mtok
      PARSER_PRICE_SOURCE       = var.parser_price_source
      BEDROCK_REGION            = local.region
      COGNITO_REGION            = local.region
      COGNITO_USER_POOL_ID      = var.cognito_user_pool_id
      COGNITO_CLIENT_ID         = var.cognito_client_id
      # COGNITO_JWKS is deliberately absent: outside the VPC the function fetches the pool's
      # keys itself. The API has to be handed them, because it has no route out.
    }
  }
}

# Public HTTPS endpoint the browser posts the pasted text to. AuthType NONE because the caller
# holds a Cognito ID token, not SigV4 credentials - the handler checks that token itself.
resource "aws_lambda_function_url" "parser" {
  function_name      = aws_lambda_function.parser.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = var.cors_origins
    allow_methods = ["POST"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 3600
  }
}

# A public function URL needs both permissions, like the backend's.
resource "aws_lambda_permission" "parser_url" {
  statement_id           = "FunctionURLAllowPublicAccess"
  function_name          = aws_lambda_function.parser.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "parser_invoke" {
  statement_id  = "AllowInvokeViaFunctionUrl"
  function_name = aws_lambda_function.parser.function_name
  action        = "lambda:InvokeFunction"
  principal     = "*"
}

# =====================================================================
# Cost guard
# =====================================================================
# Account-wide on purpose: a runaway parse loop shows up here whatever it is billed as.
# Budgets cannot be tagged.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"

  # At 80% of the budget, while there is still time to react.
  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_email]
  }

  # And on the forecast, which is what catches a leak on day three of the month.
  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_email]
  }
}
