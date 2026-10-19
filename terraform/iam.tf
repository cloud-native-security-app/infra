# Replaces the former 03-iam-roles.sh. The Learner Lab denies iam:CreateRole, so
# every ECS task uses the pre-existing LabRole as both task and execution role.
data "aws_iam_role" "lab" {
  name = local.lab_role_name
}
