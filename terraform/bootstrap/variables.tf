variable "region" {
  description = "AWS region. The Learner Lab only supports us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used as the prefix of the state bucket (same value as the main root module)."
  type        = string
  default     = "security-app"
}
