locals {
  region = nonsensitive(var.vcluster.properties["region"])
  azs    = slice(data.aws_availability_zones.available.names, 0, min(2, length(data.aws_availability_zones.available.names)))

  public_subnets  = [for idx, az in local.azs : cidrsubnet(local.vpc_cidr_block, 8, idx)]
  private_subnets = [for idx, az in local.azs : cidrsubnet(local.vpc_cidr_block, 8, idx + length(local.azs))]

  vcluster_name      = nonsensitive(var.vcluster.instance.metadata.name)
  vcluster_namespace = nonsensitive(var.vcluster.instance.metadata.namespace)

  # API endpoint can come from explicit property OR instance networking.hostname
  # To set explicitly, add to NodeProvider or vCluster instance:
  #   vcluster.com/api-endpoint: mycluster.example.com
  vcluster_hostname = nonsensitive(try(
    var.vcluster.properties["vcluster.com/api-endpoint"] != "" ? var.vcluster.properties["vcluster.com/api-endpoint"] : var.vcluster.instance.spec.networking.hostname,
    ""
  ))

  cluster_tag = {
    format("kubernetes.io/cluster/%s", local.vcluster_name) = "owned"
  }

  vpc_cidr_block = nonsensitive(try(var.vcluster.properties["vcluster.com/vpc-cidr"], "10.0.0.0/16"))
  ccm_enabled    = nonsensitive(try(tobool(var.vcluster.properties["vcluster.com/ccm-enabled"]), true))
  csi_enabled    = nonsensitive(try(tobool(var.vcluster.properties["vcluster.com/csi-enabled"]), true))

  # ── Bring-your-own-VPC mode ────────────────────────────────────────────
  # When vcluster.com/vpc-id is set, no VPC is created: nodes are placed in
  # the provided existing subnets. The worker security group and instance
  # profile are still created per virtual cluster, inside the existing VPC.
  existing_vpc_id             = trimspace(nonsensitive(try(var.vcluster.properties["vcluster.com/vpc-id"], "")))
  existing_private_subnet_ids = compact([for s in split(",", nonsensitive(try(var.vcluster.properties["vcluster.com/private-subnet-ids"], ""))) : trimspace(s)])
  existing_public_subnet_ids  = compact([for s in split(",", nonsensitive(try(var.vcluster.properties["vcluster.com/public-subnet-ids"], ""))) : trimspace(s)])
  use_existing_vpc            = local.existing_vpc_id != ""

  # Effective network, existing or created. Fallback references are wrapped
  # in try() because module.vpc has zero instances in existing-VPC mode.
  vpc_id             = local.use_existing_vpc ? local.existing_vpc_id : try(module.vpc[local.region].vpc_id, null)
  vpc_cidr           = local.use_existing_vpc ? data.aws_vpc.existing["selected"].cidr_block : local.vpc_cidr_block
  private_subnet_ids = local.use_existing_vpc ? local.existing_private_subnet_ids : try(module.vpc[local.region].private_subnets, [])
  public_subnet_ids  = local.use_existing_vpc ? local.existing_public_subnet_ids : try(module.vpc[local.region].public_subnets, [])

  # CSI storage-class topology must match where nodes can actually run, so
  # in existing-VPC mode the zones come from the provided subnets.
  availability_zones = local.use_existing_vpc ? distinct([for s in data.aws_subnet.existing_private : s.availability_zone]) : data.aws_availability_zones.available.names
}
