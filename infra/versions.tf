terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1]
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    neon = {
      source  = "kislerdm/neon"
      version = "~> 0.13"
    }
  }

  backend "s3" {
    bucket       = "__AWS_PROFILE__-tfstate-__AWS_ACCOUNT_ID__"
    key          = "apps/__APP_NAME__.tfstate"
    region       = "__AWS_REGION__"
    encrypt      = true
    use_lockfile = true
  }
}
