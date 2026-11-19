data "aws_caller_identity" "current" {}

locals {
  # S3 bucket names are global. The account ID makes the name unique and keeps
  # it out of the repository.
  bucket_name = "${var.project}-${var.environment}-mysql-backup-${data.aws_caller_identity.current.account_id}"
}

# Mirrors step 2 of the lesson 16 runbook: create the bucket, block every
# public path, turn on default encryption. Versioning, lifecycle rules and a
# bucket policy are left out on purpose, so backup and restore behave as in
# the lesson.
resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Name = local.bucket_name })

  lifecycle {
    precondition {
      condition     = length(local.bucket_name) <= 63
      error_message = "The bucket name ${local.bucket_name} is longer than 63 characters. Shorten the project or the environment name."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The bucket name ends with the account ID, so no manifest contains it. The
# commands that install the MySQL cluster read the name from this parameter.
# The environment comes first in the path: Parameter Store rejects names that
# start with "aws" or "ssm", and the project name starts with "aws".
resource "aws_ssm_parameter" "bucket_name" {
  name        = "/${var.environment}/${var.project}/mysql-backup/bucket_name"
  description = "Name of the S3 bucket that stores MySQL backups."
  type        = "String"
  value       = aws_s3_bucket.this.bucket
  tags        = merge(var.tags, { Name = "${var.project}-${var.environment}-mysql-backup-bucket-name" })
}
