mock_provider "aws" {
  source = "./tests/mocks"

  # Networking data sources (network.tf) need at least 2 subnets for the output precondition.
  override_data {
    target = data.aws_subnets.default
    values = {
      ids = ["subnet-aaa", "subnet-bbb"]
    }
  }
}

run "names_match_00_env" {
  command = plan

  assert {
    condition     = output.project == "security-app"
    error_message = "project must match PROJECT in 00-env.sh"
  }
  assert {
    condition     = output.cluster_name == "security-app-cluster-v2"
    error_message = "cluster_name must match CLUSTER_NAME in 00-env.sh"
  }
  assert {
    condition     = output.namespace_name == "security-app.local"
    error_message = "namespace_name must match NAMESPACE_NAME in 00-env.sh"
  }
  assert {
    condition     = output.alb_name == "security-app-alb"
    error_message = "alb_name must match ALB_NAME in 00-env.sh"
  }
  assert {
    condition     = output.alb_sg_name == "security-app-alb-sg" && output.internal_sg_name == "security-app-internal-sg"
    error_message = "security group names must match 00-env.sh"
  }
  assert {
    condition     = output.log_prefix == "/ecs/security-app"
    error_message = "log_prefix must match LOG_PREFIX in 00-env.sh"
  }
  assert {
    condition     = output.lab_role_name == "LabRole"
    error_message = "lab_role_name must match EXEC_ROLE_NAME in 00-env.sh"
  }
  assert {
    condition = output.ecr_repositories == {
      user-service = "security-app/user-service"
      nmap-service = "security-app/nmap-service"
      gateway      = "security-app/gateway"
      front        = "security-app/front"
    }
    error_message = "ECR repos must be security-app/<name> and exclude rabbitmq"
  }
  assert {
    condition = output.task_families == {
      postgres     = "security-app-postgres"
      mongo        = "security-app-mongo"
      user-service = "security-app-user-service"
      nmap-service = "security-app-nmap-service"
      gateway      = "security-app-gateway"
      front        = "security-app-front"
    }
    error_message = "task families must match the task-defs JSON and exclude rabbitmq"
  }
  assert {
    condition     = output.target_group_names == { front = "security-app-front-tg", gateway = "security-app-gateway-tg" }
    error_message = "target group names must match 06-alb.sh"
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = var.region == "us-east-1"
    error_message = "region default must be us-east-1"
  }
  assert {
    condition     = var.desired_count == 1
    error_message = "desired_count default must be 1"
  }
}

run "negative_desired_count_rejected" {
  command = plan

  variables {
    desired_count = -1
  }

  expect_failures = [var.desired_count]
}

run "zero_desired_count_allowed" {
  command = plan

  variables {
    desired_count = 0
  }

  assert {
    condition     = var.desired_count == 0
    error_message = "0 means paused and must be accepted"
  }
}
