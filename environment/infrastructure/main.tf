data "aws_availability_zones" "available" {
  state = "available"
}

resource "random_id" "suffix" {
  byte_length = 4
}

module "validation" {
  source = "./validation"
  region = local.region
}

# Existing network, resolved only in bring-your-own-VPC mode.
data "aws_vpc" "existing" {
  for_each = local.use_existing_vpc ? { selected = local.existing_vpc_id } : {}
  id       = each.value

  lifecycle {
    postcondition {
      condition     = length(local.existing_private_subnet_ids) > 0
      error_message = "vcluster.com/private-subnet-ids must list at least one subnet when vcluster.com/vpc-id is set."
    }
  }
}

data "aws_subnet" "existing_private" {
  for_each = local.use_existing_vpc ? toset(local.existing_private_subnet_ids) : toset([])
  id       = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == local.existing_vpc_id
      error_message = "Private subnet ${self.id} does not belong to VPC ${local.existing_vpc_id}."
    }
  }
}

data "aws_subnet" "existing_public" {
  for_each = local.use_existing_vpc ? toset(local.existing_public_subnet_ids) : toset([])
  id       = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == local.existing_vpc_id
      error_message = "Public subnet ${self.id} does not belong to VPC ${local.existing_vpc_id}."
    }
  }
}

module "vpc" {
  # Keep VPC as map to trigger the whole module recreation in case of region change.
  # Empty in bring-your-own-VPC mode: nothing is created.
  for_each = local.use_existing_vpc ? {} : { (local.region) = true }

  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.5.0"

  name = format("vcluster-vpc-%s", random_id.suffix.hex)
  cidr = local.vpc_cidr_block

  azs                    = local.azs
  private_subnets        = local.private_subnets
  public_subnets         = local.public_subnets
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = {
    name = format("vcluster-vpc-%s", random_id.suffix.hex)
  }
}


################################################################################
# VPC Endpoints for Systems Manager (SSM)
# Required for private nodes to register with SSM and report to vCluster.
# These endpoints are always created, whether using new or existing VPC.
################################################################################

resource "aws_security_group" "vpc_endpoints" {
  name        = format("vcluster-vpc-endpoints-sg-%s", random_id.suffix.hex)
  description = "Security group for VPC endpoints: allow HTTPS from worker nodes"
  vpc_id      = local.vpc_id

  # Allow HTTPS from worker nodes (explicit)
  ingress {
    description     = "HTTPS from worker nodes"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.workers.id]
  }

  # Also allow from VPC CIDR as fallback
  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    name = format("vcluster-vpc-endpoints-sg-%s", random_id.suffix.hex)
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${local.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    name = format("vcluster-ssm-endpoint-%s", random_id.suffix.hex)
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${local.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    name = format("vcluster-ssmmessages-endpoint-%s", random_id.suffix.hex)
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${local.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    name = format("vcluster-ec2messages-endpoint-%s", random_id.suffix.hex)
  }
}
