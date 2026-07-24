data "aws_ami" "ami" {
  most_recent = true
  owners      = ["099720109477"] # Canonical 

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

module "validation" {
  source            = "./validation"
  region            = var.vcluster.properties["region"]
  vcluster_hostname = local.vcluster_hostname
}

resource "random_integer" "subnet_index" {
  min = 0
  max = length(var.vcluster.nodeEnvironment.outputs.infrastructure["private_subnet_ids"]) - 1
}

# Inject external API endpoint into kubeconfig if provided
# The vCluster platform generates userData with internal ClusterIP,
# but nodes need the external hostname to reach the API server.
# Since vCluster generates userData after Terraform runs, we inject a
# post-boot script that will update the kubeconfig at runtime.
locals {
  # Patch the runcmd script to use external hostname instead of internal 172.x.x.x API
  # vCluster platform generates userData with internal ClusterIP (172.20.39.181),
  # but nodes need the external hostname to reach the API server from private VPC
  runcmd_patch = local.vcluster_hostname != "" ? base64encode(<<-SCRIPT
#!/bin/bash
# Patch vCluster's generated runcmd script to use external endpoint
# This must run BEFORE runcmd executes so the node join connects to the correct endpoint

export EXTERNAL_HOST="${local.vcluster_hostname}"
RUNCMD_SCRIPT="/var/lib/cloud/instance/scripts/runcmd"

echo "===== [$(date -u)] RUNCMD PATCH STARTING ====="
echo "External Host: $EXTERNAL_HOST"
echo ""

# Wait for cloud-init to generate the runcmd script (max 30 seconds)
echo "[runcmd-patch] Waiting for cloud-init runcmd script..."
for attempt in {1..30}; do
  if [ -f "$RUNCMD_SCRIPT" ]; then
    echo "[runcmd-patch] Found runcmd script at attempt $attempt"
    
    # Show original
    echo "[DEBUG] Original runcmd:"
    cat "$RUNCMD_SCRIPT" | head -3
    echo ""
    
    # Patch: Replace internal 172.20.x.x addresses with external hostname
    # This fixes the node join endpoint that vCluster platform generated
    sed -i 's|https://172\.[0-9]*\.[0-9]*\.[0-9]*:443|https://'"$EXTERNAL_HOST"':443|g' "$RUNCMD_SCRIPT"
    
    # Verify patch
    if grep -q "https://$EXTERNAL_HOST:443" "$RUNCMD_SCRIPT"; then
      echo "[runcmd-patch] Successfully patched runcmd script"
      echo "[DEBUG] Patched runcmd:"
      cat "$RUNCMD_SCRIPT" | head -3
      echo ""
      echo "===== [$(date -u)] RUNCMD PATCH COMPLETE ====="
      exit 0
    else
      echo "[runcmd-patch] ERROR: Patch verification failed"
      echo "[DEBUG] After patching, runcmd contains:"
      cat "$RUNCMD_SCRIPT" | head -5
      exit 1
    fi
  fi
  sleep 1
done

# If we timeout, runcmd might not exist yet - cloud-init will retry
echo "[runcmd-patch] Timeout waiting for runcmd script (will retry later if cloud-init delays)"
exit 0
SCRIPT
  ) : ""

  # Append runcmd patch script to userData
  decoded_user_data = local.user_data != null ? try(base64decode(local.user_data), local.user_data) : ""

  # SOLUTION: Patch runcmd in bootcmd BEFORE cloud-init runcmd phase runs
  # bootcmd runs early, synchronously, and completes before runcmd phase
  # This patches the actual runcmd script that vCluster platform generated
  patch_injection = local.runcmd_patch != "" ? "\nbootcmd:\n  - echo '${local.runcmd_patch}' | base64 -d | bash" : ""

  fixed_user_data = local.user_data != null ? base64encode("${local.decoded_user_data}${local.patch_injection}") : local.user_data
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.ami.id
  instance_type               = local.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [local.security_group_id]
  user_data                   = local.fixed_user_data
  user_data_replace_on_change = true

  associate_public_ip_address = false

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  private_dns_name_options {
    hostname_type = "resource-name"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1 # Restrict IMDS to host network
  }

  iam_instance_profile = local.instance_profile_name

  tags = {
    name = format("%s-worker-node", local.vcluster_name)
  }
}
