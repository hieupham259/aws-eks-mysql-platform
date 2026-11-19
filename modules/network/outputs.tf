output "vpc_id" {
  description = "VPC ID (created or existing)"
  value       = aws_vpc.this[0].id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.this[0].cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (for ALB)"
  value       = aws_subnet.public[*].id
}

output "azs" {
  description = "Availability zones in use"
  value       = local.azs
}
