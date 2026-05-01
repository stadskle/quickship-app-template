# The app itself. The quickship module reads platform facts (WAF ARN, Neon
# project handles, Bedrock model ARNs, SES sender, CodeConnection ARN,
# pipeline artifact bucket) from SSM internally; this consumer just sets
# per-app config + capability flags + git repo location.
module "app" {
  # `?ref=main` tracks latest. Pin to a tag (e.g. `?ref=v0.3.1`) if you want
  # stability — change here, then `terraform init -upgrade` and re-deploy.
  source = "git::https://__PLATFORM_SOURCE__//modules/quickship?ref=main"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix        = var.aws_profile
  app_name           = var.app_name
  allowed_principals = var.allowed_principals

  # Lambda sizing
  memory_mb       = var.memory_mb
  timeout_seconds = var.timeout_seconds

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

output "pipeline_name" {
  description = "Name of this app's CodePipeline. Pass to `aws codepipeline start-pipeline-execution`."
  value       = module.app.pipeline_name
}

output "pipeline_console_url" {
  description = "Direct link to this app's CodePipeline in the AWS console."
  value       = module.app.pipeline_console_url
}
