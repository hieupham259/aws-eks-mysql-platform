output "cicd_canary_parameter_name" {
  description = "Name of the SSM parameter used as the CI/CD canary."
  value       = aws_ssm_parameter.cicd_canary.name
}
