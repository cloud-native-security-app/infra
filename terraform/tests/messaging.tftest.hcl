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

override_resource {
  target = aws_sns_topic.scan["scan-requests"]
  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:scan-requests"
  }
}

override_resource {
  target = aws_sqs_queue.consumer["ms-nmap-scan-requests"]
  values = {
    arn = "arn:aws:sqs:us-east-1:123456789012:ms-nmap-scan-requests"
    id  = "https://sqs.us-east-1.amazonaws.com/123456789012/ms-nmap-scan-requests"
  }
}

override_resource {
  target = aws_sqs_queue.dlq["ms-nmap-scan-requests"]
  values = {
    arn = "arn:aws:sqs:us-east-1:123456789012:ms-nmap-scan-requests-dlq"
    id  = "https://sqs.us-east-1.amazonaws.com/123456789012/ms-nmap-scan-requests-dlq"
  }
}

run "topics_and_queues_match_the_signed_off_topology" {
  command = apply

  assert {
    condition     = toset([for t in aws_sns_topic.scan : t.name]) == toset(["scan-requests", "scan-cancellations", "scan-outcomes"])
    error_message = "one SNS topic per former exchange"
  }
  assert {
    condition     = toset([for q in aws_sqs_queue.consumer : q.name]) == toset(["ms-nmap-scan-requests", "ms-nmap-scan-cancellations", "gateway-scan-outcomes"])
    error_message = "the 3 consumer queues keep the MSG-01 names; ms-analisis is deferred (Q7)"
  }
  assert {
    condition     = toset([for q in aws_sqs_queue.dlq : q.name]) == toset(["ms-nmap-scan-requests-dlq", "ms-nmap-scan-cancellations-dlq", "gateway-scan-outcomes-dlq"])
    error_message = "every consumer queue has a <name>-dlq"
  }
  assert {
    condition     = alltrue([for q in concat(values(aws_sqs_queue.consumer), values(aws_sqs_queue.dlq)) : q.sqs_managed_sse_enabled && q.fifo_queue != true && !endswith(q.name, ".fifo")])
    error_message = "standard queues with SSE-SQS (Q3, Q4)"
  }
}

run "redrive_after_three_receives" {
  command = apply

  assert {
    condition     = alltrue([for k, q in aws_sqs_queue.consumer : jsondecode(q.redrive_policy).maxReceiveCount == 3 && jsondecode(q.redrive_policy).deadLetterTargetArn == aws_sqs_queue.dlq[k].arn])
    error_message = "each queue redrives to its own DLQ after 3 receives"
  }
  assert {
    condition = alltrue([for k, p in aws_sqs_queue_redrive_allow_policy.dlq :
      jsondecode(p.redrive_allow_policy).redrivePermission == "byQueue" &&
      jsondecode(p.redrive_allow_policy).sourceQueueArns == [aws_sqs_queue.consumer[k].arn]
    ])
    error_message = "a DLQ only accepts redrive from its own source queue"
  }
}

run "requests_queue_timeouts_and_retention" {
  command = apply

  assert {
    condition     = aws_sqs_queue.consumer["ms-nmap-scan-requests"].visibility_timeout_seconds == 10 + 900 + 300 + 60
    error_message = "visibility = SSH connect + SSH command timeout + NVD enrichment budget + margin (Q1)"
  }
  assert {
    condition     = aws_sqs_queue.consumer["ms-nmap-scan-requests"].message_retention_seconds == 4200 && aws_sqs_queue.dlq["ms-nmap-scan-requests"].message_retention_seconds == 86400
    error_message = "requests carry SSH credentials: 70 min retention, DLQ 24 h (Q4)"
  }
  assert {
    condition     = alltrue([for q in aws_sqs_queue.consumer : q.message_retention_seconds > 3 * q.visibility_timeout_seconds])
    error_message = "every queue must keep a failing message longer than maxReceiveCount (3) visibility cycles, or it expires before reaching its DLQ"
  }
  assert {
    condition     = aws_sqs_queue.consumer["ms-nmap-scan-cancellations"].message_retention_seconds == 345600 && aws_sqs_queue.dlq["gateway-scan-outcomes"].message_retention_seconds == 1209600
    error_message = "other queues keep the SQS defaults (4 days, DLQs 14 days)"
  }
}

