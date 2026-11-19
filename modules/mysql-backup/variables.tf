variable "environment" {
  type        = string
  description = "Environment name. Part of the bucket name and of the SSM parameter path."
}

variable "project" {
  type        = string
  description = "Project name. Part of the bucket name and of the SSM parameter path."
}

variable "force_destroy" {
  type        = bool
  default     = true
  description = "Let terraform destroy delete the bucket together with every backup in it. Keep false wherever the backups matter."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common tags applied to resources"
}
