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

run "lab_role_is_looked_up_not_created" {
  command = plan

  assert {
    condition     = data.aws_iam_role.lab.name == "LabRole"
    error_message = "the data source must look up the pre-existing LabRole (no iam:CreateRole in the Learner Lab)"
  }
  assert {
    condition     = output.lab_role_arn == "arn:aws:iam::123456789012:role/LabRole"
    error_message = "lab_role_arn must expose the looked-up role ARN for ECS task and execution roles"
  }
}
