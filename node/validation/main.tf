variable "region" {
  type        = string
  description = "The AWS region"
}

variable "vcluster_hostname" {
  type        = string
  description = "vCluster external API hostname - required for nodes to reach the API server"
}

locals {
  region = nonsensitive(split(",", var.region)[0])
}

resource "null_resource" "validate" {
  lifecycle {
    precondition {
      condition     = length(trimspace(local.region)) > 0
      error_message = "Region cannot be empty. Please provide a valid AWS region."
    }

    precondition {
      condition     = local.region != "*" && !can(regex("[*?\\[\\]{}]", local.region))
      error_message = "Region cannot be a glob pattern or contain wildcards. Received: '${local.region}'"
    }

    precondition {
      condition     = var.vcluster_hostname != ""
      error_message = "vCluster hostname is required. Set vcluster.com/api-endpoint in NodeProvider properties or configure vCluster LoadBalancer/Ingress with external hostname."
    }
  }
}

output "region" {
  value = local.region
}
