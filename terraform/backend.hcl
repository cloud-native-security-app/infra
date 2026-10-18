# Partial backend configuration for the S3 backend declared in versions.tf.
# The bucket name is NOT committed: pass it at init time (see README.md).
key          = "security-app/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true
encrypt      = true
