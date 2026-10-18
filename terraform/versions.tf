terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Partial configuration: key, region and locking come from backend.hcl and the
  # bucket from -backend-config="bucket=..." (see README.md). Plain `init` needs
  # AWS; verify and the tests use `init -backend=false`.
  backend "s3" {}
}
