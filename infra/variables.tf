variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (staging, production)"
  type        = string
  default     = "staging"
}

variable "app_image" {
  description = "Docker image URI for the web app (ECR)"
  type        = string
}

variable "batch_image" {
  description = "Docker image URI for the batch job (ECR)"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_name" {
  description = "Postgres database name"
  type        = string
  default     = "contoso"
}

variable "db_username" {
  description = "Postgres admin username (stored in Secrets Manager)"
  type        = string
  default     = "contoso_admin"
}

# Never set this directly — source from AWS Secrets Manager at apply time
# Example: TF_VAR_db_password=$(aws secretsmanager get-secret-value --secret-id contoso/db_password --query SecretString --output text)
variable "db_password" {
  description = "Postgres admin password — must be sourced from Secrets Manager, never hardcoded"
  type        = string
  sensitive   = true
}

variable "vpc_id" {
  description = "VPC ID for all resources"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (at least 2 AZs) for RDS and ECS"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB"
  type        = list(string)
}

variable "reports_bucket_name" {
  description = "S3 bucket name for reconciliation reports"
  type        = string
  default     = "contoso-reports-prod"
}
