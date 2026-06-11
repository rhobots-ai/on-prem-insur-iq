provider "aws" {
  region = var.region
  default_tags { tags = var.tags }
}

data "aws_caller_identity" "current" {}
