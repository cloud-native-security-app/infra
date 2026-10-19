# Replaces the former 04-network.sh. RabbitMQ ports (5672/5671/15672) are gone:
# messaging moved to SNS/SQS, which tasks reach through egress.

locals {
  alb_public_ports = { for p in [80, 443, 8080] : tostring(p) => p }
  # postgres, mongo, and the HTTP services (user-service, gateway, front).
  internal_service_ports = { for p in [5432, 27017, 8080] : tostring(p) => p }
  container_port         = 8080
}

resource "aws_security_group" "alb" {
  name        = local.alb_sg_name
  description = "Public ingress to the ${var.project} ALB"
  vpc_id      = local.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_public" {
  for_each = local.alb_public_ports

  security_group_id = aws_security_group.alb.id
  description       = "Public TCP ${each.value}"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "0.0.0.0/0"
}

# The ALB only forwards to tasks; it needs no other egress.
resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to ECS tasks"
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.internal.id
}

resource "aws_security_group" "internal" {
  name        = local.internal_sg_name
  description = "Traffic between ${var.project} ECS tasks"
  vpc_id      = local.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "internal_self" {
  for_each = local.internal_service_ports

  security_group_id            = aws_security_group.internal.id
  description                  = "Task to task TCP ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.internal.id
}

# Without this rule the ALB marks front/gateway targets unhealthy.
resource "aws_vpc_security_group_ingress_rule" "internal_from_alb" {
  security_group_id            = aws_security_group.internal.id
  description                  = "ALB to container port"
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

# ECR pulls, SQS/SNS, CloudWatch Logs, SSM, and nmap-service scan targets.
resource "aws_vpc_security_group_egress_rule" "internal_all" {
  security_group_id = aws_security_group.internal.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
