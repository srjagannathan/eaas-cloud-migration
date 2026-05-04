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
