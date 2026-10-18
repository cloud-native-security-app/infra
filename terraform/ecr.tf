# Mirrors deploy/aws/02-ecr-repos.sh without rabbitmq-custom (SNS/SQS replace RabbitMQ).
# postgres and mongo use public mirrors, so they have no repo here.
resource "aws_ecr_repository" "app" {
  for_each = local.ecr_repositories

  name = each.value
  # MUTABLE while deploy/aws still pushes :latest; revisit once CI pushes SHA tags.
  image_tag_mutability = "MUTABLE"
  # Lab stack: images are rebuildable, so destroy must not get stuck on them.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Each :latest push leaves the previous image untagged; drop those after a week.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
