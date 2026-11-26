# Alarms for messages stuck in dead-letter queues (RF-21).
# A message only reaches a DLQ after maxReceiveCount failed receives, so any visible
# message there needs a human: inspect it, fix the cause, then redrive (README).

locals {
  # queue key => DLQ name. A future DLQ is one line here.
  dlq_names = merge(
    { for k, q in aws_sqs_queue.dlq : k => q.name },
    { "report-emails" = aws_sqs_queue.report_emails_dlq.name },
  )
}

resource "aws_sns_topic" "ops_alerts" {
  name = "ops-alerts"
}

resource "aws_sns_topic_policy" "ops_alerts" {
  arn = aws_sns_topic.ops_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = ["SNS:Publish", "SNS:Subscribe", "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:ListSubscriptionsByTopic"]
        Resource  = aws_sns_topic.ops_alerts.arn
      },
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.ops_alerts.arn
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
      },
      merge(local.deny_insecure_transport, { Resource = aws_sns_topic.ops_alerts.arn, Action = local.sns_topic_actions }),
    ]
  })
}

# Each recipient must confirm the AWS subscription email before alerts arrive.
resource "aws_sns_topic_subscription" "ops_alerts_email" {
  for_each = toset(var.alarm_emails)

  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = local.dlq_names

  alarm_name          = "${each.value}-not-empty"
  alarm_description   = "Dead-letter queue ${each.value} holds messages. Inspect them and redrive once the cause is fixed (terraform/README.md, Dead-letter queue alarms)."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  # An idle SQS queue can publish no datapoints; that is not a breach.
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.ops_alerts.arn]
  ok_actions         = [aws_sns_topic.ops_alerts.arn]
}
