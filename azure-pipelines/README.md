# Azure DevOps Pipelines — ALZ Bicep (WA Health / HSS)

This directory contains the Azure DevOps YAML pipeline definitions for the ALZ Bicep
platform deployment. These pipelines replace the GitHub Actions workflows and implement
the enterprise DevSecOps platform mandated by DD03 / DD04 using Azure DevOps.

---

## Pipeline Overview and Execution Order

`00-security-checks` runs automatically on every PR and push — it is a gate, not a
deployment pipeline. All other pipelines must be run in the order shown below for
the initial platform deployment. After the platform is established, each pipeline
can run independently when its source paths change.

```
00-security-checks     (every PR + push to main/staging/prod — no deployment)
        │
        ▼
01-management-groups   (tenant scope — run once)
        │
        ▼
02-logging             (management subscription — run once)
        │
        ▼
03-connectivity        (connectivity subscription — run once)
        │
        ▼
06-platform-security   (management subscription — run after 02 + 03)
        │
        ▼
03b-er-connection      (manual trigger only — run after ER circuit is provisioned)
        │
        ▼
04-subscription-vending  (on-demand — run per subscription request)
        │
        ▼
05-sentinel            (management subscription — run once)
```

> **Why 06 runs after 03?**  `06-platform-security` deploys the platform Key Vault and
> immutable storage. It needs `HUB_VNET_ID` and `MANAGEMENT_SUBNET_ID` from pipeline 03
> to attach private endpoints. After 06 completes, its Key Vault URI output is fed back
> into pipeline 02 (re-run) to activate Customer-Managed Key (CMK) on Log Analytics.

---

## Pipeline Files

| File | Pipeline | Scope | Trigger |
|------|----------|-------|---------|
| `00-security-checks.yml` | Security Checks (lint + SAST + secrets scan) | N/A (no deployment) | Every PR to main/staging; push to main/staging/prod |
| `01-management-groups.yml` | Management Group Hierarchy | Tenant | `platform/management-groups/**` push to main |
| `02-logging.yml` | Log Analytics + Monitoring | Management subscription | `platform/logging/**` push to main |
| `03-connectivity.yml` | Hub VNet + ER Gateway + Checkpoint VMSS | Connectivity subscription | `platform/connectivity/**` push to main |
| `03b-er-connection.yml` | ExpressRoute Connection | Connectivity subscription | Manual only (`trigger: none`) |
| `04-subscription-vending.yml` | Subscription Vending Machine | Management group (EA) | `subscription-vending/parameters/**` push to main |
| `05-sentinel.yml` | Microsoft Sentinel | Management subscription | `platform/sentinel/**` push to main |
| `06-platform-security.yml` | Platform Security (Key Vault + WORM storage) | Management subscription | `platform/security/**` push to main |

---

## Prerequisites

### 1. Azure Service Connection

All pipelines authenticate to Azure using a single federated OIDC service connection.

**Service connection name:** `hss-platform-azure-sc`

To create this service connection:

1. In Azure Portal, navigate to **Azure Active Directory > App registrations**
2. Create a new app registration (or use the existing ALZ service principal)
3. Under **Certificates & secrets > Federated credentials**, add a credential:
   - Scenario: `Azure DevOps`
   - Organisation: your ADO organisation URL
   - Project: your ADO project name
   - Entity type: `Branch`
   - Branch: `main`
4. Grant the service principal the following RBAC roles:
   - **Owner** at tenant root management group scope (required for tenant-level deployments)
   - **Management Group Contributor** at root MG
   - **EA Enrollment Account Owner** (required for subscription vending)
5. In Azure DevOps, navigate to **Project Settings > Service connections > New service connection**
6. Select **Azure Resource Manager > Workload Identity federation (manual)**
7. Enter the tenant ID, subscription ID, service principal client ID, and federation subject
8. Name the connection exactly: `hss-platform-azure-sc`
9. Grant access to all pipelines

