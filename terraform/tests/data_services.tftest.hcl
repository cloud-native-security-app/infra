# Mocked aws provider; random runs for real (local password generation only).
mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  namespace_arn = "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-0"
}

override_data {
  target = data.aws_subnets.default
  values = {
    ids = ["subnet-aaa", "subnet-bbb"]
  }
}

override_data {
  target = data.aws_iam_role.lab
  values = {
    arn = "arn:aws:iam::123456789012:role/LabRole"
  }
}

override_resource {
  target = aws_security_group.internal
  values = {
    id = "sg-internal"
  }
}

override_resource {
  target = aws_ssm_parameter.postgres_password
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/postgres/password"
  }
}

run "postgres_password_is_generated_and_stored_in_ssm" {
  command = apply

  assert {
    condition     = random_password.postgres.length >= 32 && !random_password.postgres.special
    error_message = "the password must be long and URL-safe (it ends up in user-service's database URL)"
  }
  assert {
    condition     = aws_ssm_parameter.postgres_password.name == "/security-app/postgres/password" && aws_ssm_parameter.postgres_password.type == "SecureString"
    error_message = "the password lives in an SSM SecureString"
  }
  assert {
    condition     = aws_ssm_parameter.postgres_password.value == random_password.postgres.result
    error_message = "SSM must hold the generated password"
  }
}

run "task_definitions_match_the_legacy_json" {
  command = apply

  assert {
    condition     = toset(keys(aws_ecs_task_definition.data)) == toset(["postgres", "mongo"])
    error_message = "one task definition per data service"
  }
  assert {
    condition = alltrue([for k, td in aws_ecs_task_definition.data :
      td.family == "security-app-${k}" && td.network_mode == "awsvpc" && td.cpu == "256" && td.memory == "512" &&
      td.requires_compatibilities == toset(["FARGATE"]) && td.execution_role_arn == "arn:aws:iam::123456789012:role/LabRole"
    ])
    error_message = "Fargate awsvpc 256/512 with LabRole as execution role, families from 00-env.sh"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.data["postgres"].container_definitions)[0].image == "public.ecr.aws/docker/library/postgres:16-alpine" && jsondecode(aws_ecs_task_definition.data["mongo"].container_definitions)[0].image == "public.ecr.aws/docker/library/mongo:7"
    error_message = "images are the public ECR mirrors from 00-env.sh"
  }
  assert {
    condition = alltrue([for k, td in aws_ecs_task_definition.data :
      jsondecode(td.container_definitions)[0].portMappings[0].name == k &&
      jsondecode(td.container_definitions)[0].logConfiguration.options["awslogs-group"] == "/ecs/security-app/${k}"
    ])
    error_message = "named port mappings (Service Connect) and the per-service log group"
  }
}

run "postgres_password_is_injected_as_a_secret" {
  command = apply

  assert {
    condition     = length([for e in jsondecode(aws_ecs_task_definition.data["postgres"].container_definitions)[0].environment : e if e.name == "POSTGRES_PASSWORD"]) == 0
    error_message = "the password must not be a plain environment variable"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.data["postgres"].container_definitions)[0].secrets == [{ name = "POSTGRES_PASSWORD", valueFrom = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/postgres/password" }]
    error_message = "POSTGRES_PASSWORD comes from the SSM parameter"
  }
  assert {
    condition     = toset([for e in jsondecode(aws_ecs_task_definition.data["postgres"].container_definitions)[0].environment : "${e.name}=${e.value}"]) == toset(["POSTGRES_USER=postgres", "POSTGRES_DB=usuarios"])
    error_message = "postgres keeps its user and database names"
  }
}

run "services_join_service_connect" {
  command = apply

  assert {
    condition = alltrue([for k, svc in aws_ecs_service.data :
      svc.name == k && svc.launch_type == "FARGATE" && svc.desired_count == 1 &&
      svc.network_configuration[0].assign_public_ip &&
      svc.network_configuration[0].security_groups == toset(["sg-internal"]) &&
      svc.network_configuration[0].subnets == toset(["subnet-aaa", "subnet-bbb"])
    ])
    error_message = "services run on Fargate in the internal SG with a public IP (no NAT for image pulls)"
  }
  assert {
    condition = alltrue([for k, port in { postgres = 5432, mongo = 27017 } :
      aws_ecs_service.data[k].service_connect_configuration[0].enabled &&
      aws_ecs_service.data[k].service_connect_configuration[0].namespace == "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-0" &&
      aws_ecs_service.data[k].service_connect_configuration[0].service[0].port_name == k &&
      aws_ecs_service.data[k].service_connect_configuration[0].service[0].client_alias[0].dns_name == k &&
      aws_ecs_service.data[k].service_connect_configuration[0].service[0].client_alias[0].port == port
    ])
    error_message = "Service Connect aliases postgres:5432 and mongo:27017"
  }
}

run "desired_count_zero_pauses_data_services" {
  command = plan

  variables {
    desired_count = 0
  }

  assert {
    condition     = alltrue([for svc in aws_ecs_service.data : svc.desired_count == 0])
    error_message = "desired_count must drive the data services too"
  }
}
