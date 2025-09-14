terraform {
  backend "s3" {
    bucket         = "many-mailer-tf-state-381354916781-eu-west-1"
    key            = "infra/terraform.tfstate"
    region         = "eu-west-1"
    use_lockfile   = true
    encrypt        = true
  }
}
