provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      App       = "__APP_NAME__"
      ManagedBy = "terraform"
    }
  }
}

# us-east-1 is required for the platform's CLOUDFRONT-scope WAF reference.
# Nothing else in this app needs us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      App       = "__APP_NAME__"
      ManagedBy = "terraform"
    }
  }
}

# Cloudflare provider config. API token comes from the platform-shared SSM
# placeholder; operator populates once when the platform is bootstrapped.
data "aws_ssm_parameter" "cloudflare_api_token" {
  name = "/tinyapp/cloudflare/api_token"
}

provider "cloudflare" {
  api_token = data.aws_ssm_parameter.cloudflare_api_token.value
}

# Neon provider — same SSM-backed pattern.
data "aws_ssm_parameter" "neon_api_key" {
  name = "/tinyapp/neon/api_key"
}

provider "neon" {
  api_key = data.aws_ssm_parameter.neon_api_key.value
}

# The app itself. The tinyapp module reads platform facts (WAF ARN, Neon
# project handles, Bedrock model ARNs, SES sender, CodeConnection ARN,
# pipeline artifact bucket) from SSM internally; this consumer just sets
# per-app config + capability flags + git repo location.
module "app" {
  source = "git::https://github.com/__PLATFORM_REPO__//modules/tinyapp?ref=__PLATFORM_VERSION__"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  app_name           = "__APP_NAME__"
  allowed_principals = var.allowed_principals

  # Capabilities
  database_enabled  = var.database_enabled
  storage_enabled   = var.storage_enabled
  dynamodb_tables   = var.dynamodb_tables
  email_enabled     = var.email_enabled
  ai_models_enabled = var.ai_models_enabled
  secret_names      = var.secret_names

  # Pipeline (CI/CD). pipeline_enabled defaults to true on the module side;
  # set explicitly here so the consumer's intent is visible.
  pipeline_enabled = var.git_repo != ""
  git_repo         = var.git_repo
  git_branch       = var.git_branch

  # Developer access (debug + local-dev real-AWS via AssumeRole).
  developers = var.developers
}

output "app_url" {
  description = "Public URL fronted by Cloudflare Access."
  value       = module.app.url
}

output "function_name" {
  description = "Lambda function name. Useful for `aws logs tail /aws/lambda/<name>`."
  value       = module.app.function_name
}

output "pipeline_console_url" {
  description = "Direct link to this app's CodePipeline in the AWS console."
  value       = module.app.pipeline_console_url
}
