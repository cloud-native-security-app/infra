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

output "log_prefix" {
  description = "CloudWatch log group prefix."
  value       = local.log_prefix
}

output "lab_role_name" {
  description = "Name of the pre-existing Learner Lab IAM role."
  value       = local.lab_role_name
}

output "ecr_repositories" {
  description = "ECR repository names by service."
  value       = local.ecr_repositories
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
