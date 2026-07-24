output "private_subnet_ids" {
  description = "A list of private subnet ids"
  value       = local.private_subnet_ids
}

output "public_subnet_ids" {
  description = "A list of public subnet ids"
  value       = local.public_subnet_ids
}

output "availability_zones" {
  description = "A list of availability zones"
  value       = local.availability_zones
}

output "security_group_id" {
  description = "Security group id to attach to worker nodes"
  value       = aws_security_group.workers.id
}

output "instance_profile_name" {
  description = "Instance profile name to attach to worker nodes"
  value       = aws_iam_instance_profile.vcluster_node.name
}

output "cluster_tag" {
  description = "Global tag of all provisioned AWS resources"
  value       = local.cluster_tag
}

output "api_endpoint" {
  description = "API endpoint for nodes to connect to vCluster (should be DNS resolvable from private nodes)"
  value       = local.vcluster_hostname != "" ? "https://${local.vcluster_hostname}:443" : null
  sensitive   = false
}
