# SIEM ingestion token: provisioned only when siem_enabled. Mocked aws provider; random runs for real.
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
  target = aws_security_group.nmap
  values = {
    id = "sg-nmap"
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
  target = aws_ssm_parameter.google_oauth["client-id"]
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/gateway/google-client-id"
  }
}

override_resource {
  target = aws_ssm_parameter.google_oauth["client-secret"]
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/gateway/google-client-secret"
  }
}

override_resource {
  target = aws_ssm_parameter.smtp["host"]
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/user-service/smtp-host"
  }
}

override_resource {
  target = aws_ssm_parameter.smtp["port"]
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/user-service/smtp-port"
  }
}

override_resource {
  target = aws_ssm_parameter.smtp["username"]
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/user-service/smtp-username"
  }
}

override_resource {
  target = aws_ssm_parameter.smtp["password"]
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/user-service/smtp-password"
  }
}

override_resource {
  target = aws_ssm_parameter.gateway_shared_secret
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/gateway-shared-secret"
  }
}

override_resource {
  target = aws_ssm_parameter.events_service_shared_secret
  values = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/security-app/events-service/gateway-shared-secret"
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

run "siem_disabled_by_default_provisions_nothing" {
  command = apply

  assert {
    condition     = length(aws_ssm_parameter.siem_ingest_token) == 0 && length(random_password.siem_ingest_token) == 0
    error_message = "with siem_enabled=false there is no SIEM SSM parameter and no random token"
  }
  assert {
    condition = !contains(
      [for s in jsondecode(aws_ecs_task_definition.app["gateway"].container_definitions)[0].secrets : s.name],
      "SIEM_INGEST_TOKEN"
    )
    error_message = "the gateway must not receive SIEM_INGEST_TOKEN when SIEM is disabled"
  }
  assert {
    condition = !contains(
      [for e in jsondecode(aws_ecs_task_definition.app["events-service"].container_definitions)[0].environment : e.name],
      "SIEM_ENABLED"
    )
    error_message = "events-service gets no SIEM_ENABLED when disabled (its default is false)"
  }
}

run "siem_enabled_stores_the_token_in_ssm_and_wires_the_services" {
  command = apply

  variables {
    siem_enabled = true
  }

  assert {
    condition = (
      aws_ssm_parameter.siem_ingest_token[0].name == "/security-app/gateway/siem-ingest-token" &&
      aws_ssm_parameter.siem_ingest_token[0].type == "SecureString" &&
      aws_ssm_parameter.siem_ingest_token[0].value == random_password.siem_ingest_token[0].result &&
      random_password.siem_ingest_token[0].length == 48 && !random_password.siem_ingest_token[0].special
    )
    error_message = "the token is a random 48-character password stored as a SecureString"
  }
  assert {
    condition = (
      { for s in jsondecode(aws_ecs_task_definition.app["gateway"].container_definitions)[0].secrets : s.name => s.valueFrom }["SIEM_INGEST_TOKEN"]
      == aws_ssm_parameter.siem_ingest_token[0].arn
    )
    error_message = "the gateway reads SIEM_INGEST_TOKEN from the SSM parameter through `secrets`"
  }
  assert {
    condition = !contains(
      [for e in jsondecode(aws_ecs_task_definition.app["gateway"].container_definitions)[0].environment : e.name],
      "SIEM_INGEST_TOKEN"
    )
    error_message = "the token never travels as a plain environment value"
  }
  assert {
    condition = (
      { for e in jsondecode(aws_ecs_task_definition.app["events-service"].container_definitions)[0].environment : e.name => e.value }["SIEM_ENABLED"] == "true"
    )
    error_message = "events-service runs with SIEM_ENABLED=true"
  }
}
