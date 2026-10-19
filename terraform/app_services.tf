# Replaces the former task-defs JSON and tier1/tier2/front deploy scripts for the four app services.
# Terraform only creates the services with a complete bootstrap task definition so the
# stack runs before any CI exists; each service repo's CI registers later revisions, so
# the services ignore task_definition changes. CI task definitions must reference the
# same SSM parameter names as below.

# Replace the hardcoded dev secrets of the legacy JSON. No special characters: they end up
# in headers and URLs. The values also sit in the encrypted S3 state; ECS injects them
# through `secrets`.
resource "random_password" "gateway_shared_secret" {
  length  = 48
  special = false
}

resource "random_id" "credentials_encryption_key" {
  byte_length = 32 # 32 bytes -> 64 hex characters, the key size user-service expects
}

resource "random_password" "session_signing_key" {
  length  = 64
  special = false
}

# Shared by user-service (GATEWAY_SHARED_SECRET) and gateway (MS_USUARIOS_SHARED_SECRET).
resource "aws_ssm_parameter" "gateway_shared_secret" {
  name  = "/${var.project}/gateway-shared-secret"
  type  = "SecureString"
  value = random_password.gateway_shared_secret.result
}

resource "aws_ssm_parameter" "credentials_encryption_key" {
  name  = "/${var.project}/user-service/credentials-encryption-key"
  type  = "SecureString"
  value = random_id.credentials_encryption_key.hex
}

resource "aws_ssm_parameter" "session_signing_key" {
  name  = "/${var.project}/gateway/session-signing-key"
  type  = "SecureString"
  value = random_password.session_signing_key.result
}

