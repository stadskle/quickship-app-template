# Provider configuration. Auto-loaded by Terraform — you almost never need
# to edit this file. The credentials all come from SSM placeholders the
# platform admin populated once during platform bootstrap.

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

# Cloudflare API token comes from the platform-shared SSM placeholder;
# operator populates once when the platform is bootstrapped.
data "aws_ssm_parameter" "cloudflare_api_token" {
  name = "/quickship/cloudflare/api_token"
}

provider "cloudflare" {
  api_token = data.aws_ssm_parameter.cloudflare_api_token.value
}

# Neon provider — same SSM-backed pattern.
data "aws_ssm_parameter" "neon_api_key" {
  name = "/quickship/neon/api_key"
}

provider "neon" {
  api_key = data.aws_ssm_parameter.neon_api_key.value
}
