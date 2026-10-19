# Mocked aws provider; random runs for real (local secret generation only).
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

# One distinct ARN per parameter, so the tests can tell which one each secret uses.
override_resource {
  target = aws_ssm_parameter.postgres_password
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/postgres/password"
  }
}

override_resource {
  target = aws_ssm_parameter.gateway_shared_secret
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/gateway-shared-secret"
  }
}

override_resource {
  target = aws_ssm_parameter.credentials_encryption_key
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/user-service/credentials-encryption-key"
  }
}

override_resource {
  target = aws_ssm_parameter.session_signing_key
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/gateway/session-signing-key"
  }
}

override_resource {
  target = aws_ssm_parameter.database_url
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/user-service/database-url"
  }
}

run "secrets_are_generated_and_stored_in_ssm" {
  command = apply

  assert {
    condition = alltrue([
      for p in [aws_ssm_parameter.gateway_shared_secret, aws_ssm_parameter.credentials_encryption_key, aws_ssm_parameter.session_signing_key, aws_ssm_parameter.database_url] :
      p.type == "SecureString"
    ])
    error_message = "every generated secret lives in an SSM SecureString"
  }
  assert {
    condition = (
      aws_ssm_parameter.gateway_shared_secret.name == "/security-app/gateway-shared-secret" &&
      aws_ssm_parameter.credentials_encryption_key.name == "/security-app/user-service/credentials-encryption-key" &&
      aws_ssm_parameter.session_signing_key.name == "/security-app/gateway/session-signing-key" &&
      aws_ssm_parameter.database_url.name == "/security-app/user-service/database-url"
    )
    error_message = "parameter names are the contract with the service repos' CI task definitions"
  }
  assert {
    condition     = random_password.gateway_shared_secret.length == 48 && !random_password.gateway_shared_secret.special && aws_ssm_parameter.gateway_shared_secret.value == random_password.gateway_shared_secret.result
    error_message = "the gateway shared secret is 48 alphanumeric characters"
  }
  assert {
    condition     = random_password.session_signing_key.length == 64 && !random_password.session_signing_key.special && aws_ssm_parameter.session_signing_key.value == random_password.session_signing_key.result
    error_message = "the session signing key is 64 alphanumeric characters"
  }
  assert {
    condition     = random_id.credentials_encryption_key.byte_length == 32 && can(regex("^[0-9a-f]{64}$", random_id.credentials_encryption_key.hex)) && aws_ssm_parameter.credentials_encryption_key.value == random_id.credentials_encryption_key.hex
    error_message = "the credentials encryption key is 32 random bytes as 64 hex characters"
  }
  assert {
    condition     = aws_ssm_parameter.database_url.value == "postgres://postgres:${random_password.postgres.result}@postgres:5432/usuarios"
    error_message = "the database URL embeds the generated postgres password"
  }
}

run "task_definitions_are_complete_bootstrap_definitions" {
  command = apply

  assert {
    condition     = toset(keys(aws_ecs_task_definition.app)) == toset(["user-service", "nmap-service", "gateway", "front"])
    error_message = "one task definition per application service"
  }
  assert {
    condition = alltrue([for k, td in aws_ecs_task_definition.app :
      td.family == local.task_families[k] && td.network_mode == "awsvpc" && td.cpu == "256" && td.memory == "512" &&
      td.requires_compatibilities == toset(["FARGATE"]) &&
      td.execution_role_arn == "arn:aws:iam::123456789012:role/LabRole" && td.task_role_arn == "arn:aws:iam::123456789012:role/LabRole"
    ])
    error_message = "Fargate awsvpc 256/512 with LabRole as execution and task role (tasks call SQS/SNS/SSM)"
  }
  assert {
    condition = alltrue([for k, td in aws_ecs_task_definition.app :
      jsondecode(td.container_definitions)[0].name == k &&
      jsondecode(td.container_definitions)[0].image == "${aws_ecr_repository.app[k].repository_url}:latest" &&
      jsondecode(td.container_definitions)[0].logConfiguration.options["awslogs-group"] == "/ecs/security-app/${k}" &&
      jsondecode(td.container_definitions)[0].logConfiguration.options["awslogs-region"] == "us-east-1" &&
      jsondecode(td.container_definitions)[0].logConfiguration.options["awslogs-stream-prefix"] == "ecs"
    ])
    error_message = "ECR :latest images, container named after the service, per-service log group"
  }
  assert {
    condition = alltrue([for k, port in { user-service = 8080, gateway = 8080, front = 8080 } :
      jsondecode(aws_ecs_task_definition.app[k].container_definitions)[0].portMappings == [{ name = k, containerPort = port, protocol = "tcp" }]
    ])
    error_message = "named port mappings as in the legacy JSON"
  }
  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.app["nmap-service"].container_definitions)[0]), "portMappings")
    error_message = "nmap-service listens on nothing"
  }
}