# Google OAuth client of the gateway. Terraform only seeds a placeholder; the real values
# are written by scripts/set-google-oauth.sh, so the secret never enters Terraform state.
resource "aws_ssm_parameter" "google_oauth" {
  for_each = toset(["client-id", "client-secret"])

  name  = "/${var.project}/gateway/google-${each.key}"
  type  = "SecureString"
  value = "unset-run-scripts-set-google-oauth"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "database_url" {
  name  = "/${var.project}/user-service/database-url"
  type  = "SecureString"
  value = "postgres://postgres:${random_password.postgres.result}@postgres:5432/usuarios"
}

locals {
  # service_connect: "publish" = client and server (user-service), "client" = client only,
  # "none" = no configuration at all (front, as in 13-deploy-front.sh).
  # target_group: key of aws_lb_target_group.app when the service sits behind the ALB.
  app_services = {
    user-service = {
      port            = 8080
      service_connect = "publish"
      target_group    = null
      environment = {
        HTTP_HOST = "0.0.0.0"
        HTTP_PORT = "8080"
        RUST_LOG  = "info,user_service=debug,tower_http=debug"
      }
      secrets = {
        DATABASE_URL               = aws_ssm_parameter.database_url.arn
        GATEWAY_SHARED_SECRET      = aws_ssm_parameter.gateway_shared_secret.arn
        CREDENTIALS_ENCRYPTION_KEY = aws_ssm_parameter.credentials_encryption_key.arn
      }
    }
    # The gateway/nmap-service code still speaks AMQP until MSG-GW/MSG-NM land, so these two
    # start but will not process scans yet. Variable names follow the services' sqs-sns-adapter tasks.
    nmap-service = {
      port            = null
      service_connect = "client"
      target_group    = null
      environment = {
        MS_NMAP_MONGO_URI                    = "mongodb://mongo:27017/?directConnection=true"
        MS_NMAP_MONGO_DB                     = "db-nmap"
        MS_NMAP_SSH_PORT                     = "22"
        MS_NMAP_NVD_ENRICHMENT_ENABLED       = "false"
        MS_NMAP_SCAN_TIMING                  = "aggressive"
        MS_NMAP_SSH_CONNECT_TIMEOUT_SECS     = tostring(var.ssh_connect_timeout_secs)
        MS_NMAP_SSH_COMMAND_TIMEOUT_SECS     = tostring(var.ssh_command_timeout_secs)
        AWS_REGION                           = var.region
        MS_NMAP_SCAN_REQUESTS_QUEUE_URL      = aws_sqs_queue.consumer["ms-nmap-scan-requests"].id
        MS_NMAP_SCAN_CANCELLATIONS_QUEUE_URL = aws_sqs_queue.consumer["ms-nmap-scan-cancellations"].id
        MS_NMAP_SCAN_OUTCOMES_TOPIC_ARN      = aws_sns_topic.scan["scan-outcomes"].arn
        MS_NMAP_SCAN_REQUESTS_DLQ_URL        = aws_sqs_queue.dlq["ms-nmap-scan-requests"].id
        MS_NMAP_SCAN_CANCELLATIONS_DLQ_URL   = aws_sqs_queue.dlq["ms-nmap-scan-cancellations"].id
      }
      secrets = {}
    }
    gateway = {
      port            = 8080
      service_connect = "client"
      target_group    = "gateway"
      environment = {
        HTTP_HOST                               = "0.0.0.0"
        HTTP_PORT                               = "8080"
        GOOGLE_REDIRECT_URI                     = "https://${aws_lb.main.dns_name}:8080/auth/callback"
        FRONT_BASE_URL                          = "https://${aws_lb.main.dns_name}"
        SESSION_TTL_SECS                        = "3600"
        MS_USUARIOS_BASE_URL                    = "http://user-service:8080"
        SCAN_SUBMISSION_RATE_LIMIT_MAX_REQUESTS = "5"
        SCAN_SUBMISSION_RATE_LIMIT_WINDOW_SECS  = "60"
        AWS_REGION                              = var.region
        SCAN_REQUESTS_TOPIC_ARN                 = aws_sns_topic.scan["scan-requests"].arn
        SCAN_CANCELLATIONS_TOPIC_ARN            = aws_sns_topic.scan["scan-cancellations"].arn
        GATEWAY_SCAN_OUTCOMES_QUEUE_URL         = aws_sqs_queue.consumer["gateway-scan-outcomes"].id
        GATEWAY_SCAN_OUTCOMES_DLQ_URL           = aws_sqs_queue.dlq["gateway-scan-outcomes"].id
      }
      secrets = {
        MS_USUARIOS_SHARED_SECRET = aws_ssm_parameter.gateway_shared_secret.arn
        SESSION_SIGNING_KEY       = aws_ssm_parameter.session_signing_key.arn
        GOOGLE_CLIENT_ID          = aws_ssm_parameter.google_oauth["client-id"].arn
        GOOGLE_CLIENT_SECRET      = aws_ssm_parameter.google_oauth["client-secret"].arn
      }
    }
    front = {
      port            = 8080
      service_connect = "none"
      target_group    = "front"
      environment     = {}
      secrets         = {}
    }
  }
}

resource "aws_ecs_task_definition" "app" {
  for_each = local.app_services

  family                   = local.task_families[each.key]
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.lab.arn
  task_role_arn            = data.aws_iam_role.lab.arn # tasks call SQS, SNS and SSM with LabRole

  container_definitions = jsonencode([merge(
    {
      name      = each.key
      image     = "${aws_ecr_repository.app[each.key].repository_url}:latest"
      essential = true
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service[each.key].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    each.value.port == null ? {} : {
      portMappings = [{ name = each.key, containerPort = each.value.port, protocol = "tcp" }]
    },
    length(each.value.environment) == 0 ? {} : {
      environment = [for name, value in each.value.environment : { name = name, value = value }]
    },
    length(each.value.secrets) == 0 ? {} : {
      secrets = [for name, arn in each.value.secrets : { name = name, valueFrom = arn }]
    },
  )])
}

resource "aws_ecs_service" "app" {
  for_each = local.app_services

  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app[each.key].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Listeners: only the two ALB services need them, but depends_on cannot be conditional
  # (a target group must be attached to a listener before a service can use it).
  # Data services: start postgres and mongo before their clients, as 21-resume.sh did.
  depends_on = [aws_lb_listener.front_https, aws_lb_listener.gateway_https, aws_ecs_service.data]

  # Only the ALB services get a grace period (it is invalid without a load balancer).
  health_check_grace_period_seconds = each.value.target_group == null ? null : 60

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.internal.id]
    assign_public_ip = true # default VPC has no NAT; needed to pull images from ECR
  }

  dynamic "service_connect_configuration" {
    for_each = each.value.service_connect == "none" ? [] : [each.value.service_connect]

    content {
      enabled   = true
      namespace = var.namespace_arn

      dynamic "service" {
        for_each = service_connect_configuration.value == "publish" ? [each.value.port] : []

        content {
          port_name = each.key
          client_alias {
            port     = service.value
            dns_name = each.key
          }
        }
      }
    }
  }

  dynamic "load_balancer" {
    for_each = each.value.target_group == null ? [] : [each.value.target_group]

    content {
      target_group_arn = aws_lb_target_group.app[load_balancer.value].arn
      container_name   = each.key
      container_port   = each.value.port
    }
  }

  # Each service repo's CI registers new task definition revisions.
  lifecycle {
    ignore_changes = [task_definition]
  }
}
