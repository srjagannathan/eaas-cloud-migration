variable "environment"       { type = string }
variable "vpc_id"            { type = string }
variable "subnet_ids"        { type = list(string) }
variable "db_name"           { type = string }
variable "db_username"       { type = string }
variable "db_password"       { type = string; sensitive = true }
variable "db_instance_class" { type = string }

resource "aws_db_subnet_group" "contoso" {
  name       = "contoso-${var.environment}"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "rds" {
  name   = "contoso-rds-${var.environment}"
  vpc_id = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds.id]
    description     = "Postgres from ECS tasks only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "primary" {
  identifier              = "contoso-${var.environment}"
  engine                  = "postgres"
  engine_version          = "15.4"
  instance_class          = var.db_instance_class
  allocated_storage       = 100
  max_allocated_storage   = 500
  storage_encrypted       = true
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password  # sourced from Secrets Manager at apply time
  db_subnet_group_name    = aws_db_subnet_group.contoso.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  multi_az                = true
  publicly_accessible     = false
  deletion_protection     = var.environment == "production"
  backup_retention_period = 7
  skip_final_snapshot     = var.environment != "production"
}

resource "aws_db_instance" "read_replica" {
  identifier             = "contoso-${var.environment}-replica"
  replicate_source_db    = aws_db_instance.primary.identifier
  instance_class         = var.db_instance_class
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
}

# Store connection details in Secrets Manager — referenced by ECS task role
resource "aws_secretsmanager_secret" "db" {
  name = "contoso/${var.environment}/db"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = aws_db_instance.primary.address
    port     = 5432
    dbname   = var.db_name
  })
}

output "primary_endpoint"      { value = aws_db_instance.primary.address;      sensitive = true }
output "read_replica_endpoint" { value = aws_db_instance.read_replica.address; sensitive = true }
output "db_secret_arn"         { value = aws_secretsmanager_secret.db.arn }
