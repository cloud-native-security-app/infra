# Kinesis Data Stream for immutable domain events (admin panel feed).
# Plan: odd/tasks/kinesis-admin-panel.md (KAP-01). Producers: gateway, nmap-service, user-service.
# The consumer is the gateway. No IAM resources: tasks run as LabRole, which can read and
# write Kinesis from Fargate (KAP-00b). The stream name reaches the services as the plain
# environment variable SECURITY_EVENTS_STREAM_NAME (see app_services.tf).

resource "aws_kinesis_stream" "security_events" {
  name             = "security-events"
  shard_count      = 1
  retention_period = 24 # hours

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  # AWS-managed key only: the lab cannot create customer-managed keys or key policies.
  # LabRole use of this key is unverified; set security_events_encryption = "NONE" if it fails.
  encryption_type = var.security_events_encryption
  kms_key_id      = var.security_events_encryption == "KMS" ? "alias/aws/kinesis" : null
}
