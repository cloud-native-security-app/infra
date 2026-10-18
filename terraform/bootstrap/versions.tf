terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Intentionally no backend: this module uses LOCAL state (gitignored) because it
  # creates the bucket that holds the remote state of the main root module.
}
