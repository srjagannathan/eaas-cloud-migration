variable "environment"         { type = string }
variable "vpc_id"              { type = string }
variable "private_subnet_ids"  { type = list(string) }
variable "public_subnet_ids"   { type = list(string) }
variable "app_image"           { type = string }
variable "batch_image"         { type = string }
variable "reports_bucket_arn"  { type = string }
variable "db_secret_arn"       { type = string }
variable "redis_endpoint"      { type = string; sensitive = true }
variable "db_endpoint"         { type = string; sensitive = true }
variable "db_read_endpoint"    { type = string; sensitive = true }

data "aws_caller_identity" "current" {}

# ── ECS Cluster ────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "contoso" {
  name = "contoso-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ── IAM Task Role (web app + batch) ───────────────────────────────────────
resource "aws_iam_role" "ecs_task" {
  name = "contoso-ecs-task-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "contoso-ecs-task-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Reports"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GeneratePresignedUrl"]
        Resource = [var.reports_bucket_arn, "${var.reports_bucket_arn}/*"]
      },
      {
        Sid      = "SecretsManagerDB"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.db_secret_arn]
      }
    ]
  })
}

# ── ALB ────────────────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "contoso-alb-${var.environment}"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "web" {
  name               = "contoso-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
}

resource "aws_lb_target_group" "web" {
  name        = "contoso-web-${var.environment}"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# ── ECS Task Definition — Web App ──────────────────────────────────────────
resource "aws_ecs_task_definition" "web" {
  family                   = "contoso-web-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  task_role_arn            = aws_iam_role.ecs_task.arn
  execution_role_arn       = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "contoso-web"
    image     = var.app_image
    essential = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]

    environment = [
      { name = "S3_BUCKET", value = "contoso-reports-${var.environment}" }
    ]

    secrets = [
      { name = "DATABASE_URL", valueFrom = "${var.db_secret_arn}:host::" },
      { name = "REDIS_URL",    valueFrom = "arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter/contoso/${var.environment}/redis_url" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/contoso-web-${var.environment}"
        awslogs-region        = "us-east-1"
        awslogs-stream-prefix = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8000/health')\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }
  }])
}

# ── ECS Service ────────────────────────────────────────────────────────────
resource "aws_security_group" "ecs_tasks" {
  name   = "contoso-ecs-tasks-${var.environment}"
  vpc_id = var.vpc_id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "web" {
  name            = "contoso-web-${var.environment}"
  cluster         = aws_ecs_cluster.contoso.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "contoso-web"
    container_port   = 8000
  }

  depends_on = [aws_lb_target_group.web]
}

# ── AWS Batch — Nightly Reconciliation ────────────────────────────────────
resource "aws_batch_compute_environment" "reconciliation" {
  compute_environment_name = "contoso-batch-${var.environment}"
  type                     = "MANAGED"

  compute_resources {
    type               = "FARGATE"
    max_vcpus          = 4
    subnets            = var.private_subnet_ids
    security_group_ids = [aws_security_group.ecs_tasks.id]
  }
}

resource "aws_batch_job_queue" "reconciliation" {
  name     = "contoso-reconciliation-${var.environment}"
  state    = "ENABLED"
  priority = 1
  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.reconciliation.arn
  }
}

resource "aws_batch_job_definition" "reconciliation" {
  name = "contoso-reconciliation-${var.environment}"
  type = "container"

  platform_capabilities = ["FARGATE"]

  container_properties = jsonencode({
    image      = var.batch_image
    jobRoleArn = aws_iam_role.ecs_task.arn
    fargatePlatformConfiguration = { platformVersion = "LATEST" }
    resourceRequirements = [
      { type = "VCPU",   value = "0.5" },
      { type = "MEMORY", value = "1024" }
    ]
    environment = [
      { name = "S3_BUCKET", value = "contoso-reports-${var.environment}" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/batch/contoso-reconciliation-${var.environment}"
        awslogs-region        = "us-east-1"
        awslogs-stream-prefix = "batch"
      }
    }
  })
}

# EventBridge rule — replaces on-prem cron (0 2 * * *)
resource "aws_cloudwatch_event_rule" "reconciliation" {
  name                = "contoso-reconciliation-nightly-${var.environment}"
  description         = "Triggers nightly batch reconciliation at 2am UTC (replaces on-prem cron)"
  schedule_expression = "cron(0 2 * * ? *)"
  state               = var.environment == "production" ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "reconciliation" {
  rule     = aws_cloudwatch_event_rule.reconciliation.name
  arn      = aws_batch_job_queue.reconciliation.arn
  role_arn = aws_iam_role.ecs_task.arn

  batch_target {
    job_definition = aws_batch_job_definition.reconciliation.arn
    job_name       = "nightly-reconciliation"
  }
}

output "alb_dns_name" { value = aws_lb.web.dns_name }
