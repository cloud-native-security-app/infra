# Default VPC and its default-for-az subnets (replaces the lookup in deploy/aws/04-network.sh).
# All default subnets are public (MapPublicIpOnLaunch=true).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}
