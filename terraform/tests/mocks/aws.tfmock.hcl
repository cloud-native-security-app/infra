# Shared aws mocks: the provider validates ARN shapes on apply, so random mock
# strings are not enough for resources whose ARNs feed other resources.
mock_resource "aws_lb" {
  defaults = {
    arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/security-app-alb/0"
    dns_name = "security-app-alb-0.us-east-1.elb.amazonaws.com"
  }
}

mock_resource "aws_lb_target_group" {
  defaults = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/security-app-tg/0"
  }
}

mock_resource "aws_acm_certificate" {
  defaults = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/0"
  }
}

mock_data "aws_service_discovery_http_namespace" {
  defaults = {
    arn = "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-0"
  }
}