run "no_secret_in_plain_environment" {
  command = apply

  assert {
    condition = alltrue([for k, td in aws_ecs_task_definition.app :
      length([for e in try(jsondecode(td.container_definitions)[0].environment, []) :
        e if contains(["GATEWAY_SHARED_SECRET", "CREDENTIALS_ENCRYPTION_KEY", "SESSION_SIGNING_KEY", "DATABASE_URL", "MS_USUARIOS_SHARED_SECRET"], e.name)
      ]) == 0
    ])
    error_message = "secret-bearing variables must come from `secrets`, never `environment`"
  }
  assert {
    condition = alltrue([for k, td in aws_ecs_task_definition.app :
      length([for e in try(jsondecode(td.container_definitions)[0].environment, []) :
        e if can(regex("devpassword|dev-shared-secret|dev-signing-key-not-for-prod|0707070707", e.value))
      ]) == 0
    ])
    error_message = "none of the legacy hardcoded secret values may remain"
  }
  assert {
    condition = alltrue([for k, td in aws_ecs_task_definition.app :
      length([for e in try(jsondecode(td.container_definitions)[0].environment, []) :
        e if can(regex("^(BROKER_|MS_NMAP_BROKER_|SSL_CERT_FILE)", e.name))
      ]) == 0
    ])
    error_message = "RabbitMQ variables are gone"
  }
}

run "secrets_come_from_the_ssm_parameters" {
  command = apply

  assert {
    condition = (
      { for s in jsondecode(aws_ecs_task_definition.app["user-service"].container_definitions)[0].secrets : s.name => s.valueFrom } == {
        DATABASE_URL               = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/user-service/database-url"
        GATEWAY_SHARED_SECRET      = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/gateway-shared-secret"
        CREDENTIALS_ENCRYPTION_KEY = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/user-service/credentials-encryption-key"
      }
    )
    error_message = "user-service secrets come from the SSM parameters"
  }
  assert {
    condition = (
      { for s in jsondecode(aws_ecs_task_definition.app["gateway"].container_definitions)[0].secrets : s.name => s.valueFrom } == {
        MS_USUARIOS_SHARED_SECRET = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/gateway-shared-secret"
        SESSION_SIGNING_KEY       = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/gateway/session-signing-key"
      }
    )
    error_message = "gateway shares the user-service's shared-secret parameter and has its own signing key"
  }
  assert {
    condition = alltrue([for k in ["nmap-service", "front"] :
      length(try(jsondecode(aws_ecs_task_definition.app[k].container_definitions)[0].secrets, [])) == 0
    ])
    error_message = "nmap-service and front have no secrets (Google OAuth stays a placeholder until TF-16)"
  }
}

