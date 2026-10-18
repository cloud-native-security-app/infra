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
