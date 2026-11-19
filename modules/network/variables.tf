variable "environment" {
  type        = string
  description = "Environment name"
}

variable "project" {
  type        = string
  description = "Project name"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block of the VPC when self-created (ignored if existing_vpc_id != null)"
}

variable "az_count" {
  type        = number
  default     = 2
  description = "Number of AZs the VPC spans. Default 2 for 3 worker nodes."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common tags applied to resources"
}

