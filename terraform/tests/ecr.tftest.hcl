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

run "four_app_repositories" {
  command = plan

  assert {
    condition     = toset([for r in aws_ecr_repository.app : r.name]) == toset(["security-app/user-service", "security-app/nmap-service", "security-app/gateway", "security-app/front"])
    error_message = "exactly the 4 app repos must exist (no rabbitmq-custom: RabbitMQ replaced by SNS/SQS)"
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.app : r.image_scanning_configuration[0].scan_on_push])
    error_message = "every repo must scan on push, as 02-ecr-repos.sh did"
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.app : r.image_tag_mutability == "MUTABLE"])
    error_message = "tags stay mutable while push-images.sh pushes :latest"
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.app : r.force_delete])
    error_message = "terraform destroy must be able to remove repos that still hold images"
  }
}

run "untagged_images_expire" {
  command = plan

  assert {
    condition     = length(aws_ecr_lifecycle_policy.app) == 4
    error_message = "every repo needs a lifecycle policy"
  }
  assert {
    condition     = alltrue([for p in aws_ecr_lifecycle_policy.app : jsondecode(p.policy).rules[0].selection.tagStatus == "untagged"])
    error_message = "the lifecycle policy must only expire untagged images"
  }
}

run "outputs_expose_repository_urls" {
  command = apply

  override_resource {
    target = aws_ecr_repository.app["front"]
    values = {
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/security-app/front"
    }
  }

  assert {
    condition     = keys(output.ecr_repository_urls) == ["front", "gateway", "nmap-service", "user-service"]
    error_message = "repository URLs must be exported by service"
  }
  assert {
    condition     = output.ecr_repository_urls["front"] == "123456789012.dkr.ecr.us-east-1.amazonaws.com/security-app/front"
    error_message = "front URL must come from the repository resource"
  }
}
