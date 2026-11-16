variable "project" {
  type        = string
  description = "Project name. Prefixes resource names and SSM parameter paths."
}

variable "environment" {
  type        = string
  description = "Environment name. Equals the branch name and the directory under envs/."
}

variable "cicd_canary_value" {
  type        = string
  description = "Value of the CI/CD canary parameter. Change it in a pull request to exercise plan and apply."
}
