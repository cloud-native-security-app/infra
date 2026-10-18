mock_provider "aws" {
  source = "./tests/mocks"
}

override_data {
  target = data.aws_subnets.default
  values = {
    ids = ["subnet-aaa", "subnet-bbb"]
  }
}

# The lab denies servicediscovery:GetNamespace, so the ARN comes in as a variable
# (printed by scripts/bootstrap-namespace.sh) instead of a data source.
variables {
  namespace_arn = "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-abc"
}

run "cluster_uses_namespace_from_variable" {
  command = apply

  assert {
    condition     = aws_ecs_cluster.main.name == "security-app-cluster-v2"
    error_message = "the cluster must keep the 00-env.sh name"
  }
  assert {
    condition     = aws_ecs_cluster.main.service_connect_defaults[0].namespace == "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-abc"
    error_message = "Service Connect defaults must point at the namespace ARN"
  }
}

run "fargate_is_default_capacity_provider" {
  command = apply

  assert {
    condition     = aws_ecs_cluster_capacity_providers.main.capacity_providers == toset(["FARGATE"])
    error_message = "only FARGATE is enabled"
  }
  assert {
    condition     = length(aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy) == 1 && alltrue([for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s.capacity_provider == "FARGATE" && s.weight == 1])
    error_message = "the default strategy must be FARGATE weight 1"
  }
}

run "log_groups_per_service_with_three_day_retention" {
  command = apply

  assert {
    condition     = toset(keys(aws_cloudwatch_log_group.service)) == toset(["postgres", "mongo", "user-service", "nmap-service", "gateway", "front"])
    error_message = "one log group per service, none for rabbitmq"
  }
  assert {
    condition     = alltrue([for k, g in aws_cloudwatch_log_group.service : g.name == "/ecs/security-app/${k}" && g.retention_in_days == 3])
    error_message = "log groups must be /ecs/security-app/<service> with 3-day retention"
  }
}

run "outputs_expose_cluster_and_namespace" {
  command = apply

  assert {
    condition     = output.namespace_arn == "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-abc"
    error_message = "namespace_arn must be exported"
  }
  assert {
    condition     = output.cluster_arn == aws_ecs_cluster.main.arn
    error_message = "cluster_arn must be exported"
  }
  assert {
    condition     = output.log_group_names["gateway"] == "/ecs/security-app/gateway" && length(output.log_group_names) == 6
    error_message = "log_group_names must map every service to its log group"
  }
}

run "namespace_arn_must_be_a_cloud_map_arn" {
  command = plan

  variables {
    namespace_arn = "security-app.local"
  }

  expect_failures = [var.namespace_arn]
}
