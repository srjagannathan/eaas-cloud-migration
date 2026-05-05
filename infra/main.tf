# =====================================================================
# Phase 1 IaC — what ships at cutover
# =====================================================================
# These modules provision ECS Fargate, RDS PostgreSQL multi-AZ, and
# ElastiCache Redis. This matches the Phase 1 dispositions in ADR-001
# (Refactor + Re-platform) and ADR-004 (per-workload 5 Rs).
#
# Phase 2 target architecture (EKS + Karpenter, Aurora Serverless v2,
# Redshift Serverless, Amazon MSK, Bedrock attach point) is documented
# in ADR-002. Phase 2 commitments — owners, deadlines, success criteria —
# are in runbooks/cto-office-runbook.md section 4.
#
# We deliberately did NOT prematurely upgrade the IaC to Phase 2 services.
# The Phase 1 stack runs today; the Phase 2 path is reversible at known
# cost (see runbooks/ops-runbook.md section 4 for rollback procedures).
# =====================================================================

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State stored in S3 with DynamoDB locking — never check state files into git
  backend "s3" {
    bucket         = "contoso-tf-state"
    key            = "cloud-migration/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "contoso-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "contoso-cloud-migration"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

module "s3" {
  source      = "./modules/s3"
  bucket_name = var.reports_bucket_name
  environment = var.environment
}

module "rds" {
  source             = "./modules/rds"
  environment        = var.environment
  vpc_id             = var.vpc_id
  subnet_ids         = var.private_subnet_ids
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = var.db_password
  db_instance_class  = var.db_instance_class
}

module "elasticache" {
  source     = "./modules/elasticache"
  environment = var.environment
  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids
}

module "ecs" {
  source             = "./modules/ecs"
  environment        = var.environment
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  public_subnet_ids  = var.public_subnet_ids
  app_image          = var.app_image
  batch_image        = var.batch_image
  reports_bucket_arn = module.s3.bucket_arn
  db_secret_arn      = module.rds.db_secret_arn
  redis_endpoint     = module.elasticache.primary_endpoint
  db_endpoint        = module.rds.primary_endpoint
  db_read_endpoint   = module.rds.read_replica_endpoint
}
