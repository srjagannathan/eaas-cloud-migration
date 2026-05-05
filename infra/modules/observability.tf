# =====================================================================
# Observability — CloudWatch alarms as IaC
# =====================================================================
# Added in response to Ops review (Priya Krishnan): "A trip-wire that
# exists only in markdown is theatre." The SLOs in
# runbooks/ops-runbook.md section 5 are now backed by alarms in code.
#
# Each alarm publishes to the contoso-prod-incidents SNS topic, which
# integrates with PagerDuty (escalation policy: Contoso-Production).
# =====================================================================

variable "environment"            { type = string }
variable "ecs_cluster_name"       { type = string }
variable "ecs_service_name"       { type = string }
variable "alb_arn_suffix"         { type = string }
variable "target_group_arn_suffix" { type = string }
variable "rds_cluster_id"         { type = string }
variable "batch_job_queue_name"   { type = string }
variable "pagerduty_integration_url" {
  type        = string
  sensitive   = true
  description = "PagerDuty events API integration URL — sourced from Secrets Manager at apply time"
}

# ──── SNS topic for incident routing ────────────────────────────────
resource "aws_sns_topic" "incidents" {
  name              = "contoso-${var.environment}-incidents"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "pagerduty" {
  topic_arn              = aws_sns_topic.incidents.arn
  protocol               = "https"
  endpoint               = var.pagerduty_integration_url
  endpoint_auto_confirms = true
}

# ──── SLO 1: Web app availability — 5xx rate < 1% over 5 min ────────
resource "aws_cloudwatch_metric_alarm" "web_5xx_rate" {
  alarm_name          = "contoso-${var.environment}-web-5xx-rate"
  alarm_description   = "Web app 5xx rate exceeded 1% — see Ops runbook section 6.4"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  threshold           = 1.0
  alarm_actions       = [aws_sns_topic.incidents.arn]
  ok_actions          = [aws_sns_topic.incidents.arn]
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "100 * (e5xx / requests)"
    label       = "5xx error rate (%)"
    return_data = true
  }
  metric_query {
    id = "e5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
    }
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
    }
  }
}

# ──── SLO 2: Web app latency — p95 > 500ms for 10 min ───────────────
resource "aws_cloudwatch_metric_alarm" "web_p95_latency" {
  alarm_name          = "contoso-${var.environment}-web-p95-latency"
  alarm_description   = "Web app p95 latency > 500ms — Aurora cold-start or downstream issue. See Ops runbook section 6.4"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 10
  threshold           = 0.5
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  alarm_actions       = [aws_sns_topic.incidents.arn]
  treat_missing_data  = "notBreaching"
}

# ──── SLO 3: ALB target health — < 100% for 5 min ───────────────────
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_targets" {
  alarm_name          = "contoso-${var.environment}-alb-unhealthy-targets"
  alarm_description   = "ALB has unhealthy targets — capacity loss. See Ops runbook section 6.4"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  alarm_actions       = [aws_sns_topic.incidents.arn]
  treat_missing_data  = "notBreaching"
}

# ──── SLO 4: Aurora connection saturation — > 80% of max ────────────
resource "aws_cloudwatch_metric_alarm" "aurora_connections" {
  alarm_name          = "contoso-${var.environment}-aurora-connection-saturation"
  alarm_description   = "Aurora connection count > 80% — connection storm imminent. See Ops runbook section 6.4 (Aurora connection storm)"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80   # raise as ACU range scales
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { DBClusterIdentifier = var.rds_cluster_id }
  alarm_actions       = [aws_sns_topic.incidents.arn]
}

# ──── SLO 5: Aurora replication lag — > 1 second for 5 min ──────────
resource "aws_cloudwatch_metric_alarm" "aurora_replication_lag" {
  alarm_name          = "contoso-${var.environment}-aurora-replication-lag"
  alarm_description   = "Aurora replica lag > 1s — BI queries seeing stale data"
  namespace           = "AWS/RDS"
  metric_name         = "AuroraReplicaLag"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1000   # milliseconds
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { DBClusterIdentifier = var.rds_cluster_id }
  alarm_actions       = [aws_sns_topic.incidents.arn]
}

# ──── SLO 6: Reconciliation completion — by 06:00 UTC daily ────────
# CloudWatch native alarm cannot express "by time of day" — implemented
# as a Lambda watchdog that publishes a custom metric. Alarm here.
resource "aws_cloudwatch_metric_alarm" "batch_reconciliation_overdue" {
  alarm_name          = "contoso-${var.environment}-batch-reconciliation-overdue"
  alarm_description   = "Reconciliation job did not complete by 06:00 UTC. Page DBA + Eng on-call."
  namespace           = "Contoso/Batch"
  metric_name         = "ReconciliationOverdue"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.incidents.arn]
  treat_missing_data  = "notBreaching"
}

# ──── SLO 7: Health check uptime — > 99.99% ─────────────────────────
resource "aws_cloudwatch_metric_alarm" "health_check" {
  alarm_name          = "contoso-${var.environment}-health-check-failure"
  alarm_description   = "Health endpoint failing — full outage. SEV2 immediate page."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.incidents.arn]
  treat_missing_data  = "breaching"
}

# ──── Cost guardrail: monthly cost anomaly ──────────────────────────
# Addresses CTO review (David Chen): TCO sensitivity. If Aurora ACU
# usage runs 2x estimate, this alarm fires before month-end.
resource "aws_cloudwatch_metric_alarm" "monthly_cost_anomaly" {
  alarm_name          = "contoso-${var.environment}-cost-anomaly"
  alarm_description   = "Forecast monthly cost > 25% above baseline. Trigger right-sizing review."
  namespace           = "AWS/Billing"
  metric_name         = "EstimatedCharges"
  statistic           = "Maximum"
  period              = 21600   # 6 hours
  evaluation_periods  = 1
  threshold           = 60000   # raise per environment baseline
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { Currency = "USD" }
  alarm_actions       = [aws_sns_topic.incidents.arn]
}

# ──── CloudWatch dashboard ──────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "contoso-${var.environment}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "RequestCount",          "LoadBalancer", var.alb_arn_suffix],
            [".",                  "HTTPCode_Target_5XX_Count", ".",          "."],
            [".",                  "TargetResponseTime",    ".",            "."]
          ]
          view   = "timeSeries"
          region = "us-east-1"
          title  = "Web App — RPS, 5xx, latency"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", var.rds_cluster_id],
            [".",       "AuroraReplicaLag",    ".",                   "."]
          ]
          view   = "timeSeries"
          region = "us-east-1"
          title  = "Aurora — connections, replica lag"
        }
      }
    ]
  })
}

output "incidents_topic_arn" { value = aws_sns_topic.incidents.arn }
output "dashboard_url"       { value = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}" }