run "environment_matches_the_legacy_json" {
  command = apply

  assert {
    condition = (
      { for e in jsondecode(aws_ecs_task_definition.app["user-service"].container_definitions)[0].environment : e.name => e.value } == {
        HTTP_HOST = "0.0.0.0"
        HTTP_PORT = "8080"
        RUST_LOG  = "info,user_service=debug,tower_http=debug"
      }
    )
    error_message = "user-service keeps its non-secret settings"
  }
  assert {
    condition = (
      { for e in jsondecode(aws_ecs_task_definition.app["gateway"].container_definitions)[0].environment : e.name => e.value } == {
        HTTP_HOST                               = "0.0.0.0"
        HTTP_PORT                               = "8080"
        GOOGLE_CLIENT_ID                        = "dev-placeholder"
        GOOGLE_CLIENT_SECRET                    = "dev-placeholder"
        GOOGLE_REDIRECT_URI                     = "https://security-app-alb-0.us-east-1.elb.amazonaws.com:8080/auth/callback"
        FRONT_BASE_URL                          = "https://security-app-alb-0.us-east-1.elb.amazonaws.com"
        SESSION_TTL_SECS                        = "3600"
        MS_USUARIOS_BASE_URL                    = "http://user-service:8080"
        SCAN_SUBMISSION_RATE_LIMIT_MAX_REQUESTS = "5"
        SCAN_SUBMISSION_RATE_LIMIT_WINDOW_SECS  = "60"
        AWS_REGION                              = "us-east-1"
        SCAN_REQUESTS_TOPIC_ARN                 = aws_sns_topic.scan["scan-requests"].arn
        SCAN_CANCELLATIONS_TOPIC_ARN            = aws_sns_topic.scan["scan-cancellations"].arn
        GATEWAY_SCAN_OUTCOMES_QUEUE_URL         = aws_sqs_queue.consumer["gateway-scan-outcomes"].id
        GATEWAY_SCAN_OUTCOMES_DLQ_URL           = aws_sqs_queue.dlq["gateway-scan-outcomes"].id
      }
    )
    error_message = "gateway env: legacy settings (OAuth redirect and front URL from the ALB) plus the SNS/SQS wiring"
  }
  assert {
    condition = (
      { for e in jsondecode(aws_ecs_task_definition.app["nmap-service"].container_definitions)[0].environment : e.name => e.value } == {
        MS_NMAP_MONGO_URI                    = "mongodb://mongo:27017/?directConnection=true"
        MS_NMAP_MONGO_DB                     = "db-nmap"
        MS_NMAP_SSH_PORT                     = "22"
        MS_NMAP_NVD_ENRICHMENT_ENABLED       = "false"
        MS_NMAP_SCAN_TIMING                  = "aggressive"
        MS_NMAP_SSH_CONNECT_TIMEOUT_SECS     = "10"
        MS_NMAP_SSH_COMMAND_TIMEOUT_SECS     = "900"
        AWS_REGION                           = "us-east-1"
        MS_NMAP_SCAN_REQUESTS_QUEUE_URL      = aws_sqs_queue.consumer["ms-nmap-scan-requests"].id
        MS_NMAP_SCAN_CANCELLATIONS_QUEUE_URL = aws_sqs_queue.consumer["ms-nmap-scan-cancellations"].id
        MS_NMAP_SCAN_OUTCOMES_TOPIC_ARN      = aws_sns_topic.scan["scan-outcomes"].arn
        MS_NMAP_SCAN_REQUESTS_DLQ_URL        = aws_sqs_queue.dlq["ms-nmap-scan-requests"].id
        MS_NMAP_SCAN_CANCELLATIONS_DLQ_URL   = aws_sqs_queue.dlq["ms-nmap-scan-cancellations"].id
      }
    )
    error_message = "nmap-service env: legacy settings plus the SNS/SQS wiring"
  }
  assert {
    condition     = length(try(jsondecode(aws_ecs_task_definition.app["front"].container_definitions)[0].environment, [])) == 0
    error_message = "front has no environment"
  }
}

