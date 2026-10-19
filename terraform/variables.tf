variable "region" {
  description = "AWS region. The Learner Lab only supports us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used as the prefix of every resource name."
  type        = string
  default     = "security-app"
}

variable "desired_count" {
  description = "Desired task count for the ECS services. 0 pauses the stack."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count >= 0
    error_message = "desired_count must be greater than or equal to 0."
  }
}

variable "namespace_arn" {
  description = "ARN of the Cloud Map HTTP namespace printed by scripts/bootstrap-namespace.sh (export TF_VAR_namespace_arn)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:servicediscovery:[a-z0-9-]+:[0-9]{12}:namespace/ns-[a-z0-9]+$", var.namespace_arn))
    error_message = "namespace_arn must be a Cloud Map namespace ARN; run scripts/bootstrap-namespace.sh and export TF_VAR_namespace_arn."
  }
}

# nmap-service SSH timeouts (MS_NMAP_SSH_*_TIMEOUT_SECS); they also size the requests visibility timeout.
variable "ssh_connect_timeout_secs" {
  description = "nmap-service SSH connect timeout in seconds."
  type        = number
  default     = 10

  validation {
    condition     = var.ssh_connect_timeout_secs > 0
    error_message = "ssh_connect_timeout_secs must be positive."
  }
}

variable "ssh_command_timeout_secs" {
  description = "nmap-service remote nmap command timeout in seconds."
  type        = number
  default     = 900

  validation {
    # SQS caps the visibility timeout at 12 hours.
    condition     = var.ssh_command_timeout_secs > 0 && var.ssh_connect_timeout_secs + var.ssh_command_timeout_secs + 60 <= 43200
    error_message = "ssh_command_timeout_secs must be positive and keep connect + command + 60 within the 12-hour SQS visibility limit."
  }
}
