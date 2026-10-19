# The Cloud Map namespace is created outside Terraform by scripts/bootstrap-namespace.sh:
# the Learner Lab denies servicediscovery:CreateHttpNamespace (ECS creates it instead) and
# servicediscovery:GetNamespace (so no data source); its ARN arrives as var.namespace_arn.
resource "aws_ecs_cluster" "main" {
  name = local.cluster_name

  service_connect_defaults {
    namespace = var.namespace_arn
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# One log group per ECS service (08-ecs-cluster-namespace-logs.sh); no rabbitmq.
resource "aws_cloudwatch_log_group" "service" {
  for_each = local.task_families

  name              = "${local.log_prefix}/${each.key}"
  retention_in_days = 3
}
