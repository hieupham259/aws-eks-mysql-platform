# The stack itself lives in envs/_shared so that every environment runs the
# same code. This directory only holds what differs per environment: the
# backend key, the provider settings and terraform.tfvars.
module "stack" {
  source = "../_shared"

  project           = var.project
  environment       = var.environment
  cicd_canary_value = var.cicd_canary_value
}
