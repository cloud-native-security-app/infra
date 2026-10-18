output "state_bucket_name" {
  description = "Name of the Terraform state bucket; pass it to the main root with -backend-config."
  value       = aws_s3_bucket.state.bucket
}