### 2. ADO Variable Groups (Library)

Two variable groups must exist in **Pipelines > Library** before running any pipeline.

#### `alz-platform-secrets` (mark all values as secret)

| Variable | Description | Set by pipeline |
|----------|-------------|-----------------|
| `AZURE_TENANT_ID` | Azure tenant ID | Manual |
| `AZURE_CLIENT_ID` | Service principal client ID (app registration) | Manual |
| `CHECKPOINT_ADMIN_PASSWORD` | Checkpoint NVA admin password (min 12 chars) | Manual |
| `CONNECTIVITY_SUBSCRIPTION_ID` | Subscription ID for connectivity resources | Manual |
| `MANAGEMENT_SUBSCRIPTION_ID` | Subscription ID for management/logging resources | Manual |
| `IDENTITY_SUBSCRIPTION_ID` | Subscription ID for identity resources | Manual |
| `LOG_ANALYTICS_WORKSPACE_ID` | Full resource ID of the Log Analytics Workspace | **Set after running pipeline 02** |
| `ER_GATEWAY_ID` | Full resource ID of the ExpressRoute Gateway | **Set after running pipeline 03** |
| `ER_CIRCUIT_RESOURCE_ID` | Full resource ID of the ER circuit (if pre-provisioned) | Manual (optional) |
| `EA_BILLING_ACCOUNT` | EA billing account name | Manual |
| `EA_ENROLLMENT_ACCOUNT` | EA enrollment account name | Manual |
| `HUB_VNET_ID` | Full resource ID of the Hub VNet | **Set after running pipeline 03** |
| `MANAGEMENT_SUBNET_ID` | Full resource ID of the management subnet in Hub VNet | **Set after running pipeline 03** |
| `ROUTE_TABLE_ID` | Full resource ID of the Hub route table | **Set after running pipeline 03** |
| `LAW_MI_PRINCIPAL_ID` | Principal ID of the Log Analytics managed identity (for CMK) | **Set after running pipeline 02** (lawManagedIdentityPrincipalId output) |
| `SENTINEL_SECURITY_CONTACT` | Email address for Defender for Cloud security alerts | Manual |

#### `alz-platform-variables` (non-secret configuration values)

| Variable | Description | Default value |
|----------|-------------|---------------|
| `LOCATION` | Primary Azure region | `australiaeast` |
| `ROOT_MG_ID` | Root management group ID | `alz` |
| `HUB_RESOURCE_GROUP` | Hub VNet resource group name | `rg-connectivity-hub-australiaeast-001` |

To create a variable group:

1. Navigate to **Pipelines > Library > + Variable group**
2. Name the group exactly as shown above
3. Add each variable — tick **Secret** for sensitive values
4. Save the group

### 3. ADO Environments

Environments provide manual approval gates. Create these in **Pipelines > Environments**
before importing the pipelines.

| Environment name | Required approvers | Used by pipeline(s) |
|------------------|--------------------|---------------------|
| `platform-production` | Platform team leads | 01, 02, 03, 03b, 05, 06 |
| `vending-network-review` | Network team | 04 |
| `vending-security-review` | Security / SOC team | 04 |
| `vending-platform-approval` | Platform team leads | 04 |

To create an environment with approvals:

1. Navigate to **Pipelines > Environments > New environment**
2. Name the environment (e.g. `platform-production`), select **None** for resource
3. Click **...** (ellipsis) > **Approvals and checks**
4. Click **+** > **Approvals**
5. Add the required approver users or groups
6. Set **Timeout**: `1 day` (adjust per team SLA)
7. Optional: tick **Notify approvers** to send email on pending approval

---

## Importing Pipelines into Azure DevOps

Import all 8 pipeline YAML files in one session. The steps are identical for each.

### Steps (repeat for each pipeline file)

