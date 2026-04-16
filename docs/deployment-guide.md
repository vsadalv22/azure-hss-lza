# Deployment Guide — WA Health HSS Azure Landing Zone

**Estimated time:** 4–6 hours for full platform deployment  
**Prerequisites:** Azure CLI, Bicep CLI, PowerShell 7+, GitHub CLI or Azure DevOps access

---

## Architecture Overview

```
                     Internet
                        │
              ┌─────────▼──────────┐
              │  vnet-ingress-*     │  10.1.0.0/16
              │  ┌──────────────┐  │
              │  │ Checkpoint   │  │  VMSS (2 instances)
              │  │  VMSS eth0   │  │  External LB
              │  └──────┬───────┘  │
              └─────────┼──────────┘
                        │ VNet Peering
              ┌─────────▼──────────┐
              │  vnet-hub-*        │  10.0.0.0/16
              │  ┌──────────────┐  │
              │  │ Checkpoint   │  │  Internal LB (10.x.1.4)
              │  │  VMSS eth1   │  │
              │  └──────┬───────┘  │
              │  ┌──────▼───────┐  │
              │  │  ER Gateway  │  │  ErGw1AZ
              │  └──────┬───────┘  │
              └─────────┼──────────┘
                        │ ExpressRoute (manual)
              ┌─────────▼──────────┐
              │   On-Premises      │  NextDC P1/P2 Perth
              └────────────────────┘
```

---

## Pre-Deployment

### 1. GitHub / Azure DevOps Setup

```bash
# Clone the repository
git clone https://github.com/vsadalv22/azure-hss-lza.git
cd azure-hss-lza

# Create a service principal with OIDC (no client secret)
az ad app create --display-name "hss-platform-alz-sp"
az ad sp create --id <app-id>

# Configure federated credential for GitHub Actions
az ad app federated-credential create \
  --id <app-id> \
  --parameters '{
    "name": "github-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:vsadalv22/azure-hss-lza:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# Assign roles
az role assignment create \
  --assignee <sp-object-id> \
  --role "Management Group Contributor" \
  --scope /providers/Microsoft.Management/managementGroups/<root-mg>
```

### 2. GitHub Secrets / Variables

Set in GitHub → Settings → Secrets and variables → Actions:

| Name | Type | Value |
|------|------|-------|
| `AZURE_TENANT_ID` | Variable | Your Entra ID tenant ID |
| `AZURE_CLIENT_ID` | Variable | Service principal app ID |
| `CONNECTIVITY_SUBSCRIPTION_ID` | Variable | Connectivity subscription ID |
| `MANAGEMENT_SUBSCRIPTION_ID` | Variable | Management subscription ID |
| `IDENTITY_SUBSCRIPTION_ID` | Variable | Identity subscription ID |
| `CHECKPOINT_ADMIN_PASSWORD` | **Secret** | Initial Checkpoint password (move to KV after first deploy) |

---

## Deployment Sequence

Run pipelines in this order. Each depends on outputs from previous stages.

```
Pipeline 01 → Pipeline 02 → Pipeline 03 → Pipeline 06
                                ↓
                         Pipeline 03b (after manual ER)
                                ↓
                    Pipeline 04 (per subscription request)
                         Pipeline 05
                         Pipeline 07
```

### Stage 1: Management Groups
```bash
# GitHub Actions
gh workflow run 01-platform-management-groups.yml --ref main

# Azure DevOps
az pipelines run --name "01 — Management Groups"
```
**Outputs used by:** all subsequent pipelines

### Stage 2: Logging
```bash
gh workflow run 02-platform-logging.yml --ref main
```
**Outputs used by:** connectivity, sentinel, monitoring, subscription vending  
**Capture:** `LOG_ANALYTICS_WORKSPACE_ID`

### Stage 3: Connectivity
```bash
gh workflow run 03-platform-connectivity.yml --ref main \
  --field checkpoint_sku=sg-byol \
  --field er_gateway_sku=ErGw1AZ
```
**Duration:** ~45 minutes (ER Gateway takes ~30 min)  
**Outputs to capture:**
- `HUB_VNET_ID`
- `ROUTE_TABLE_ID`
- `ER_GATEWAY_ID`
- `MANAGEMENT_SUBNET_ID`
- `CHECKPOINT_INTERNAL_LB_ID`

### Stage 3b: ER Connection (after provider provisioning)
```bash
# Only after network team confirms: Provider Status = Provisioned
gh workflow run 03b-platform-er-connection.yml --ref main \
  --field er_circuit_resource_id="/subscriptions/.../expressRouteCircuits/..."
```

### Stage 4: Platform Security (Key Vault + Immutable Storage)
```bash
gh workflow run 06-platform-security.yml --ref main
```
**Post-deploy manual steps:**
1. Create `checkpoint-admin-password` secret in Key Vault
2. Grant LAW Managed Identity `Key Vault Crypto User` role

### Stage 5: Sentinel
```bash
gh workflow run 05-platform-sentinel.yml --ref main
```

### Stage 6: Monitoring
```bash
gh workflow run 07-platform-monitoring.yml --ref main
```

---

## Vending a New Subscription

1. Open a GitHub Issue using the **Subscription Request** template
2. Fill in all required fields (application, HSP ID, CIDR range, etc.)
3. Platform team creates `.bicepparam` file in `subscription-vending/parameters/`
4. Pipeline `04-subscription-vending.yml` runs automatically on merge
5. 4-stage approval: Validate → What-If → 3-team review → Deploy

---

## Post-Deployment Checklist

See `docs/security-baseline.md` → Section 8 for the full checklist.

Key items:
- [ ] Configure Checkpoint (see `docs/checkpoint-first-boot.md`)
- [ ] Enable PIM for privileged roles in Entra ID
- [ ] Create Conditional Access policies
- [ ] Verify all Sentinel analytics rules are triggering correctly
- [ ] Run Defender for Cloud recommendations review
