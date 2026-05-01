variable "app_name" {
  type        = string
  description = "App identifier — drives resource names, the subdomain, the tfstate path. Set by bootstrap.sh from the folder name; rename here would re-create the entire app (data loss)."
}

variable "aws_profile" {
  type        = string
  description = "Local AWS profile name used by terraform's AWS provider. Same as the platform's name_prefix (per convention). Set by bootstrap.sh; you generally shouldn't edit by hand."
}

variable "aws_region" {
  type        = string
  description = "AWS region where this app's resources live (Lambda, S3, etc.). Should match the platform region."
  default     = "eu-central-1"
}

# ---- Lambda sizing --------------------------------------------------------

variable "memory_mb" {
  type        = number
  description = "Lambda memory size in MB. CPU scales linearly with memory. Bump if cold starts feel sluggish or if response times suffer under load."
  default     = 256
}

variable "timeout_seconds" {
  type        = number
  description = "Lambda timeout in seconds. Default 25 covers Bedrock calls + DB roundtrips comfortably. Bump (up to 900) for legitimate long operations; if every request takes >25s, you probably want a background job instead."
  default     = 25
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
  default = false
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