1. In Azure DevOps, navigate to **Pipelines > Pipelines > New pipeline**
2. Select **Azure Repos Git** (or GitHub if the repo is mirrored)
3. Select the `alz-bicep` repository
4. Select **Existing Azure Pipelines YAML file**
5. Set **Branch** to `main`
6. Set **Path** to the pipeline YAML file (e.g. `/azure-pipelines/01-management-groups.yml`)
7. Click **Continue**
8. On the review screen, click the **Variables** tab and confirm the variable groups are linked
9. Click **Save** (do not run yet)
10. Rename the pipeline using **...** > **Rename/move** to a friendly name (e.g. `01 - Management Groups`)

### Recommended pipeline names in ADO

| YAML file | ADO pipeline name |
|-----------|-------------------|
| `00-security-checks.yml` | `00 - Security: Lint, SAST & Secrets Scan` |
| `01-management-groups.yml` | `01 - Platform: Management Groups` |
| `02-logging.yml` | `02 - Platform: Logging & Monitoring` |
| `03-connectivity.yml` | `03 - Platform: Connectivity` |
| `03b-er-connection.yml` | `03b - Platform: ExpressRoute Connection` |
| `04-subscription-vending.yml` | `04 - Subscription Vending Machine` |
| `05-sentinel.yml` | `05 - Platform: Microsoft Sentinel` |
| `06-platform-security.yml` | `06 - Platform: Security (Key Vault + WORM)` |

---

## Running Pipelines for the First Time (Initial Platform Deployment)

Follow this sequence for a fresh platform deployment. Each step must complete
successfully before proceeding to the next.

### Step 1 — Management Groups (pipeline 01)

```
Run pipeline: 01 - Platform: Management Groups
No parameters required.
Approval gate: platform-production (platform team)
```

After completion, verify the management group hierarchy in Azure Portal >
Management groups.

### Step 2 — Logging (pipeline 02)

```
Run pipeline: 02 - Platform: Logging & Monitoring
No parameters required.
Approval gate: platform-production (platform team)
```

After completion, copy the `LOG_ANALYTICS_WORKSPACE_ID` from the pipeline output
and update the `alz-platform-secrets` variable group.

### Step 3 — Connectivity (pipeline 03)

```
Run pipeline: 03 - Platform: Connectivity
Optional parameters:
  checkpointSku: sg-byol (default) | sg-ngtp | sg-ngtx
  erGatewaySku:  ErGw1AZ (default) | ErGw2AZ | ErGw3AZ
Approval gate: platform-production (platform team)
```

After completion, copy these values from the pipeline output and update
`alz-platform-secrets`:
- `ER_GATEWAY_ID`
- `HUB_VNET_ID`
- `MANAGEMENT_SUBNET_ID`
- `ROUTE_TABLE_ID`

### Step 3a — Platform Security (pipeline 06)

Run this pipeline after steps 2 and 3 have both completed. It deploys the platform
Key Vault (Premium / HSM-backed) and the immutable audit storage account (WORM).
Private endpoints are attached to the management subnet created in step 3.

```
Run pipeline: 06 - Platform: Security (Key Vault + WORM)
No parameters required.
Approval gate: platform-production (platform team)
```

After completion:
1. The pipeline automatically grants **Key Vault Crypto User** to the Log Analytics
   managed identity (`LAW_MI_PRINCIPAL_ID` variable group entry — set after step 2).
2. **Re-run pipeline 02** (Logging) to activate Customer-Managed Key (CMK) on the
   Log Analytics Workspace using the Key Vault URI output from this pipeline.

### Step 3b — ExpressRoute Connection (pipeline 03b)

Run this pipeline ONLY after:
- Pipeline 03 has completed
- The ER circuit has been created in Azure Portal
- The service key has been sent to the provider
- The provider has confirmed circuit status as **Provisioned**

```
Run pipeline: 03b - Platform: ExpressRoute Connection
Required parameter:
  erCircuitResourceId: /subscriptions/<id>/resourceGroups/<rg>/providers/
                       Microsoft.Network/expressRouteCircuits/<name>
Optional parameters:
  connectionName: con-ergw-to-circuit-001 (default)
  routingWeight:  0 (default)
Approval gate: platform-production (platform team)
```

