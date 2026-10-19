variable "region" {
  description = "AWS region. The Learner Lab only supports us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used as the prefix of every resource name (PROJECT in deploy/aws/00-env.sh)."
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
