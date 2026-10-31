# Non-secret values only. The Google client secret is a sensitive workspace variable.
project_name = "meetings"
region       = "us-east-1"

# The backend image both the report builder and the agenda parser run.
image_uri = "896138901201.dkr.ecr.us-east-1.amazonaws.com/meetings-backend:7da3119-dirty-20261017110705"

# The application's Cognito pool (infra/cognito.yaml, still CloudFormation) whose tokens the
# parser accepts. Lab 4's own pool is a different one; see auth.tf.
cognito_user_pool_id = "us-east-1_ZP0kUOTsf"
cognito_client_id    = "7n91n1e0fnau4pcpkjdbng7hm5"

google_client_id = "324676702520-v4neq1ce092gsjjhu8qst8dm2vibhme5.apps.googleusercontent.com"

mail_from    = "alinayatsko10@gmail.com"
mail_to      = "alinayatsko10@gmail.com"
budget_email = "alinayatsko10@gmail.com"
