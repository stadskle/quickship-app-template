# Per-app config. The bootstrap script populated this; edit as needed.
# Capability flags map directly to inputs on the platform's tinyapp module.

aws_region         = "__AWS_REGION__"
allowed_principals = __ALLOWED_PRINCIPALS__

# CI/CD — git_repo is filled in by Claude (or you) after the GitHub repo is
# created. Until set, the pipeline is disabled and `terraform apply` does
# not provision CodeBuild/CodePipeline. Run /deploy to have Claude auto-fill
# this from `git remote get-url origin`.
git_repo   = ""
git_branch = "main"

# Developers with debug + local-dev real-AWS access (matching `developer`
# module calls in the platform repo).
developers = __DEVELOPERS__

# Capabilities — opt in to what this app uses. Each maps to platform-side
# resources (DB role, S3 bucket, DynamoDB table, IAM grant) created by the
# tinyapp module.
database_enabled  = __DATABASE_ENABLED__
storage_enabled   = __STORAGE_ENABLED__
dynamodb_tables   = __DYNAMODB_TABLES__
email_enabled     = __EMAIL_ENABLED__
ai_models_enabled = __AI_MODELS_ENABLED__

# Per-app secrets. Each name becomes an SSM SecureString placeholder +
# Lambda env var. Set values via `aws ssm put-parameter` after first apply.
secret_names = []
