output "bucket_name" {
  description = "Name of the S3 bucket that stores MySQL backups"
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "ARN of the backup bucket, for the policy of the backup IAM user"
  value       = aws_s3_bucket.this.arn
}

output "bucket_name_parameter" {
  description = "Name of the SSM parameter that holds the bucket name"
  value       = aws_ssm_parameter.bucket_name.name
}
