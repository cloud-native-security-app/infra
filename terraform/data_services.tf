# Replaces the former postgres/mongo task-defs and tier0 deploy script (without rabbitmq).
# Terraform owns these task definitions, so no ignore_changes.
# Data lives in the task's ephemeral storage, as before: a restart starts empty.

# Replaces the hardcoded "devpassword". No special characters: user-service puts it in a URL.
resource "random_password" "postgres" {
  length  = 32
  special = false
}

# The value also sits in the encrypted S3 state. ECS injects it through `secrets`.
resource "aws_ssm_parameter" "postgres_password" {
  name  = "/${var.project}/postgres/password"
  type  = "SecureString"
  value = random_password.postgres.result
}

locals {
  data_services = {
    postgres = {
      image       = "public.ecr.aws/docker/library/postgres:16-alpine"
      port        = 5432
      environment = { POSTGRES_USER = "postgres", POSTGRES_DB = "usuarios" }
      secrets     = { POSTGRES_PASSWORD = aws_ssm_parameter.postgres_password.arn }
      health      = ["CMD-SHELL", "pg_isready -U postgres"]
    }
    mongo = {
      image       = "public.ecr.aws/docker/library/mongo:7"
      port        = 27017
      environment = {}
      secrets     = {}
      health      = ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping')"]
    }
  }
}

resource "aws_ecs_task_definition" "data" {
  for_each = local.data_services

  family                   = local.task_families[each.key]
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.lab.arn

  container_definitions = jsonencode([{
    name         = each.key
    image        = each.value.image
    essential    = true
    portMappings = [{ name = each.key, containerPort = each.value.port, protocol = "tcp" }]
    environment  = [for name, value in each.value.environment : { name = name, value = value }]
    secrets      = [for name, arn in each.value.secrets : { name = name, valueFrom = arn }]
    healthCheck = {
      command     = each.value.health
      interval    = 15
      timeout     = 5
      retries     = 10
      startPeriod = 10
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service[each.key].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "data" {
  for_each = local.data_services

  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.data[each.key].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.internal.id]
    assign_public_ip = true # default VPC has no NAT; needed to pull public images
  }

  service_connect_configuration {
    enabled   = true
    namespace = var.namespace_arn

    service {
      port_name = each.key
      client_alias {
        port     = each.value.port
        dns_name = each.key
      }
    }
  }
}
