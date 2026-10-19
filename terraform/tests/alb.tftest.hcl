# Mocked aws provider; tls runs for real (local key and certificate generation only).
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

override_resource {
  target = aws_security_group.alb
  values = {
    id = "sg-alb"
  }
}

override_resource {
  target = aws_lb.main
  values = {
    arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/security-app-alb/123"
    dns_name = "security-app-alb-123.us-east-1.elb.amazonaws.com"
  }
}

override_resource {
  target = aws_lb_target_group.app["front"]
  values = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/security-app-front-tg/1"
  }
}

override_resource {
  target = aws_lb_target_group.app["gateway"]
  values = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/security-app-gateway-tg/2"
  }
}

override_resource {
  target = aws_acm_certificate.alb
  values = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc"
  }
}

run "alb_is_public_in_default_subnets" {
  command = apply

  assert {
    condition     = aws_lb.main.name == "security-app-alb" && aws_lb.main.load_balancer_type == "application" && !aws_lb.main.internal
    error_message = "the ALB must be internet-facing and keep the 00-env.sh name"
  }
  assert {
    condition     = toset(aws_lb.main.subnets) == toset(["subnet-aaa", "subnet-bbb"]) && toset(aws_lb.main.security_groups) == toset(["sg-alb"])
    error_message = "the ALB must use the default subnets and the ALB SG"
  }
  assert {
    condition     = aws_lb.main.drop_invalid_header_fields
    error_message = "the ALB must drop invalid HTTP headers"
  }
}

run "target_groups_match_06_alb" {
  command = apply

  assert {
    condition     = aws_lb_target_group.app["front"].name == "security-app-front-tg" && aws_lb_target_group.app["front"].health_check[0].path == "/"
    error_message = "front TG must keep its name and health check on /"
  }
  assert {
    condition     = aws_lb_target_group.app["gateway"].name == "security-app-gateway-tg" && aws_lb_target_group.app["gateway"].health_check[0].path == "/health"
    error_message = "gateway TG must keep its name and health check on /health"
  }
  assert {
    condition = alltrue([for tg in aws_lb_target_group.app :
      tg.port == 8080 && tg.protocol == "HTTP" && tg.target_type == "ip" &&
      tg.health_check[0].interval == 15 && tg.health_check[0].healthy_threshold == 2 && tg.health_check[0].unhealthy_threshold == 3
    ])
    error_message = "TGs must target container port 8080 by IP (awsvpc) with the 06-alb.sh health check timings"
  }
}

run "self_signed_certificate_covers_alb_dns" {
  command = apply

  assert {
    condition     = tls_self_signed_cert.alb.subject[0].common_name == "security-app-alb-123.us-east-1.elb.amazonaws.com" && tls_self_signed_cert.alb.dns_names == tolist(["security-app-alb-123.us-east-1.elb.amazonaws.com"])
    error_message = "the certificate CN and SAN must be the ALB DNS name"
  }
  assert {
    condition     = contains(tls_self_signed_cert.alb.allowed_uses, "server_auth")
    error_message = "the certificate must allow TLS server auth"
  }
  assert {
    condition     = aws_acm_certificate.alb.certificate_body == tls_self_signed_cert.alb.cert_pem
    error_message = "ACM must import the generated certificate"
  }
}

run "https_listeners_and_http_redirect" {
  command = apply

  assert {
    condition     = aws_lb_listener.http.port == 80 && aws_lb_listener.http.default_action[0].type == "redirect" && aws_lb_listener.http.default_action[0].redirect[0].port == "443" && aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS"
    error_message = "port 80 must redirect to HTTPS 443"
  }
  assert {
    condition     = aws_lb_listener.front_https.port == 443 && aws_lb_listener.front_https.protocol == "HTTPS" && aws_lb_listener.front_https.default_action[0].target_group_arn == "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/security-app-front-tg/1"
    error_message = "443 must serve front over HTTPS"
  }
  assert {
    condition     = aws_lb_listener.gateway_https.port == 8080 && aws_lb_listener.gateway_https.protocol == "HTTPS" && aws_lb_listener.gateway_https.default_action[0].target_group_arn == "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/security-app-gateway-tg/2"
    error_message = "8080 must serve gateway over HTTPS"
  }
  assert {
    condition     = alltrue([for l in [aws_lb_listener.front_https, aws_lb_listener.gateway_https] : l.certificate_arn == "arn:aws:acm:us-east-1:123456789012:certificate/abc" && startswith(l.ssl_policy, "ELBSecurityPolicy-TLS13")])
    error_message = "HTTPS listeners must use the imported certificate and a TLS 1.3 policy"
  }
}

run "outputs_expose_public_urls" {
  command = apply

  assert {
    condition     = output.alb_dns == "security-app-alb-123.us-east-1.elb.amazonaws.com"
    error_message = "alb_dns must be exported"
  }
  assert {
    condition     = output.front_public_url == "https://security-app-alb-123.us-east-1.elb.amazonaws.com" && output.gateway_public_url == "https://security-app-alb-123.us-east-1.elb.amazonaws.com:8080"
    error_message = "public URLs must match what 15-enable-https-gateway.sh wrote to .state/"
  }
}
