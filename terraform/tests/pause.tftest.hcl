# desired_count replaces 20-pause.sh and 21-resume.sh for the whole stack.
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

run "zero_pauses_every_service" {
  command = plan

  variables {
    desired_count = 0
  }

  assert {
    condition     = length(concat(values(aws_ecs_service.data), values(aws_ecs_service.app))) == 6
    error_message = "the pause must cover all six services (2 data + 4 app)"
  }
  assert {
    condition     = alltrue([for svc in concat(values(aws_ecs_service.data), values(aws_ecs_service.app)) : svc.desired_count == 0])
    error_message = "desired_count = 0 must stop every service"
  }
  assert {
    condition     = output.desired_count == 0
    error_message = "the desired_count output must reflect the paused state"
  }
}

run "one_resumes_every_service" {
  command = plan

  assert {
    condition     = alltrue([for svc in concat(values(aws_ecs_service.data), values(aws_ecs_service.app)) : svc.desired_count == 1])
    error_message = "the default desired_count = 1 must run every service"
  }
}
