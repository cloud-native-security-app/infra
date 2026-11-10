# KAP-01: Kinesis Data Stream for domain events (admin panel feed).
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
  target = aws_kinesis_stream.security_events
  values = {
    arn = "arn:aws:kinesis:us-east-1:123456789012:stream/security-events"
  }
}

run "stream_is_provisioned_single_shard_24h" {
  command = apply

  assert {
    condition     = aws_kinesis_stream.security_events.name == "security-events"
    error_message = "the stream keeps the bare name used by SECURITY_EVENTS_STREAM_NAME (like scan-requests)"
  }
  assert {
    condition     = aws_kinesis_stream.security_events.stream_mode_details[0].stream_mode == "PROVISIONED"
    error_message = "PROVISIONED mode (no on-demand cost surprises in the lab)"
  }
  assert {
    condition     = aws_kinesis_stream.security_events.shard_count == 1 && aws_kinesis_stream.security_events.retention_period == 24
    error_message = "1 shard and 24 h retention"
  }
}

run "encrypted_with_the_aws_managed_key_by_default" {
  command = apply

  assert {
    condition     = aws_kinesis_stream.security_events.encryption_type == "KMS" && aws_kinesis_stream.security_events.kms_key_id == "alias/aws/kinesis"
    error_message = "server-side encryption with the AWS-managed Kinesis key by default"
  }
}

run "encryption_can_be_turned_off" {
  command = apply

  variables {
    security_events_encryption = "NONE"
  }

  assert {
    condition     = aws_kinesis_stream.security_events.encryption_type == "NONE" && aws_kinesis_stream.security_events.kms_key_id == null
    error_message = "NONE disables encryption and sets no key (fallback if LabRole cannot use KMS)"
  }
}

run "invalid_encryption_value_is_rejected" {
  command = plan

  variables {
    security_events_encryption = "AES"
  }

  expect_failures = [var.security_events_encryption]
}

run "outputs_expose_the_stream" {
  command = apply

  assert {
    condition     = output.security_events_stream_name == "security-events"
    error_message = "stream name output"
  }
  assert {
    condition     = output.security_events_stream_arn == "arn:aws:kinesis:us-east-1:123456789012:stream/security-events"
    error_message = "stream ARN output"
  }
}
