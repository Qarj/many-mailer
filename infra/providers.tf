terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
provider "aws" {
  region = var.aws_region

  # Apply consistent tags across all supported AWS resources
  default_tags {
    tags = {
      Project = "many-mailer"
    }
  }
}
