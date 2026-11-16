# The bucket and the KMS key are created by bootstrap/02-tfstate-backend.yaml.
# The bucket name ends with the 12-digit AWS account ID: fill it in before the
# first commit. State locking uses an S3 lock file next to the state object.
terraform {
  required_version = ">= 1.13.3, < 2.0.0"

  backend "s3" {
    bucket       = "aws-eks-mysql-platform-tfstate-<account-id>"
    key          = "aws-eks-mysql-platform/production/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "alias/aws-eks-mysql-platform-tfstate"
    use_lockfile = true
  }
}
