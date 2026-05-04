output "alb_dns_name" {
  description = "ALB DNS name for the web app"
  value       = module.ecs.alb_dns_name
}

output "rds_primary_endpoint" {
  description = "RDS primary endpoint (web app + batch job writes)"
  value       = module.rds.primary_endpoint
  sensitive   = true
}

output "rds_read_replica_endpoint" {
  description = "RDS read replica endpoint (reporting teams)"
  value       = module.rds.read_replica_endpoint
  sensitive   = true
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint"
  value       = module.elasticache.primary_endpoint
  sensitive   = true
}

output "reports_bucket_name" {
  description = "S3 bucket name for reconciliation reports"
  value       = module.s3.bucket_name
}
