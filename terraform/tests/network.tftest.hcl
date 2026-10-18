mock_provider "aws" {}

run "default_vpc_and_sorted_subnets" {
  command = plan

  override_data {
    target = data.aws_vpc.default
    values = {
      id = "vpc-0123456789abcdef0"
    }
  }
  override_data {
    target = data.aws_subnets.default
    values = {
      ids = ["subnet-ccc", "subnet-aaa", "subnet-bbb"]
    }
  }

  assert {
    condition     = output.vpc_id == "vpc-0123456789abcdef0"
    error_message = "vpc_id must be the default VPC id"
  }
  assert {
    condition     = output.subnet_ids == tolist(["subnet-aaa", "subnet-bbb", "subnet-ccc"])
    error_message = "subnet_ids must be sorted for deterministic plans"
  }
  assert {
    condition     = length(output.subnet_ids) >= 2
    error_message = "the ALB needs subnets in at least 2 AZs"
  }
}

run "fewer_than_two_subnets_fails" {
  command = plan

  override_data {
    target = data.aws_vpc.default
    values = {
      id = "vpc-0123456789abcdef0"
    }
  }
  override_data {
    target = data.aws_subnets.default
    values = {
      ids = ["subnet-aaa"]
    }
  }

  expect_failures = [output.subnet_ids]
}
