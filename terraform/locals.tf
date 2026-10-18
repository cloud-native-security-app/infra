# Names mirror deploy/aws/00-env.sh so Terraform can adopt the same layout.
locals {
  # "-v2": the original cluster name was locked by CreateCluster idempotency in 00-env.sh.
  cluster_name     = "${var.project}-cluster-v2"
  namespace_name   = "${var.project}.local"
  alb_name         = "${var.project}-alb"
  alb_sg_name      = "${var.project}-alb-sg"
  internal_sg_name = "${var.project}-internal-sg"
  log_prefix       = "/ecs/${var.project}"

  # Learner Lab cannot create IAM roles; the data source lives in TF-06.
  lab_role_name = "LabRole"

  # Application services only; no rabbitmq repo (replaced by SNS/SQS).
  ecr_repositories = {
    for name in ["user-service", "nmap-service", "gateway", "front"] :
    name => "${var.project}/${name}"
  }

  task_families = {
    for name in ["postgres", "mongo", "user-service", "nmap-service", "gateway", "front"] :
    name => "${var.project}-${name}"
  }

  target_group_names = {
    for name in ["front", "gateway"] :
    name => "${var.project}-${name}-tg"
  }
}
