# vCluster Node Sync Issues - Troubleshooting Guide

## Symptom
Nodes fail to provision with error in vCluster logs:
```
ERROR   karpenter      state/cluster.go:135     cluster is waiting on sync for extended duration
Duration: 300+ seconds, continuously increasing
Error: "waiting on cluster sync"
```

## Root Cause
**Karpenter (vCluster's auto-node provisioning system) cannot reach the vCluster API server.**

The issue occurs because:
1. vCluster control plane starts successfully (etcd, apiserver running)
2. But Karpenter inside vCluster tries to contact the infrastructure/host to provision nodes
3. It cannot find the API endpoint to connect to
4. Without successful sync, nodes are never provisioned

## Solution

### Required: Set vCluster API Endpoint in NodeProvider

Your NodeProvider MUST specify the external DNS endpoint so that:
- Nodes can bootstrap and reach the API server
- Karpenter can coordinate with the infrastructure

**Edit your NodeProvider to include:**

```yaml
apiVersion: management.loft.sh/v1
kind: NodeProvider
metadata:
  name: auto-nodes-aws
spec:
  terraform:
    # ... existing config ...
  
  # ADD THIS SECTION:
  properties:
  - key: vcluster.com/api-endpoint
    required: true
    defaultValue: "vcluster.marina.viasat.io"  # ⬅️ SET YOUR ACTUAL ENDPOINT
```

### Finding Your vCluster's External Endpoint

**Option 1: LoadBalancer Service (Recommended)**
```bash
kubectl get svc -n loft-conserv-v-<vcluster-name> <vcluster-name>
# Look for EXTERNAL-IP or use LoadBalancer hostname
```

**Option 2: Ingress Hostname**
```bash
kubectl get ingress -n loft-conserv-v-<vcluster-name>
# Use the hostname from the ingress
```

**Option 3: DNS Name**
```bash
# If you have a DNS CNAME pointing to your vCluster's LoadBalancer
# Use that FQDN
```

### Apply the Fix

1. **Update your NodeProvider:**
   ```bash
   kubectl patch nodeprovider auto-nodes-aws -p '{"spec":{"properties":[{"key":"vcluster.com/api-endpoint","required":true,"defaultValue":"YOUR.ENDPOINT.HERE"}]}}'
   ```

2. **Terminate broken node to trigger reprovisioning:**
   ```bash
   # In AWS console or CLI, terminate the node with the "waiting on cluster sync" error
   # Karpenter will automatically provision a new one with correct API endpoint
   ```

3. **Verify new node provisioning:**
   - Check vCluster logs: `kubectl logs -f <vcluster-pod> -c syncer`
   - Karpenter errors should stop appearing
   - New node should reach API server and begin joining

## How It Works

```
NodeProvider property vcluster.com/api-endpoint
  ↓
environment/infrastructure/locals.tf reads it
  ↓  
environment/infrastructure/outputs.tf exports as api_endpoint
  ↓
node/main.tf receives it via nodeEnvironment outputs
  ↓
node/locals.tf sets vcluster_hostname
  ↓
vCluster platform uses it when generating bootstrap user_data
  ↓
Nodes receive kubeconfig with CORRECT external API endpoint
  ↓
Nodes can reach API server ✓
Karpenter can sync ✓
```

## Validation

The system now validates that api-endpoint is set. If you try to provision a node without it, you'll see:
```
Error: vCluster hostname is required. 
Set vcluster.com/api-endpoint in NodeProvider properties or configure 
vCluster LoadBalancer/Ingress with external hostname.
```

## Prevention

Always set `vcluster.com/api-endpoint` when creating a NodeProvider for private/auto-nodes setups.
