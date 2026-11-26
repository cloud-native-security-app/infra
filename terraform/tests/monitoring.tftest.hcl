# DLQ depth alarms and the ops-alerts topic (RF-21).
mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  namespace_arn = "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-0"
}

override_data {
  target = data.aws_subnets.default
  values = {
    ids = ["subnet-aaa", "subnet-bbb"]
  }
}

run "one_alarm_per_dead_letter_queue" {
  command = apply

  assert {
    condition = toset([for a in aws_cloudwatch_metric_alarm.dlq_not_empty : a.alarm_name]) == toset([
      "ms-nmap-scan-requests-dlq-not-empty",
      "ms-nmap-scan-cancellations-dlq-not-empty",
      "gateway-scan-outcomes-dlq-not-empty",
      "user-service-report-emails-dlq-not-empty",
    ])
    error_message = "every scan DLQ and the report email DLQ has a <queue>-not-empty alarm"
  }
  assert {
    condition = alltrue([for a in aws_cloudwatch_metric_alarm.dlq_not_empty :
      a.dimensions["QueueName"] == trimsuffix(a.alarm_name, "-not-empty")
    ])
    error_message = "each alarm watches the queue its name says"
  }
}

run "alarm_fires_on_any_visible_message" {
  command = apply

  assert {
    condition = alltrue([for a in aws_cloudwatch_metric_alarm.dlq_not_empty :
      a.namespace == "AWS/SQS" &&
      a.metric_name == "ApproximateNumberOfMessagesVisible" &&
      a.statistic == "Maximum" &&
      a.period == 300 &&
      a.evaluation_periods == 1 &&
      a.threshold == 0 &&
      a.comparison_operator == "GreaterThanThreshold"
    ])
    error_message = "alarm when the visible depth is above 0 in a 5 minute period"
  }
  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.dlq_not_empty : a.treat_missing_data == "notBreaching"])
    error_message = "an idle queue publishes no datapoints: that is not an alarm"
  }
  assert {
    condition = alltrue([for a in aws_cloudwatch_metric_alarm.dlq_not_empty :
      a.alarm_actions == toset([aws_sns_topic.ops_alerts.arn]) && a.ok_actions == toset([aws_sns_topic.ops_alerts.arn])
    ])
    error_message = "alarm and recovery notify the ops-alerts topic"
  }
  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.dlq_not_empty : strcontains(a.alarm_description, a.dimensions["QueueName"]) && strcontains(a.alarm_description, "redrive")])
    error_message = "the description names the queue and the next step"
  }
}

run "topic_policy_lets_cloudwatch_publish_and_denies_plain_http" {
  command = apply

  assert {
    condition     = aws_sns_topic.ops_alerts.name == "ops-alerts"
    error_message = "topic is named ops-alerts"
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_sns_topic_policy.ops_alerts.policy).Statement :
      s.Effect == "Allow" &&
      s.Principal.Service == "cloudwatch.amazonaws.com" &&
      s.Action == "SNS:Publish" &&
      s.Condition.StringEquals["aws:SourceAccount"] == "123456789012"
    ])
    error_message = "CloudWatch may publish, only for alarms of this account"
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_sns_topic_policy.ops_alerts.policy).Statement :
      s.Effect == "Deny" && s.Condition.Bool["aws:SecureTransport"] == "false"
    ])
    error_message = "non-TLS access is denied"
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_sns_topic_policy.ops_alerts.policy).Statement :
      s.Effect == "Allow" && try(s.Principal.AWS == "arn:aws:iam::123456789012:root", false)
    ])
    error_message = "the account keeps access to the topic"
  }
}

run "no_subscriptions_by_default" {
  command = apply

  assert {
    condition     = length(aws_sns_topic_subscription.ops_alerts_email) == 0
    error_message = "nobody is subscribed until alarm_emails is set"
  }
  assert {
    condition     = output.ops_alerts_topic_arn == aws_sns_topic.ops_alerts.arn
    error_message = "the topic ARN is an output"
  }
}

run "one_email_subscription_per_address" {
  command = apply

  variables {
    alarm_emails = ["ops@example.com", "dev@example.com"]
  }

  assert {
    condition     = toset([for s in aws_sns_topic_subscription.ops_alerts_email : s.endpoint]) == toset(["ops@example.com", "dev@example.com"])
    error_message = "one subscription per address"
  }
  assert {
    condition     = alltrue([for s in aws_sns_topic_subscription.ops_alerts_email : s.protocol == "email" && s.topic_arn == aws_sns_topic.ops_alerts.arn])
    error_message = "email subscriptions on the ops-alerts topic"
  }
}

run "invalid_alarm_email_is_rejected" {
  command = plan

  variables {
    alarm_emails = ["not-an-email"]
  }

  expect_failures = [var.alarm_emails]
}
