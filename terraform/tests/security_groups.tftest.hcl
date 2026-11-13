# Mocked provider: `apply` creates nothing real and resolves the overridden SG ids.
mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  namespace_arn = "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-0"
}

override_data {
  target = data.aws_vpc.default
  values = {
    id = "vpc-0123456789abcdef0"
  }
}

override_data {
  target = data.aws_subnets.default
  values = {
    ids = ["subnet-aaa", "subnet-bbb"]
  }
}

override_resource {
  target = aws_security_group.alb
  values = {
    id = "sg-alb"
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

run "alb_sg_is_public_on_listener_ports_only" {
  command = apply

  assert {
    condition     = aws_security_group.alb.name == "security-app-alb-sg" && aws_security_group.alb.vpc_id == "vpc-0123456789abcdef0"
    error_message = "ALB SG must keep the 00-env.sh name and live in the default VPC"
  }
  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.alb_public : r.from_port]) == toset([80, 443, 8080])
    error_message = "ALB SG must open exactly 80, 443 and 8080"
  }
  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.alb_public : r.cidr_ipv4 == "0.0.0.0/0" && r.from_port == r.to_port && r.ip_protocol == "tcp"])
    error_message = "ALB public rules must be single TCP ports from 0.0.0.0/0"
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.alb_to_tasks.referenced_security_group_id == "sg-internal" && aws_vpc_security_group_egress_rule.alb_to_tasks.from_port == 8080
    error_message = "ALB egress must only reach the tasks SG on the container port"
  }
}

run "internal_sg_allows_only_service_ports" {
  command = apply

  assert {
    condition     = aws_security_group.internal.name == "security-app-internal-sg"
    error_message = "internal SG must keep the 00-env.sh name"
  }
  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.internal_self : r.from_port]) == toset([5432, 27017, 8080])
    error_message = "internal SG must open postgres, mongo and 8080 only (no RabbitMQ ports: replaced by SNS/SQS)"
  }
  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.internal_self : r.referenced_security_group_id == "sg-internal" && r.cidr_ipv4 == null])
    error_message = "internal service ports must only be reachable from the internal SG itself"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.internal_from_alb.referenced_security_group_id == "sg-alb" && aws_vpc_security_group_ingress_rule.internal_from_alb.from_port == 8080
    error_message = "the ALB must reach front/gateway on 8080 for health checks"
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.internal_all.ip_protocol == "-1" && aws_vpc_security_group_egress_rule.internal_all.cidr_ipv4 == "0.0.0.0/0"
    error_message = "tasks need full egress (ECR, SQS/SNS, CloudWatch, nmap scan targets)"
  }
}

run "outputs_expose_sg_ids" {
  command = apply

  assert {
    condition     = output.alb_sg_id == "sg-alb" && output.internal_sg_id == "sg-internal"
    error_message = "SG ids must be exported for the ALB and ECS services"
  }
}

run "nmap_sg_is_isolated_from_the_internal_sg" {
  command = apply

  assert {
    condition     = aws_security_group.nmap.name == "security-app-nmap-sg" && aws_security_group.nmap.vpc_id == "vpc-0123456789abcdef0"
    error_message = "nmap-service has its own security group"
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.nmap_all.security_group_id == "sg-nmap" && aws_vpc_security_group_egress_rule.nmap_all.ip_protocol == "-1" && aws_vpc_security_group_egress_rule.nmap_all.cidr_ipv4 == "0.0.0.0/0"
    error_message = "nmap-service egress is open: it scans arbitrary targets and reaches SQS/SNS/Kinesis/ECR"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.mongo_from_nmap.security_group_id == "sg-internal" && aws_vpc_security_group_ingress_rule.mongo_from_nmap.referenced_security_group_id == "sg-nmap" && aws_vpc_security_group_ingress_rule.mongo_from_nmap.from_port == 27017 && aws_vpc_security_group_ingress_rule.mongo_from_nmap.to_port == 27017
    error_message = "Mongo (internal SG) accepts 27017 from the nmap-service SG"
  }
  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.internal_self : r.referenced_security_group_id]) == toset(["sg-internal"]) && aws_vpc_security_group_ingress_rule.internal_from_alb.referenced_security_group_id == "sg-alb"
    error_message = "no other rule on the internal SG admits the nmap-service SG (gateway, user-service, events-service, Postgres stay closed to it)"
  }
}

run "nmap_sg_has_no_ingress_and_outputs_its_id" {
  command = apply

  assert {
    condition     = output.nmap_sg_id == "sg-nmap" && output.nmap_sg_name == "security-app-nmap-sg"
    error_message = "the target scripts look the nmap-service SG up through its name and id output"
  }
}