run "visibility_follows_the_ssh_timeouts" {
  command = plan

  variables {
    ssh_connect_timeout_secs   = 20
    ssh_command_timeout_secs   = 600
    local_scan_timeout_secs    = 300
    nvd_enrichment_budget_secs = 120
  }

  assert {
    condition     = aws_sqs_queue.consumer["ms-nmap-scan-requests"].visibility_timeout_seconds == 20 + 600 + 120 + 60
    error_message = "the visibility timeout must be derived from the SSH timeout variables"
  }
}

run "subscriptions_are_raw_and_filtered" {
  command = apply

  assert {
    condition     = alltrue([for s in aws_sns_topic_subscription.consumer : s.protocol == "sqs" && s.raw_message_delivery])
    error_message = "SNS -> SQS with raw delivery so the body is the bare JSON contract"
  }
  assert {
    condition     = aws_sns_topic_subscription.consumer["ms-nmap-scan-requests"].topic_arn == "arn:aws:sns:us-east-1:123456789012:scan-requests" && aws_sns_topic_subscription.consumer["ms-nmap-scan-requests"].endpoint == "arn:aws:sqs:us-east-1:123456789012:ms-nmap-scan-requests"
    error_message = "the requests queue subscribes to the requests topic"
  }
  assert {
    condition     = jsondecode(aws_sns_topic_subscription.consumer["gateway-scan-outcomes"].filter_policy) == { routing_key = [{ prefix = "scan.outcome." }] }
    error_message = "the gateway receives every scan.outcome.* (MSG-01)"
  }
  assert {
    condition     = aws_sns_topic_subscription.consumer["ms-nmap-scan-requests"].filter_policy == null && aws_sns_topic_subscription.consumer["ms-nmap-scan-cancellations"].filter_policy == null
    error_message = "single-routing-key topics need no filter"
  }
}

run "queue_policies_restrict_to_topic_and_tls" {
  command = apply

  assert {
    condition = anytrue([for s in jsondecode(aws_sqs_queue_policy.consumer["ms-nmap-scan-requests"].policy).Statement :
      s.Effect == "Allow" && s.Principal == { Service = "sns.amazonaws.com" } && s.Action == "sqs:SendMessage" &&
      s.Condition.ArnEquals["aws:SourceArn"] == "arn:aws:sns:us-east-1:123456789012:scan-requests"
    ])
    error_message = "only the matching topic may send to the queue"
  }
  assert {
    condition = alltrue([for p in concat(values(aws_sqs_queue_policy.consumer), values(aws_sqs_queue_policy.dlq), values(aws_sns_topic_policy.scan)) :
      anytrue([for s in jsondecode(p.policy).Statement : s.Effect == "Deny" && s.Condition.Bool["aws:SecureTransport"] == "false"])
    ])
    error_message = "every queue, DLQ and topic denies non-TLS access"
  }
  assert {
    condition     = length([for s in jsondecode(aws_sqs_queue_policy.dlq["ms-nmap-scan-requests"].policy).Statement : s if s.Effect == "Allow"]) == 0
    error_message = "DLQs grant nothing beyond the account's IAM (LabRole) access"
  }
}

run "outputs_expose_topics_and_queues" {
  command = apply

  assert {
    condition     = output.sns_topic_arns["scan-requests"] == "arn:aws:sns:us-east-1:123456789012:scan-requests" && length(output.sns_topic_arns) == 3
    error_message = "topic ARNs must be exported by name"
  }
  assert {
    condition     = output.sqs_queue_urls["ms-nmap-scan-requests"] == "https://sqs.us-east-1.amazonaws.com/123456789012/ms-nmap-scan-requests" && output.sqs_dlq_urls["ms-nmap-scan-requests"] == "https://sqs.us-east-1.amazonaws.com/123456789012/ms-nmap-scan-requests-dlq"
    error_message = "queue and DLQ URLs must be exported (consumers need the DLQ URL for explicit sends, Q5)"
  }
}

