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


mock_resource "aws_sns_topic" {
  defaults = {
    arn = "arn:aws:sns:us-east-1:123456789012:mock-topic"
  }
}

mock_resource "aws_sqs_queue" {
  defaults = {
    arn = "arn:aws:sqs:us-east-1:123456789012:mock-queue"
    id  = "https://sqs.us-east-1.amazonaws.com/123456789012/mock-queue"
  }
}

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "123456789012"
  }
}

mock_resource "aws_ecs_cluster" {
  defaults = {
    arn = "arn:aws:ecs:us-east-1:123456789012:cluster/security-app-cluster-v2"
    id  = "arn:aws:ecs:us-east-1:123456789012:cluster/security-app-cluster-v2"
  }
}

mock_resource "aws_ecs_task_definition" {
  defaults = {
    arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/mock:1"
  }
}

mock_resource "aws_ssm_parameter" {
  defaults = {
    arn = "arn:aws:ssm:us-east-1:123456789012:parameter/mock"
  }
}

mock_data "aws_iam_role" {
  defaults = {
    arn = "arn:aws:iam::123456789012:role/LabRole"
  }
}
