# Was infra/auth.yaml (Lab 4, stack demo-auth): a standalone Cognito user pool on the Essentials
# tier - email as the username with self sign-up, Google as a federated provider, a public app
# client for the SPA, and managed login version 2 with Cognito's own branding.
#
# Every name here comes from var.auth_project_name ("demo"), because that is what the deployed
# stack used. Changing it renames the pool, the client and the login domain, which means new
# resources and lost accounts.

resource "aws_cognito_user_pool" "main" {
  name = "${var.auth_project_name}-users"

  # Managed login version 2 and its branding need Essentials (Lite does not support them).
  user_pool_tier = "ESSENTIALS"

  # Users sign in with their email; Cognito emails a code to verify it on sign-up.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  # Self sign-up: anyone may create an account, no admin invitation needed.
  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_uppercase = false
    require_symbols   = false
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  # Overrides the provider's default_tags for this key: the pool carries PROJECT_NAME=demo,
  # as UserPoolTags set it in the template.
  tags = {
    PROJECT_NAME = var.auth_project_name
  }
}

resource "aws_cognito_identity_provider" "google" {
  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "openid email profile"
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
  }
}

# Public client (no secret): the browser talks to Cognito directly and only ever holds tokens.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.auth_project_name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  # The reference is the dependency: the provider must exist before the client may list it.
  # No DependsOn to write by hand, as the template needed.
  supported_identity_providers = ["COGNITO", aws_cognito_identity_provider.google.provider_name]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = var.auth_callback_urls
  logout_urls                          = var.auth_logout_urls

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
}

# Hosted sign-in pages. The prefix must be unique across all of AWS, hence the account ID.
resource "aws_cognito_user_pool_domain" "main" {
  domain                = "${var.auth_project_name}-auth-${local.account_id}"
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2
}

# Managed login styled with Cognito's defaults; no custom assets to upload.
resource "aws_cognito_managed_login_branding" "main" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.web.id
  use_cognito_provided_values = true

  depends_on = [aws_cognito_user_pool_domain.main]
}
