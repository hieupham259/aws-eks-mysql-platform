variable "project" {
  type        = string
  description = "Project name. Equals the GitHub repository name."
}

variable "environment" {
  type        = string
  description = "Environment name. Equals the branch name and this directory name."

  validation {
    condition     = contains(["development", "production"], var.environment)
    error_message = "The environment must be development or production."
  }
}

variable "region" {
  type        = string
  description = "AWS region of every resource in this environment."
}
