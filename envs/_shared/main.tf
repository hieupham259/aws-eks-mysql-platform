locals {
  name_prefix = "${var.project}-${var.environment}"
}

# CI/CD canary: a free, harmless resource. It lets the pipeline prove that it
# can plan, apply, detect drift and destroy before real infrastructure exists.
#   - Change var.cicd_canary_value in a pull request to see a plan and an apply.
#   - Change the value directly in AWS to see drift detection fail.
resource "aws_ssm_parameter" "cicd_canary" {
  name        = "/${var.project}/${var.environment}/cicd/canary"
  description = "CI/CD canary managed by Terraform. Do not edit by hand, except to test drift detection."
  type        = "String"
  value       = var.cicd_canary_value

  tags = {
    Name = "${local.name_prefix}-cicd-canary"
  }
}
