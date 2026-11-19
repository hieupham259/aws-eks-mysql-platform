locals {
  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "terraform"
  })
}

module "network" {
  source = "../../modules/network"

  environment = var.environment
  tags        = local.common_tags
  project     = var.project
  vpc_cidr    = var.vpc_cidr
}
module "mysql_backup" {
  source = "../../modules/mysql-backup"

  environment = var.environment
  tags        = local.common_tags
  project     = var.project
}