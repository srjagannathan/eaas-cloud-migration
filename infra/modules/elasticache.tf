variable "environment" { type = string }
variable "vpc_id"     { type = string }
variable "subnet_ids" { type = list(string) }

resource "aws_elasticache_subnet_group" "contoso" {
  name       = "contoso-${var.environment}"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "redis" {
  name   = "contoso-redis-${var.environment}"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "Redis from VPC only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elasticache_replication_group" "contoso" {
  replication_group_id = "contoso-${var.environment}"
  description          = "Contoso Financial session cache — replaces on-prem warm-ping cron"
  engine               = "redis"
  engine_version       = "7.0"
  node_type            = "cache.t3.micro"
  num_cache_clusters   = 1
  subnet_group_name    = aws_elasticache_subnet_group.contoso.name
  security_group_ids   = [aws_security_group.redis.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
}

output "primary_endpoint" {
  value     = aws_elasticache_replication_group.contoso.primary_endpoint_address
  sensitive = true
}
