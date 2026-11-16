# Non-secret settings of the production environment. Never put secrets here.
project     = "aws-eks-mysql-platform"
environment = "production"
region      = "us-east-1"

# Change this value in a pull request to exercise the plan and apply workflows.
cicd_canary_value = "v1"
