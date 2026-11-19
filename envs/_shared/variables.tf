variable "project" {
  type        = string
  description = "Project name. Prefixes resource names and SSM parameter paths."
}

variable "environment" {
  type        = string
  description = "Environment name. Equals the branch name and the directory under envs/."
}

variable "region" {
  type        = string
  description = "AWS region"
}

# --- Network ---
variable "vpc_cidr" {
  type        = string
  default     = "192.168.0.0/16"
  description = "CIDR block of the VPC when self-created"
}

variable "tags" {
  type    = map(string)
  default = {}
}