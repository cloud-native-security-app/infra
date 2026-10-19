# Outputs that replace deploy/aws/.state/*.txt and feed CI and the verify check (TF-15).
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
  target = aws_sns_topic.scan["scan-cancellations"]
  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:scan-cancellations"
  }
}

override_resource {
  target = aws_sns_topic.scan["scan-outcomes"]
  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:scan-outcomes"
  }
}

run "named_topic_arns" {
  command = apply

  assert {
    condition     = output.scan_requests_topic_arn == "arn:aws:sns:us-east-1:123456789012:scan-requests"
    error_message = "scan_requests_topic_arn must be the requests topic"
  }
  assert {
    condition     = output.scan_cancellations_topic_arn == "arn:aws:sns:us-east-1:123456789012:scan-cancellations"
    error_message = "scan_cancellations_topic_arn must be the cancellations topic"
  }
  assert {
    condition     = output.scan_outcomes_topic_arn == "arn:aws:sns:us-east-1:123456789012:scan-outcomes"
    error_message = "scan_outcomes_topic_arn must be the outcomes topic"
  }
}

run "service_names_cover_the_stack" {
  command = apply

  assert {
    condition     = output.service_names == tolist(["front", "gateway", "mongo", "nmap-service", "postgres", "user-service"])
    error_message = "service_names must list all six ECS services, sorted"
  }
}

run "queue_urls_cover_every_consumer" {
  command = apply

  assert {
    condition     = keys(output.sqs_queue_urls) == ["gateway-scan-outcomes", "ms-nmap-scan-cancellations", "ms-nmap-scan-requests"] && keys(output.sqs_dlq_urls) == keys(output.sqs_queue_urls)
    error_message = "queue and DLQ URLs must be exported for every consumer"
  }
}
