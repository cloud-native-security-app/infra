# SNS + SQS messaging that replaces RabbitMQ (10-deploy-tier0-infra.sh, task-defs/rabbitmq.json).
# Contract: broker repo, odd/tasks/sqs-sns-migration.md (MSG-01, signed off 2026-10-17).
# All tasks share LabRole, so these resource policies are the only isolation layer.

locals {
  scan_topics = toset(["scan-requests", "scan-cancellations", "scan-outcomes"])

  sqs_default_retention     = 4 * 24 * 3600  # 4 days
  sqs_default_dlq_retention = 14 * 24 * 3600 # 14 days

  # Consumer queues. ms-analisis-scan-outcomes is deferred until that service exists (Q7).
  scan_queues = {
    "ms-nmap-scan-requests" = {
      topic = "scan-requests"
      # Fixed ceiling, no heartbeat (Q1): a scan never outlives its SSH timeouts.
      visibility_timeout = var.ssh_connect_timeout_secs + var.ssh_command_timeout_secs + 60
      # Requests carry SSH credentials: keep them briefly (Q4).
      retention     = 3600
      dlq_retention = 24 * 3600
      filter_policy = null
    }
    "ms-nmap-scan-cancellations" = {
      topic              = "scan-cancellations"
      visibility_timeout = 30
      retention          = local.sqs_default_retention
      dlq_retention      = local.sqs_default_dlq_retention
      filter_policy      = null
    }
    "gateway-scan-outcomes" = {
      topic              = "scan-outcomes"
      visibility_timeout = 30
      retention          = local.sqs_default_retention
      dlq_retention      = local.sqs_default_dlq_retention
      filter_policy      = { routing_key = [{ prefix = "scan.outcome." }] }
    }
  }

  deny_insecure_transport = {
    Sid       = "DenyInsecureTransport"
    Effect    = "Deny"
    Principal = "*"
    Action    = "*"
    Condition = { Bool = { "aws:SecureTransport" = "false" } }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # A topic policy only accepts these actions: no wildcards ("action out of service scope").
  sns_topic_actions = [
    "SNS:Publish", "SNS:Subscribe", "SNS:Receive", "SNS:GetTopicAttributes", "SNS:SetTopicAttributes",
    "SNS:AddPermission", "SNS:RemovePermission", "SNS:DeleteTopic", "SNS:ListSubscriptionsByTopic",
  ]
}

resource "aws_sns_topic" "scan" {
  for_each = local.scan_topics

  name = each.key
}

# Replaces the default topic policy: account principals keep full use; non-TLS is denied.
resource "aws_sns_topic_policy" "scan" {
  for_each = aws_sns_topic.scan

  arn = each.value.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = ["SNS:Publish", "SNS:Subscribe", "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:ListSubscriptionsByTopic"]
        Resource  = each.value.arn
      },
      merge(local.deny_insecure_transport, { Resource = each.value.arn, Action = local.sns_topic_actions }),
    ]
  })
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.scan_queues

  name                      = "${each.key}-dlq"
  message_retention_seconds = each.value.dlq_retention
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "consumer" {
  for_each = local.scan_queues

  name                       = each.key
  visibility_timeout_seconds = each.value.visibility_timeout
  message_retention_seconds  = each.value.retention
  receive_wait_time_seconds  = 20 # long polling
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })
}

# Separate resource: inline on the DLQ it would form a cycle with the redrive policy.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = local.scan_queues

  queue_url = aws_sqs_queue.dlq[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.consumer[each.key].arn]
  })
}

resource "aws_sqs_queue_policy" "consumer" {
  for_each = local.scan_queues

  queue_url = aws_sqs_queue.consumer[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSubscribedTopic"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.consumer[each.key].arn
        Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.scan[each.value.topic].arn } }
      },
      merge(local.deny_insecure_transport, { Resource = aws_sqs_queue.consumer[each.key].arn, Action = "sqs:*" }),
    ]
  })
}

# DLQs only need LabRole (IAM) access for explicit poison-message sends (Q5) and redrives.
resource "aws_sqs_queue_policy" "dlq" {
  for_each = local.scan_queues

  queue_url = aws_sqs_queue.dlq[each.key].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [merge(local.deny_insecure_transport, { Resource = aws_sqs_queue.dlq[each.key].arn, Action = "sqs:*" })]
  })
}

resource "aws_sns_topic_subscription" "consumer" {
  for_each = local.scan_queues

  topic_arn            = aws_sns_topic.scan[each.value.topic].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.consumer[each.key].arn
  raw_message_delivery = true
  filter_policy        = each.value.filter_policy == null ? null : jsonencode(each.value.filter_policy)

  # SNS can only deliver once the queue policy allows it.
  depends_on = [aws_sqs_queue_policy.consumer]
}
