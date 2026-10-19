output "project" {
  description = "Project name prefix."
  value       = var.project
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = local.cluster_name
}

output "namespace_name" {
  description = "Cloud Map namespace name."
  value       = local.namespace_name
}

output "alb_name" {
  description = "Application Load Balancer name."
  value       = local.alb_name
}

output "alb_sg_name" {
  description = "ALB security group name."
  value       = local.alb_sg_name
}

output "internal_sg_name" {
  description = "Internal security group name."
  value       = local.internal_sg_name
}

output "alb_sg_id" {
  description = "ALB security group id."
  value       = aws_security_group.alb.id
}

output "internal_sg_id" {
  description = "Internal (ECS tasks) security group id."
  value       = aws_security_group.internal.id
}

output "log_prefix" {
  description = "CloudWatch log group prefix."
  value       = local.log_prefix
}

output "lab_role_name" {
  description = "Name of the pre-existing Learner Lab IAM role."
  value       = local.lab_role_name
}

output "lab_role_arn" {
  description = "ARN of the pre-existing Learner Lab IAM role (ECS task and execution role)."
  value       = data.aws_iam_role.lab.arn
}

output "ecr_repositories" {
  description = "ECR repository names by service."
  value       = local.ecr_repositories
}

output "ecr_repository_urls" {
  description = "ECR repository URLs by service."
  value       = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}

output "alb_dns" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.main.dns_name
}

output "front_public_url" {
  description = "Front URL (HTTPS, self-signed certificate)."
  value       = "https://${aws_lb.main.dns_name}"
}

output "gateway_public_url" {
  description = "Gateway URL (HTTPS on 8080); the OAuth redirect URI is <this>/auth/callback."
  value       = "https://${aws_lb.main.dns_name}:8080"
}

output "task_families" {
  description = "ECS task definition family names by service."
  value       = local.task_families
}

output "target_group_names" {
  description = "ALB target group names by service."
  value       = local.target_group_names
}

output "desired_count" {
  description = "Desired ECS task count (0 = paused)."
  value       = var.desired_count
}

output "vpc_id" {
  description = "Default VPC id."
  value       = local.vpc_id
}

output "subnet_ids" {
  description = "Sorted default-for-az subnet ids (at least 2 AZs for the ALB)."
  value       = local.subnet_ids

  precondition {
    condition     = length(local.subnet_ids) >= 2
    error_message = "The ALB needs subnets in at least 2 availability zones; the default VPC returned fewer."
  }
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.main.arn
}

output "namespace_arn" {
  description = "Cloud Map HTTP namespace ARN (created by scripts/bootstrap-namespace.sh)."
  value       = var.namespace_arn
}

output "log_group_names" {
  description = "CloudWatch log group names by service."
  value       = { for name, group in aws_cloudwatch_log_group.service : name => group.name }
}

output "sns_topic_arns" {
  description = "SNS topic ARNs by name (scan-requests, scan-cancellations, scan-outcomes)."
  value       = { for name, topic in aws_sns_topic.scan : name => topic.arn }
}

output "sqs_queue_urls" {
  description = "Consumer SQS queue URLs by name."
  value       = { for name, queue in aws_sqs_queue.consumer : name => queue.id }
}

output "sqs_dlq_urls" {
  description = "DLQ URLs by consumer queue name (for explicit poison-message sends)."
  value       = { for name, queue in aws_sqs_queue.dlq : name => queue.id }
}

output "scan_requests_topic_arn" {
  description = "SNS topic the gateway publishes scan requests to."
  value       = aws_sns_topic.scan["scan-requests"].arn
}

output "scan_cancellations_topic_arn" {
  description = "SNS topic the gateway publishes scan cancellations to."
  value       = aws_sns_topic.scan["scan-cancellations"].arn
}

output "scan_outcomes_topic_arn" {
  description = "SNS topic nmap-service publishes scan outcomes to."
  value       = aws_sns_topic.scan["scan-outcomes"].arn
}

output "service_names" {
  description = "All ECS service names in the cluster, sorted (for describe-services checks)."
  value       = sort(concat(keys(aws_ecs_service.data), keys(aws_ecs_service.app)))
}