run "nmap_ssh_timeouts_follow_the_variables" {
  command = apply

  variables {
    ssh_connect_timeout_secs = 20
    ssh_command_timeout_secs = 300
  }

  assert {
    condition = (
      { for e in jsondecode(aws_ecs_task_definition.app["nmap-service"].container_definitions)[0].environment : e.name => e.value }["MS_NMAP_SSH_CONNECT_TIMEOUT_SECS"] == "20" &&
      { for e in jsondecode(aws_ecs_task_definition.app["nmap-service"].container_definitions)[0].environment : e.name => e.value }["MS_NMAP_SSH_COMMAND_TIMEOUT_SECS"] == "300"
    )
    error_message = "the SSH timeouts that size the SQS visibility timeout also configure nmap-service"
  }
}

run "services_run_the_bootstrap_definitions" {
  command = apply

  assert {
    condition     = toset(keys(aws_ecs_service.app)) == toset(["user-service", "nmap-service", "gateway", "front"])
    error_message = "one ECS service per application service"
  }
  assert {
    condition = alltrue([for k, svc in aws_ecs_service.app :
      svc.name == k && svc.launch_type == "FARGATE" && svc.desired_count == 1 &&
      svc.task_definition == aws_ecs_task_definition.app[k].arn &&
      svc.network_configuration[0].assign_public_ip &&
      svc.network_configuration[0].security_groups == toset(["sg-internal"]) &&
      svc.network_configuration[0].subnets == toset(["subnet-aaa", "subnet-bbb"])
    ])
    error_message = "services start from the bootstrap task definition on Fargate in the internal SG with a public IP"
  }
}

run "service_connect_matches_the_scripts" {
  command = apply

  assert {
    condition = (
      aws_ecs_service.app["user-service"].service_connect_configuration[0].enabled &&
      aws_ecs_service.app["user-service"].service_connect_configuration[0].namespace == "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-0" &&
      aws_ecs_service.app["user-service"].service_connect_configuration[0].service[0].port_name == "user-service" &&
      aws_ecs_service.app["user-service"].service_connect_configuration[0].service[0].client_alias[0].dns_name == "user-service" &&
      aws_ecs_service.app["user-service"].service_connect_configuration[0].service[0].client_alias[0].port == 8080
    )
    error_message = "user-service publishes user-service:8080"
  }
  assert {
    condition = alltrue([for k in ["nmap-service", "gateway"] :
      aws_ecs_service.app[k].service_connect_configuration[0].enabled &&
      aws_ecs_service.app[k].service_connect_configuration[0].namespace == "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-0" &&
      length(aws_ecs_service.app[k].service_connect_configuration[0].service) == 0
    ])
    error_message = "nmap-service and gateway are Service Connect clients only"
  }
  assert {
    condition     = length(aws_ecs_service.app["front"].service_connect_configuration) == 0
    error_message = "front has no Service Connect configuration"
  }
}

run "alb_services_attach_to_their_target_groups" {
  command = apply

  assert {
    condition = alltrue([for k in ["gateway", "front"] :
      length(aws_ecs_service.app[k].load_balancer) == 1 &&
      one(aws_ecs_service.app[k].load_balancer).target_group_arn == aws_lb_target_group.app[k].arn &&
      one(aws_ecs_service.app[k].load_balancer).container_name == k &&
      one(aws_ecs_service.app[k].load_balancer).container_port == 8080 &&
      aws_ecs_service.app[k].health_check_grace_period_seconds == 60
    ])
    error_message = "gateway and front register 8080 in their target groups with a health check grace period"
  }
  assert {
    condition     = alltrue([for k in ["user-service", "nmap-service"] : length(aws_ecs_service.app[k].load_balancer) == 0])
    error_message = "internal services are not behind the ALB"
  }
}

run "desired_count_zero_pauses_app_services" {
  command = plan

  variables {
    desired_count = 0
  }

  assert {
    condition     = alltrue([for svc in aws_ecs_service.app : svc.desired_count == 0])
    error_message = "desired_count must drive the application services too"
  }
}