### Step 4 — Subscription Vending (pipeline 04)

Run this pipeline once a `.bicepparam` file is added to
`subscription-vending/parameters/`. The pipeline auto-detects changed files on push,
or accepts a specific file path for manual runs.

```
Run pipeline: 04 - Subscription Vending Machine
Optional parameter:
  paramFile: subscription-vending/parameters/<filename>.bicepparam
Approval gates: vending-network-review, vending-security-review, vending-platform-approval
                (all 3 run in parallel — all must approve before deployment)
```

### Step 5 — Sentinel (pipeline 05)

```
Run pipeline: 05 - Platform: Microsoft Sentinel
No parameters required.
Approval gate: platform-production (platform team)
```

After completion, follow the post-deploy checklist printed in the pipeline
summary (watchlists, TAXII feeds, role assignments).

---

## Authentication Architecture

All pipelines use **Workload Identity Federation (OIDC)** via the `AzureCLI@2` task
with the `hss-platform-azure-sc` service connection. No client secrets are stored — the
service connection obtains short-lived tokens using federated credentials.

The service principal requires elevated permissions for tenant-scope and management group
scope deployments:

| Pipeline | Deployment scope | Required role |
|----------|-----------------|---------------|
| 00 | N/A (lint + scan only) | No Azure access required |
| 01 | Tenant | Owner at Tenant Root Management Group |
| 02 | Subscription | Contributor on Management subscription |
| 03 | Subscription | Contributor on Connectivity subscription |
| 03b | Resource Group | Contributor on Connectivity subscription |
| 04 | Management Group | Management Group Contributor + EA Enrollment Account Owner |
| 05 | Subscription | Contributor on Management subscription |
| 06 | Subscription | Contributor on Management subscription + Key Vault Administrator (post-deploy role assignment) |

---

## Troubleshooting

### Pipeline fails at lint stage: `az bicep build` not found

The `az bicep install` step at the start of each job installs the Bicep CLI onto the
Microsoft-hosted agent. If this step fails, check for Azure CLI version issues in the
agent image. The `ubuntu-latest` image includes Azure CLI but not Bicep by default.

### Pipeline fails with: `The subscription is not registered to use namespace`

Some resource providers need to be registered on the target subscription before
deployment. Common ones:
- `Microsoft.OperationsManagement` (required for Sentinel)
- `Microsoft.AlertsManagement` (required for monitoring)
- `Microsoft.Network` (should be pre-registered)

Register via: `az provider register --namespace Microsoft.OperationsManagement`

### What-If stage shows unexpected changes on re-run

What-if on tenant or management group scope can show false positives for existing
resources. Review the output carefully — changes to `tags` or `properties` fields
on unchanged resources are usually safe to proceed with.

### Subscription vending stage 3 (review) approval times out

The ADO environment approval timeout defaults to 30 days. If an approval times out,
re-run the pipeline from the WhatIf stage. The validation and what-if stages are
idempotent and safe to re-run.

### ER circuit verification fails with `Provider status is NotProvisioned`

This is expected when the circuit has just been created. Wait for your service provider
(Equinix / Megaport / Telstra) to provision the circuit. This typically takes 1–5
business days. Re-run pipeline 03b once the status shows **Provisioned** in the
Azure Portal.

---

## Security Notes

- All secret variables are stored in the `alz-platform-secrets` ADO Library variable group
  and marked as **Secret**. They are never echoed to pipeline logs.
- The service principal client secret is NOT used — OIDC federated credentials are used
  instead, eliminating the need to rotate secrets.
- Pipeline YAML files are stored in the repository and subject to branch protection and
  pull request review before they can affect production.
- The `pr: none` directive on all pipelines prevents pull request builds from triggering
  production deployments.
- ADO environment approval gates require explicit human sign-off before any deployment
  stage executes.
