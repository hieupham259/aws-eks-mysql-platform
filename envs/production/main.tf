module "stack" {
  source = "../_shared"

  project     = var.project
  environment = var.environment
  region      = var.region
}
