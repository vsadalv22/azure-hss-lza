# HSS Azure Enterprise Landing Zone

> **Platform:** Microsoft Azure | **IaC:** Bicep (Azure Verified Modules)
> **Region:** Australia East | **Billing:** Enterprise Agreement (EA)
> **Topology:** Hub & Spoke | **WAN Edge:** ExpressRoute | **NVA:** Checkpoint CloudGuard
> **SIEM:** Microsoft Sentinel | **CI/CD:** GitHub Actions

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Repository Structure](#repository-structure)
5. [First-Time Setup](#first-time-setup)
6. [Deployment Order](#deployment-order)
7. [ExpressRoute Configuration](#expressroute-configuration)
8. [Checkpoint CloudGuard NVA](#checkpoint-cloudguard-nva)
9. [Microsoft Sentinel](#microsoft-sentinel)
10. [Subscription Vending Machine](#subscription-vending-machine)
11. [GitHub Actions Workflows](#github-actions-workflows)
12. [Branch Strategy](#branch-strategy)
13. [GitHub Secrets Reference](#github-secrets-reference)
14. [Networking Reference](#networking-reference)
15. [Post-Deployment Checklist](#post-deployment-checklist)

---

## Overview

This repository contains the complete Infrastructure-as-Code for the **HSS Azure Enterprise Landing Zone** — a production-grade, enterprise-scale Azure foundation built on the [Azure Landing Zones](https://aka.ms/alz) architecture framework using [Azure Verified Modules (AVM)](https://aka.ms/avm).

### Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| IaC toolchain | Bicep + AVM | Native Azure, no state file, strong typing |
| WAN connectivity | ExpressRoute (Standard / UnlimitedData / 1 Gbps) | Predictable latency, no internet exposure |
| Firewall / NVA | Checkpoint CloudGuard R81.10 | Existing enterprise Checkpoint investment |
| Management access | On-prem jump hosts via ExpressRoute | No Bastion — reduces attack surface and cost |
| SIEM | Microsoft Sentinel | Cloud-native SIEM/SOAR, unified with Defender XDR |
| Subscription model | EA vending (lz-vending AVM) | Automated spoke provisioning with guardrails |
| Auth (CI/CD) | OIDC Federated Credentials | No client secrets stored anywhere |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Tenant Root Group                          │
│  └── alz (Root Management Group)                                │
│      ├── platform                                               │
│      │   ├── management      ← Log Analytics, Sentinel, AA      │
│      │   ├── connectivity    ← Hub VNet, Checkpoint, ER GW      │
│      │   └── identity        ← Active Directory Domain Services │
│      ├── landingzones                                           │
│      │   ├── corp            ← Internal workloads (ER-peered)   │
│      │   └── online          ← Internet-facing workloads        │
│      ├── sandbox                                                │
│      └── decommissioned                                         │
└─────────────────────────────────────────────────────────────────┘

On-Premises Network
      │
      │  ExpressRoute Circuit
      │  Standard / UnlimitedData / 1 Gbps
      │  Peering: Sydney
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  Hub VNet — 10.0.0.0/16  (Connectivity Subscription)           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ snet-        │  │ snet-        │  │ GatewaySubnet│          │
│  │ checkpoint-  │  │ checkpoint-  │  │ 10.0.3.0/27  │          │
│  │ external     │  │ internal     │  │ (ER Gateway) │          │
│  │ 10.0.0.0/28  │  │ 10.0.1.0/28  │  └──────────────┘          │
│  │ [eth0 / PIP] │  │ [eth1 / .4]  │                            │
│  └──────┬───────┘  └──────┬───────┘                            │
│         │   Checkpoint     │  ← All spoke traffic               │
│         │   CloudGuard     │    forced via UDR 0.0.0.0/0        │
│         └──────────────────┘                                    │
│                                                                 │
│  ┌──────────────┐                                               │
│  │ snet-mgmt    │  ← Reachable from on-prem via ER (no Bastion) │
│  │ 10.0.2.0/24  │                                               │
│  └──────────────┘                                               │
└────────────────────────────┬────────────────────────────────────┘
                             │ VNet Peering (spoke ↔ hub)
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
  Corp Spoke             Corp Spoke          Online Spoke
  10.100.0.0/16         10.101.0.0/16       10.200.0.0/16
  (vended via           (vended via         (vended via
   sub-vending)          sub-vending)        sub-vending)
```

---

## Prerequisites

### Tools

| Tool | Minimum Version | Install |
|---|---|---|
| Azure CLI | 2.60.0 | [docs.microsoft.com](https://docs.microsoft.com/cli/azure/install-azure-cli) |
| Bicep CLI | 0.29.0 | `az bicep install` |
| PowerShell | 7.4 | [github.com/PowerShell](https://github.com/PowerShell/PowerShell) |
| Git | 2.40 | [git-scm.com](https://git-scm.com) |
| GitHub CLI | 2.40 | [cli.github.com](https://cli.github.com) |

### Azure Permissions

| Scope | Role | Purpose |
|---|---|---|
| Tenant Root Management Group | Owner | Deploy MG hierarchy, assign policies |
| Tenant Root Management Group | Management Group Contributor | Move subscriptions between MGs |
| EA Enrollment Account | Enrollment Account Subscription Creator | Vend new subscriptions |
| All platform subscriptions | Owner | Deploy platform resources |

### Azure Subscriptions (EA)

Create these **3 platform subscriptions** in the EA portal before running the bootstrap:

| Subscription | Purpose |
|---|---|
| `sub-management` | Log Analytics, Automation Account, Microsoft Sentinel |
| `sub-connectivity` | Hub VNet, Checkpoint NVA, ExpressRoute Gateway |
| `sub-identity` | Active Directory Domain Controllers |

---

## Repository Structure

```
hss-azure-ea-lza/
│
├── .github/
│   └── workflows/
│       ├── 01-platform-management-groups.yml   # MG hierarchy
│       ├── 02-platform-logging.yml             # Log Analytics + Automation
│       ├── 03-platform-connectivity.yml        # Hub VNet + Checkpoint + ExpressRoute
│       ├── 04-subscription-vending.yml         # Automated spoke provisioning
│       └── 05-platform-sentinel.yml            # Microsoft Sentinel + connectors
│
├── platform/
│   ├── management-groups/
│   │   └── main.bicep                          # Full MG hierarchy
│   ├── logging/
│   │   └── main.bicep                          # Log Analytics + Automation Account
│   ├── connectivity/
│   │   ├── main.bicep                          # Hub VNet, ER circuit/GW, Checkpoint
│   │   ├── modules/
│   │   │   └── checkpoint-nva.bicep            # Checkpoint dual-NIC VM module
│   │   └── parameters/
│   │       └── hub-networking.bicepparam
│   ├── identity/
│   │   └── main.bicep                          # Identity VNet + AD DS
│   └── sentinel/
│       ├── main.bicep                          # Sentinel + connectors + rules
│       └── parameters/
│           └── sentinel.bicepparam
│
├── subscription-vending/
│   ├── main.bicep                              # lz-vending AVM module wrapper
│   └── parameters/
│       └── example-corp-spoke.bicepparam       # Template for new spokes
│
├── scripts/
│   ├── bootstrap.ps1                           # One-time SP + OIDC setup
│   └── new-subscription.ps1                    # Scaffold new subscription file
│
├── config/
│   └── inputs.yaml                             # Master configuration reference
│
└── bicepconfig.json                            # Bicep linter + module aliases
```

---

## First-Time Setup

### Step 1 — Clone the repository

```bash
git clone https://github.com/vsadalv22/azure-hss-lza.git
cd azure-hss-lza
```

### Step 2 — Run bootstrap script

The bootstrap script creates the service principal, configures GitHub OIDC federated credentials (no secrets stored), and assigns the required RBAC roles.

```powershell
./scripts/bootstrap.ps1 `
    -TenantId          "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -GitHubOrg         "vsadalv22" `
    -GitHubRepo        "azure-hss-lza" `
    -EABillingAccount  "12345678" `
    -EAEnrollmentAcct  "987654" `
    -ManagementSubId   "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ConnectivitySubId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -IdentitySubId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Step 3 — Configure GitHub repository

**Secrets** — navigate to `Settings → Secrets and variables → Actions`:

| Secret Name | Value | When to set |
|---|---|---|
| `AZURE_TENANT_ID` | Entra ID tenant ID | Now |
| `AZURE_CLIENT_ID` | Service principal client ID | Now |
| `MANAGEMENT_SUBSCRIPTION_ID` | Management subscription ID | Now |
| `CONNECTIVITY_SUBSCRIPTION_ID` | Connectivity subscription ID | Now |
| `IDENTITY_SUBSCRIPTION_ID` | Identity subscription ID | Now |
| `EA_BILLING_ACCOUNT` | EA billing account number | Now |
| `EA_ENROLLMENT_ACCOUNT` | EA enrollment account number | Now |
| `CHECKPOINT_ADMIN_PASSWORD` | Strong VM password | Now |
| `SENTINEL_SECURITY_CONTACT` | SOC team email address | Now |
| `LOG_ANALYTICS_WORKSPACE_ID` | LAW resource ID | After workflow 02 |
| `HUB_VNET_ID` | Hub VNet resource ID | After workflow 03 |
| `ROUTE_TABLE_ID` | UDR resource ID | After workflow 03 |

**Environments** — navigate to `Settings → Environments`:

| Environment | Required Reviewers | Used By |
|---|---|---|
| `platform-production` | Platform team leads | Workflows 01, 02, 03, 05 |
| `subscription-vending` | Security + Network team | Workflow 04 |

### Step 4 — Fill in ExpressRoute parameters

Edit `platform/connectivity/parameters/hub-networking.bicepparam` and set:

```bicep
param erServiceProviderName = 'YourProvider'   // e.g. 'Equinix' or 'Megaport'
param erPeeringLocation     = 'Sydney'
```

---

## Deployment Order

> Run each workflow in sequence — each stage builds on the previous one.

```
┌──────────────────────────────────────────────────────────┐
│  Workflow 01 — Management Groups                         │
│  Scope: Tenant                                           │
│  Creates MG hierarchy under root                         │
└──────────────────────────┬───────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────┐
│  Workflow 02 — Logging                                   │
│  Scope: Management Subscription                          │
│  Creates Log Analytics + Automation Account              │
│  → Update secret: LOG_ANALYTICS_WORKSPACE_ID             │
└──────────────────────────┬───────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────┐
│  Workflow 03 — Connectivity                              │
│  Scope: Connectivity Subscription                        │
│  Creates Hub VNet, Checkpoint NVA, ExpressRoute          │
│  → Update secrets: HUB_VNET_ID, ROUTE_TABLE_ID           │
│  → Provider must provision ER circuit (1-5 business days)│
└──────────────────────────┬───────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────┐
│  Workflow 05 — Sentinel                                  │
│  Scope: Management Subscription                          │
│  Enables Sentinel, connectors, analytics rules, UEBA     │
└──────────────────────────┬───────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────┐
│  Workflow 04 — Subscription Vending  (ongoing)           │
│  Triggered by: PR adding a .bicepparam file              │
│  Creates spoke subscription + VNet + peering + RBAC      │
└──────────────────────────────────────────────────────────┘
```

---

## ExpressRoute Configuration

### Circuit Details

| Parameter | Value |
|---|---|
| Circuit name | `erc-hub-australiaeast-001` |
| Peering location | Sydney |
| Bandwidth | 1 Gbps (upgradeable without downtime) |
| SKU tier | Standard |
| SKU family | **UnlimitedData** |
| Gateway | `ergw-hub-australiaeast-001` (ErGw1AZ — zone-redundant) |
| Gateway subnet | `10.0.3.0/27` |

### Provisioning Flow

```
1. Bicep deploys ER circuit resource  →  State: NotProvisioned
2. You send service key to provider   →  State: Provisioning
3. Provider enables the circuit       →  State: Provisioned
4. Bicep creates ER connection        →  State: Connected
```

> **Important:** The ER connection resource (`con-ergw-to-circuit-001`) will not reach `Succeeded` until the provider has provisioned the circuit. This is expected behaviour.

### Upgrading Bandwidth

Bandwidth can be increased without downtime via the Azure Portal or by updating `erBandwidthInMbps` in the parameter file and re-running workflow 03.

---

## Checkpoint CloudGuard NVA

### VM Details

| Parameter | Value |
|---|---|
| VM name | `vm-checkpoint-hub-001` |
| VM size | `Standard_D3_v2` (upgradeable) |
| Image | Checkpoint CloudGuard R81.10 (`check-point-cg-r8110`) |
| Licence | BYOL (`sg-byol`) — bring your own Checkpoint licence |
| External NIC (eth0) | `snet-checkpoint-external` — static IP `10.0.0.4` with PIP |
| Internal NIC (eth1) | `snet-checkpoint-internal` — static IP `10.0.1.4` |
| UDR | All spoke subnets: `0.0.0.0/0 → 10.0.1.4` |

### Management Access (No Bastion)

Since Azure Bastion is not deployed, connect to the Checkpoint VM via:

1. On-premises workstation over **ExpressRoute**
2. SSH to `10.0.0.4` (external NIC) from on-prem jump host
3. Or access the management VMs in `snet-management` (10.0.2.0/24)

### Post-Deploy Checkpoint Setup

```
1. SSH to 10.0.0.4 from on-prem jump host
2. Run 'clish' and complete First Time Configuration wizard
3. Set SIC one-time password (used by SmartConsole)
4. From SmartConsole (on-prem): connect to 10.0.0.4
5. Initialize gateway with SIC password
6. Install Access Policy
7. Apply BYOL licence via SmartConsole → Licences
```

### Checkpoint Management Ports

Allow these ports from on-prem networks via NSG / ER routing:

| Port | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 443 | TCP | HTTPS / Web SmartConsole |
| 18190 | TCP | SmartConsole communication |
| 19009 | TCP | Log server |
| 257 | TCP | CPD (policy push) |
| 8211 | TCP | CPRID |

---

## Microsoft Sentinel

### Enabled Components

| Component | Details |
|---|---|
| Workspace | `law-management-australiaeast-001` (shared with logging) |
| UEBA | Enabled — sources: AuditLogs, AzureActivity, SecurityEvent, SigninLogs |
| Entity Analytics | ActiveDirectory + AzureActiveDirectory |
| Retention | 365 days |

### Data Connectors (8 enabled)

| Connector | Data Collected |
|---|---|
| Azure Active Directory | Sign-in logs, Audit logs |
| Azure Activity | Subscription-level operations |
| Microsoft Defender for Cloud | Security alerts |
| Microsoft Defender XDR | Incidents + cross-product alerts |
| Microsoft Defender for Endpoint | Endpoint alerts |
| Microsoft Defender for Identity | Identity-based alerts |
| Office 365 | Exchange, SharePoint, Teams |
| Threat Intelligence | IOC indicators |

### Analytics Rules (5 built-in)

| Rule | Severity | Tactic |
|---|---|---|
| Sign-in from multiple geographies | Medium | Initial Access |
| Privileged role assigned | High | Privilege Escalation |
| Mass resource deletion | High | Impact |
| NVA / Firewall config changed | Medium | Defence Evasion |
| Password spray attack | High | Credential Access |

### Post-Deploy Sentinel Steps

1. **Populate watchlist** — add on-prem CIDR blocks (ER-connected) to `TrustedIPRanges` watchlist
2. **TAXII feed** — configure threat intelligence TAXII feed URL in the TI connector
3. **RBAC** — assign `Microsoft Sentinel Contributor` to SOC team AAD group
4. **Defender for Cloud** — enable Defender Standard plans on all subscriptions
5. **Tune rules** — adjust query thresholds in analytics rules for your environment

---

## Subscription Vending Machine

### How It Works

```
Developer / App Team                  Platform Team (review)
        │                                     │
        │  1. Run new-subscription.ps1        │
        │     (scaffolds .bicepparam file)    │
        │                                     │
        │  2. git commit + Push PR ──────────►│
        │                                     │  3. What-if posted as PR comment
        │                                     │  4. Review & approve PR
        │◄───────────────────────────────────  │
        │
        │  5. Merge to main
        │     ↓ Triggers workflow 04
        │     ↓ Requires Environment approval
        │     ↓ Deploys:
        │        • EA subscription (in Corp or Online MG)
        │        • Spoke VNet (peered to hub via Checkpoint)
        │        • UDR (0.0.0.0/0 → Checkpoint 10.0.1.4)
        │        • RBAC (app team AAD group → Contributor)
```

### Create a New Spoke Subscription

```powershell
./scripts/new-subscription.ps1 `
    -SubscriptionAlias   "sub-myapp-prod" `
    -DisplayName         "My Application Production" `
    -TargetMG            "alz-landingzones-corp" `
    -SpokeAddressPrefix  "10.101.0.0/16" `
    -OwnerEmail          "myteam@company.com" `
    -OwnerGroupObjectId  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

Then open a Pull Request — the what-if output will be posted as a comment automatically.

---

## GitHub Actions Workflows

| Workflow | Trigger | Scope | Environment Gate |
|---|---|---|---|
| `01-platform-management-groups.yml` | Push to `main` (`platform/management-groups/**`) | Tenant | `platform-production` |
| `02-platform-logging.yml` | Push to `main` (`platform/logging/**`) | Management Sub | `platform-production` |
| `03-platform-connectivity.yml` | Push to `main` (`platform/connectivity/**`) | Connectivity Sub | `platform-production` |
| `04-subscription-vending.yml` | Push to `main` (`subscription-vending/parameters/**`) | Root MG | `subscription-vending` |
| `05-platform-sentinel.yml` | Push to `main` (`platform/sentinel/**`) | Management Sub | `platform-production` |

All workflows use:
- **OIDC authentication** — no stored client secrets
- **Bicep lint** → **what-if** → **manual approval** → **deploy** pipeline
- **Deployment outputs** uploaded as GitHub Actions artifacts

---

## Branch Strategy

| Branch | Purpose | Deploys to |
|---|---|---|
| `main` | Production-ready code — protected, requires PR | Production Azure environment |
| `staging` | Pre-production validation | Staging / UAT Azure environment |
| `dev` | Active development and feature branches | Dev Azure environment |

### Branch Protection Rules (recommended)

Configure in `Settings → Branches` for each branch:

**`main`**
- Require pull request reviews (minimum 2 approvals)
- Require status checks: `Bicep Lint`, `What-If`
- Restrict pushes to platform team
- No force pushes

**`staging`**
- Require pull request reviews (minimum 1 approval)
- Require status checks: `Bicep Lint`

**`dev`**
- Require status checks: `Bicep Lint`

### Workflow

```
feature/my-change ──► dev ──► staging ──► main
                      │          │          │
                      ▼          ▼          ▼
                   dev env   staging env  prod env
```

---

## GitHub Secrets Reference

| Secret | Description | Example |
|---|---|---|
| `AZURE_TENANT_ID` | Entra ID tenant GUID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `AZURE_CLIENT_ID` | Service principal client ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `MANAGEMENT_SUBSCRIPTION_ID` | Management sub ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `CONNECTIVITY_SUBSCRIPTION_ID` | Connectivity sub ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `IDENTITY_SUBSCRIPTION_ID` | Identity sub ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `EA_BILLING_ACCOUNT` | EA billing account number | `12345678` |
| `EA_ENROLLMENT_ACCOUNT` | EA enrollment account number | `987654` |
| `CHECKPOINT_ADMIN_PASSWORD` | Checkpoint VM password | _(strong password)_ |
| `SENTINEL_SECURITY_CONTACT` | SOC alert email | `soc@company.com` |
| `LOG_ANALYTICS_WORKSPACE_ID` | LAW resource ID | `/subscriptions/.../workspaces/law-...` |
| `HUB_VNET_ID` | Hub VNet resource ID | `/subscriptions/.../virtualNetworks/vnet-hub-...` |
| `ROUTE_TABLE_ID` | UDR resource ID | `/subscriptions/.../routeTables/udr-...` |

---

## Networking Reference

### Address Space Summary

| Network | CIDR | Location | Notes |
|---|---|---|---|
| Hub VNet | `10.0.0.0/16` | Connectivity sub | Core hub — all traffic through Checkpoint |
| Checkpoint external subnet | `10.0.0.0/28` | Hub | eth0 NIC + Public IP |
| Checkpoint internal subnet | `10.0.1.0/28` | Hub | eth1 NIC — static .4 |
| Management subnet | `10.0.2.0/24` | Hub | Jump servers (on-prem access via ER) |
| GatewaySubnet | `10.0.3.0/27` | Hub | ExpressRoute Gateway |
| Identity VNet | `10.10.0.0/16` | Identity sub | AD DS domain controllers |
| Corp spokes | `10.100.0.0/16+` | Spoke subs | Vended — allocate sequentially |
| Online spokes | `10.200.0.0/16+` | Spoke subs | Vended — allocate sequentially |

### Traffic Flow (Spoke → Internet)

```
Spoke VM  →  UDR (0.0.0.0/0)  →  Checkpoint eth1 (10.0.1.4)
          →  Checkpoint inspects / allows / blocks
          →  Checkpoint eth0 (10.0.0.4)  →  Internet via PIP
```

### Traffic Flow (On-Prem → Azure Spoke)

```
On-prem  →  ER circuit  →  ER Gateway (ergw-hub)
         →  Hub VNet    →  VNet Peering  →  Spoke VNet
```

---

## Post-Deployment Checklist

### Platform

- [ ] Run workflow 01 — verify management group hierarchy in Azure Portal
- [ ] Run workflow 02 — note `LOG_ANALYTICS_WORKSPACE_ID` output and update secret
- [ ] Run workflow 03 — note `HUB_VNET_ID` and `ROUTE_TABLE_ID` outputs and update secrets
- [ ] Send ExpressRoute service key to provider; monitor circuit provisioning status
- [ ] Complete Checkpoint First Time Configuration wizard (via on-prem jump host over ER)
- [ ] Register Checkpoint gateway with SmartConsole and install base policy
- [ ] Apply BYOL licence to Checkpoint via SmartConsole
- [ ] Run workflow 05 — verify Sentinel is enabled in Azure Portal (`Microsoft Sentinel`)

### Sentinel / Security

- [ ] Validate all 8 data connectors show green status in Sentinel → Data connectors
- [ ] Populate `TrustedIPRanges` watchlist with on-prem CIDR blocks
- [ ] Configure TAXII threat intelligence feed URL
- [ ] Assign `Microsoft Sentinel Contributor` to SOC team AAD group
- [ ] Enable Microsoft Defender for Cloud Standard tier on all subscriptions
- [ ] Test analytics rules by simulating a sign-in from an untrusted location
- [ ] Review Automation Rules and assign SOC team as default incident owner

### Governance

- [ ] Review and assign Azure Policy initiatives at each management group
- [ ] Enable Microsoft Defender for Cloud across all subscriptions
- [ ] Configure Cost Management budgets and alerts per subscription
- [ ] Set up Azure Monitor alerts for platform health (ER circuit, Checkpoint VM)

---

## Contributing

1. Branch from `dev` for all changes
2. Follow the PR template
3. Bicep changes must pass lint and what-if before review
4. Infrastructure changes to `platform/` require 2 approvals
5. New subscription vending files require security + network team approval

## Licence

Internal use only — HSS platform team.
