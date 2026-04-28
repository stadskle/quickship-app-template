variable "aws_region" {
  type        = string
  description = "AWS region where this app's resources live (Lambda, S3, etc.). Should match the platform region."
  default     = "eu-central-1"
}

variable "allowed_principals" {
  type        = list(string)
  description = "Cloudflare Access allow-list. Mix of explicit emails and *@domain wildcards."
}

# ---- Pipeline (CI/CD) -----------------------------------------------------

variable "git_repo" {
  type        = string
  description = "GitHub repo in `owner/repo` form (e.g. `alice/hello-world`). Drives the CodePipeline source. Detected from `git remote get-url origin` by the /deploy slash command if left empty."
  default     = ""
}

variable "git_branch" {
  type        = string
  description = "Branch that triggers builds."
  default     = "main"
}

# ---- Developers -----------------------------------------------------------

variable "developers" {
  type        = list(string)
  description = "Developer names (matching `developer` module calls in the platform repo) who get debug/operate access to this app via AssumeRole."
  default     = []
}

# ---- Capabilities ---------------------------------------------------------

variable "database_enabled" {
  type    = bool
  default = true
}

variable "storage_enabled" {
  type    = bool
  default = false
}

variable "dynamodb_tables" {
  type    = list(string)
  default = []
}

variable "email_enabled" {
  type    = bool
  default = false
}

variable "ai_models_enabled" {
  type    = bool
  default = false
}

variable "secret_names" {
  type        = list(string)
  description = "Secret names this app needs at runtime. Each becomes an SSM SecureString placeholder + Lambda env var. Set values out-of-band (CLI/console) after first apply, then re-deploy. See CLAUDE.md \"Adding a secret\"."
  default     = []
}
