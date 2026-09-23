terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

  }
  backend "s3" {
    bucket       = "chill-crate-tfstate-stg"
    key          = "eks/stg/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true # Native S3 locking removes DynamoDB dependency
  }
}

provider "aws" {
  region = var.aws_region
}