run "topic_policies_only_use_actions_sns_accepts" {
  command = apply

  # SNS rejects wildcards and non-topic actions in a topic policy
  # ("Policy statement action out of service scope"), found on the first live apply.
  assert {
    condition = alltrue(flatten([for p in aws_sns_topic_policy.scan : [
      for s in jsondecode(p.policy).Statement : [
        for a in flatten([s.Action]) : contains([
          "SNS:Publish", "SNS:Subscribe", "SNS:Receive", "SNS:GetTopicAttributes", "SNS:SetTopicAttributes",
          "SNS:AddPermission", "SNS:RemovePermission", "SNS:DeleteTopic", "SNS:ListSubscriptionsByTopic",
        ], a)
      ]
    ]]))
    error_message = "topic policies may only list the SNS topic actions, without wildcards"
  }
}

run "visibility_covers_a_long_local_scan" {
  command = plan

  variables {
    local_scan_timeout_secs = 1800
  }

  assert {
    condition     = aws_sqs_queue.consumer["ms-nmap-scan-requests"].visibility_timeout_seconds == 1800 + 300 + 60
    error_message = "the visibility timeout must exceed the local (network) scan timeout plus the NVD budget and margin"
  }
}

run "nvd_enrichment_budget_is_validated" {
  command = plan

  variables {
    nvd_enrichment_budget_secs = 0
  }

  expect_failures = [var.nvd_enrichment_budget_secs]
}

run "nvd_enrichment_budget_respects_the_sqs_limit" {
  command = plan

  variables {
    nvd_enrichment_budget_secs = 43200
  }

  expect_failures = [var.nvd_enrichment_budget_secs]
}

run "report_email_queue_and_dlq" {
  command = apply

  assert {
    condition     = aws_sqs_queue.report_emails.name == "user-service-report-emails" && aws_sqs_queue.report_emails_dlq.name == "user-service-report-emails-dlq"
    error_message = "user-service sends report emails to its own queue and DLQ, outside the SNS-fed scan queues"
  }
  assert {
    condition     = aws_sqs_queue.report_emails.sqs_managed_sse_enabled && aws_sqs_queue.report_emails_dlq.sqs_managed_sse_enabled && aws_sqs_queue.report_emails.fifo_queue != true
    error_message = "standard queues with SSE-SQS"
  }
  assert {
    condition     = aws_sqs_queue.report_emails.visibility_timeout_seconds == 120 && aws_sqs_queue.report_emails.receive_wait_time_seconds == 20
    error_message = "120 s visibility (one SMTP attempt per receive, retried about 2 minutes later) and long polling"
  }
  assert {
    condition     = aws_sqs_queue.report_emails_dlq.message_retention_seconds == local.sqs_default_dlq_retention
    error_message = "the DLQ keeps messages for the default 14 days"
  }
  assert {
    condition     = jsondecode(aws_sqs_queue.report_emails.redrive_policy).maxReceiveCount == 3 && jsondecode(aws_sqs_queue.report_emails.redrive_policy).deadLetterTargetArn == aws_sqs_queue.report_emails_dlq.arn
    error_message = "the report email queue redrives to its DLQ after 3 receives"
  }
  assert {
    condition = (
      jsondecode(aws_sqs_queue_redrive_allow_policy.report_emails_dlq.redrive_allow_policy).redrivePermission == "byQueue" &&
      jsondecode(aws_sqs_queue_redrive_allow_policy.report_emails_dlq.redrive_allow_policy).sourceQueueArns == [aws_sqs_queue.report_emails.arn]
    )
    error_message = "the DLQ only accepts redrive from the report email queue"
  }
  assert {
    condition = alltrue([for p in [aws_sqs_queue_policy.report_emails.policy, aws_sqs_queue_policy.report_emails_dlq.policy] :
      length(jsondecode(p).Statement) == 1 &&
      jsondecode(p).Statement[0].Sid == "DenyInsecureTransport" && jsondecode(p).Statement[0].Effect == "Deny" &&
      jsondecode(p).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    ])
    error_message = "both queues deny non-TLS access and have no SNS statement (the sender is user-service through LabRole)"
  }
}
