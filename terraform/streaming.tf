# Kinesis Data Stream for immutable domain events (admin panel feed).
# Plan: odd/tasks/kinesis-admin-panel.md (KAP-01). Producers: gateway, nmap-service, user-service.
# The consumer is the gateway. No IAM resources: tasks run as LabRole, which can read and
# write Kinesis from Fargate (KAP-00b). The stream name reaches the services as the plain
# environment variable SECURITY_EVENTS_STREAM_NAME (see app_services.tf).
#
# In the Learner Lab the stream is created with the AWS CLI and imported (terraform/README.md,
# "Event stream"). Reason: on create, the aws provider always calls IncreaseStreamRetentionPeriod
# (its schema defaults retention_period to 24), and the lab SCP denies that action. On update the
# provider calls it only when retention changes, so an imported stream is managed normally.
# No import block: terraform test mock providers cannot import.

resource "aws_kinesis_stream" "security_events" {
  name        = "security-events"
  shard_count = 1
  # Retention stays at the AWS default (24 h); changing it is denied by the lab SCP.

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  # AWS-managed key only: the lab cannot create customer-managed keys or key policies.
  # LabRole can write and read a stream encrypted with this key from Fargate (KMS spike, 2026-11-10).
  encryption_type = var.security_events_encryption
  kms_key_id      = var.security_events_encryption == "KMS" ? "alias/aws/kinesis" : null
}
