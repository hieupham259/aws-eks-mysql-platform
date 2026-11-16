# Non-secret settings of the development environment. Never put secrets here.
project     = "aws-eks-mysql-platform"
environment = "development"
region      = "us-east-1"

# Change this value in a pull request to exercise the plan and apply workflows.
cicd_canary_value = "v1"
