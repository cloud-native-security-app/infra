mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

run "bucket_name_uses_project_and_account" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "security-app-tfstate-123456789012"
    error_message = "bucket name must be <project>-tfstate-<account_id>"
  }
  assert {
    condition     = output.state_bucket_name == "security-app-tfstate-123456789012"
    error_message = "state_bucket_name output must expose the bucket name"
  }
}

run "bucket_name_follows_project" {
  command = plan

  variables {
    project = "other-app"
  }

  assert {
    condition     = aws_s3_bucket.state.bucket == "other-app-tfstate-123456789012"
    error_message = "bucket name must follow var.project"
  }
}

run "bucket_is_protected" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.force_destroy == false
    error_message = "force_destroy must be false"
  }
}

run "versioning_enabled" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "versioning must be Enabled"
  }
}

run "sse_aes256" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "default encryption must be AES256"
  }
}

run "public_access_fully_blocked" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "all four public access block flags must be true"
  }
}

run "policy_denies_insecure_transport" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement :
      s.Effect == "Deny" && s.Principal == "*" && s.Condition.Bool["aws:SecureTransport"] == "false"
      && contains(s.Resource, "arn:aws:s3:::security-app-tfstate-123456789012/*")
    ])
    error_message = "bucket policy must deny requests where aws:SecureTransport is false"
  }
}
