# Replaces the former 06-alb.sh plus the HTTPS end state of 15-enable-https-gateway.sh:
# front on 443, gateway on 8080, both HTTPS on the same host so the gateway's
# Secure + SameSite=Strict session cookie reaches the front's fetch() calls.

locals {
  target_group_health_paths = {
    front   = "/"
    gateway = "/health"
  }
  tls_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

resource "aws_lb" "main" {
  name                       = local.alb_name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = local.subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  for_each = local.target_group_health_paths

  name        = local.target_group_names[each.key]
  port        = local.container_port
  protocol    = "HTTP"
  target_type = "ip" # awsvpc tasks register by IP
  vpc_id      = local.vpc_id

  health_check {
    path                = each.value
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Self-signed, as in 15-enable-https-gateway.sh: no domain or cost; browsers warn,
# which the demo accepts. The private key lives only in the encrypted S3 state.
resource "tls_private_key" "alb" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  private_key_pem = tls_private_key.alb.private_key_pem

  subject {
    common_name = aws_lb.main.dns_name
  }
  dns_names = [aws_lb.main.dns_name]

  validity_period_hours = 24 * 365
  # A plan within 30 days of expiry replaces the certificate.
  early_renewal_hours = 24 * 30
  allowed_uses        = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "alb" {
  private_key      = tls_private_key.alb.private_key_pem
  certificate_body = tls_self_signed_cert.alb.cert_pem

  # Listeners hold the old ARN; import the new certificate before deleting it.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "front_https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = local.tls_policy
  certificate_arn   = aws_acm_certificate.alb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["front"].arn
  }
}

resource "aws_lb_listener" "gateway_https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8080
  protocol          = "HTTPS"
  ssl_policy        = local.tls_policy
  certificate_arn   = aws_acm_certificate.alb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["gateway"].arn
  }
}
