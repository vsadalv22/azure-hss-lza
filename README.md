# WA Health HSS — Azure Enterprise Landing Zone

[![Security Checks](https://img.shields.io/badge/Gitleaks-passing-brightgreen?logo=git&logoColor=white)](https://github.com/gitleaks/gitleaks)
[![Checkov](https://img.shields.io/badge/Checkov-SAST-blue?logo=checkmarx&logoColor=white)](https://www.checkov.io/)
[![Bicep](https://img.shields.io/badge/Bicep-AVM-0078D4?logo=microsoftazure&logoColor=white)](https://aka.ms/avm)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **Organisation:** Western Australian Department of Health — Health Support Services (HSS)
> **Platform:** Microsoft Azure | **IaC:** Bicep (Azure Verified Modules)
> **Primary Region:** Australia East | **Secondary Region:** Perth Extended Zone (PEZ)
> **Topology:** Hub-and-Spoke | **WAN Edge:** ExpressRoute Direct (MACsec) | **NVA:** Checkpoint CloudGuard R81.10 VMSS
> **SIEM:** Microsoft Sentinel | **CI/CD:** Azure DevOps (DD03) | **Compliance:** APRA CPS 234, Australian ISM, Essential Eight ML2

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Repository Structure](#repository-structure)
4. [Prerequisites](#prerequisites)
5. [Quick Start](#quick-start)
6. [Pipeline Deployment Sequence](#pipeline-deployment-sequence)
7. [Module Reference](#module-reference)
8. [Compliance](#compliance)
9. [Security](#security)
10. [Contributing](#contributing)
11. [License](#license)
12. [Contact](#contact)

---

## Overview

This repository contains the complete Infrastructure-as-Code (IaC) for the **HSS Azure Enterprise Landing Zone** — a production-grade, enterprise-scale Azure foundation built on the [Azure Landing Zones](https://aka.ms/alz) reference architecture using [Azure Verified Modules (AVM)](https://aka.ms/avm).

It is maintained by the **WA Health HSS Platform Engineering team** and is the authoritative source for all Azure platform infrastructure. No manual changes to platform resources are permitted outside of this codebase.

### Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| IaC toolchain | Bicep + AVM | Native Azure, no state file, strong typing, no extra toolchain dependency |
| Primary region | Australia East | Highest Azure service availability in Australia |
| Secondary region | Perth Extended Zone (PEZ) | Low-latency secondary hub for WA government workloads |
| WAN connectivity | ExpressRoute Direct with MACsec | Layer 2 encryption, no internet exposure, predictable latency |
| Firewall / NVA | Checkpoint CloudGuard R81.10 | Existing enterprise Checkpoint investment; deployed manually by network team into pre-provisioned subnets |
| NVA deployment | Manual (Azure Marketplace) | IaC provisions VNets, subnets, NSGs, and route tables; Checkpoint VMs are deployed manually post-pipeline |
| Management access | On-premises jump hosts via ExpressRoute | No Bastion — reduces attack surface and cost |
| SIEM | Microsoft Sentinel | Cloud-native SIEM/SOAR, native integration with Microsoft Defender XDR |
| Subscription model | EA vending (lz-vending AVM) | Automated spoke provisioning with security and network guardrails |
| CI/CD platform | Azure DevOps (DD03) | Mandated enterprise CI/CD platform; Checkpoint NVA deployment is manual (not automated) |
| Auth (CI/CD) | OIDC Federated Credentials | No client secrets stored — workload identity federation |
| Secrets management | Azure Key Vault Premium / HSM | CMK on Log Analytics, no plaintext secrets in code or pipelines |
| Audit logs | Immutable storage (WORM) | Tamper-proof audit trail for APRA CPS 234 and ISM compliance |
| SAST | Checkov + Gitleaks | Pre-commit and pipeline static analysis for misconfigurations and secrets |

---

## Architecture

### Management Group Hierarchy

```
Tenant Root Group
  └── alz  (Root Management Group)
      ├── platform
      │   ├── management        Log Analytics, Sentinel, Key Vault, Automation Account
      │   ├── connectivity      Hub VNet, Checkpoint VMSS, ER Gateway, Ingress VNet
      │   └── identity          Active Directory Domain Services
      ├── landingzones
      │   ├── corp              Internal workloads (ExpressRoute-peered)
      │   └── online            Internet-facing workloads
      ├── sandbox               Non-production experimental subscriptions
      └── decommissioned        Subscriptions pending removal
```

### Network Topology

```
                              INTERNET
                                  │
                          ┌───────▼───────┐
                          │  Ingress VNet  │   (Connectivity Subscription)
                          │  10.1.0.0/16  │
                          │               │
                          │  ┌──────────┐ │
                          │  │Checkpoint│ │   Checkpoint CloudGuard R81.10
                          │  │   NVA    │ │   Manual deployment by network team
                          │  │ (manual) │ │   into pre-provisioned subnets
                          │  └────┬─────┘ │
                          └───────┼───────┘
                                  │ VNet Peering
                          ┌───────▼────────────────────────────────────────┐
                          │  Hub VNet — 10.0.0.0/16  (Connectivity Sub)    │
                          │                                                 │
                          │  ┌─────────────────┐   ┌────────────────────┐  │
                          │  │  GatewaySubnet  │   │   snet-mgmt        │  │
                          │  │  10.0.3.0/27    │   │   10.0.2.0/24      │  │
                          │  │  (ER Gateway)   │   │   (jump / infra)   │  │
                          │  └────────┬────────┘   └────────────────────┘  │
                          └───────────┼────────────────────────────────────┘
                                      │  VNet Peering (hub ↔ spoke)
                 ┌────────────────────┼────────────────────┐
                 ▼                    ▼                    ▼
          Corp Spoke            Corp Spoke           Online Spoke
          10.100.0.0/16        10.101.0.0/16        10.200.0.0/16
          (vended)              (vended)              (vended)
                                      │
                                      │ All spoke egress routed via
                                      │ UDR 0.0.0.0/0 → Checkpoint VMSS
                                      │ (mandatory NVA inspection, no bypass)

  On-Premises Network
         │
         │  ExpressRoute Direct (MACsec)
         │  Circuit created manually by network team
         │
         ▼
  ER Gateway (Hub VNet)
  ErGw1AZ — zone-redundant

                     ┌────────────────────────────────────────┐
                     │  Perth Extended Zone (PEZ)             │
                     │  Secondary Hub (platform/connectivity/ │
                     │  pez/main.bicep)                       │
                     │  Reduced-latency secondary for WA      │
                     └────────────────────────────────────────┘

                     ┌────────────────────────────────────────┐
                     │  Management Subscription               │
                     │  • Log Analytics Workspace (CMK)       │
                     │  • Microsoft Sentinel (6 rules)        │
                     │  • Key Vault Premium / HSM             │
                     │  • Immutable audit storage (WORM)      │
                     │  • Azure Monitor / Alerts              │
                     └────────────────────────────────────────┘

                     ┌────────────────────────────────────────┐
                     │  Identity Subscription                 │
                     │  • Active Directory Domain Controllers │
                     │  • Identity VNet peered to Hub         │
                     └────────────────────────────────────────┘
```

---

## Repository Structure

```
alz-bicep/
│
├── platform/                                  Platform subscriptions IaC
│   ├── management-groups/
│   │   └── main.bicep                         Full ALZ management group hierarchy
│   ├── logging/
│   │   └── main.bicep                         Log Analytics (CMK), Automation Account
│   ├── connectivity/
│   │   ├── main.bicep                         Hub VNet, Ingress VNet, ER Gateway, Checkpoint VMSS
│   │   ├── pez/
│   │   │   └── main.bicep                     Perth Extended Zone secondary hub
│   │   └── modules/
│   │       ├── checkpoint-vmss.bicep          Checkpoint CloudGuard VMSS cluster (2 instances)
│   │       ├── checkpoint-nva.bicep           Legacy single-VM NVA (reference only, not deployed)
│   │       ├── er-connection.bicep            ER Gateway to circuit connection resource
│   │       ├── private-dns.bicep              28 Private DNS zones (linked to hub VNet)
│   │       └── private-endpoint.bicep         Reusable private endpoint module
│   ├── identity/
│   │   └── main.bicep                         Identity VNet, AD DS subnet, NSGs
│   ├── policies/
│   │   └── main.bicep                         28 policy assignments (deny, audit, DINE)
│   ├── sentinel/
│   │   └── main.bicep                         Sentinel workspace, 6 analytics rules, HSP scoping
│   ├── monitoring/
│   │   └── main.bicep                         Action groups, alerts, platform workbooks
│   └── security/
│       ├── main.bicep                         Key Vault Premium/HSM, immutable audit storage
│       └── modules/
│           ├── rbac-assignments.bicep         Centralised RBAC role assignment module
│           ├── resource-lock.bicep            CanNotDelete lock for platform resource groups
│           └── private-endpoint.bicep         Private endpoint for Key Vault and storage
│
├── subscription-vending/                      Spoke subscription automation
│   ├── main.bicep                             lz-vending AVM wrapper — EA sub + VNet + peering
│   └── modules/
│       ├── defender-plan.bicep                Defender for Cloud plan selection per subscription
│       ├── subscription-budget.bicep          Budget alerts at 80 / 100 / 120% thresholds
│       ├── subscription-diagnostics.bicep     Subscription diagnostic settings → central LAW
│       └── subscription-lock.bicep           CanNotDelete lock on networking resource group
│
├── azure-pipelines/                           Azure DevOps pipeline definitions (DD03 — production)
│
├── .github/workflows/                         GitHub Actions workflow definitions (reference only)
│
├── scripts/
│   ├── bootstrap.ps1                          One-time: service principal, OIDC, RBAC setup
│   ├── new-subscription.ps1                   Scaffold a new subscription vending parameter file
│   └── validate-subscription-request.ps1     IP overlap, naming convention, and tag validation
│
├── docs/
│   ├── deployment-guide.md                    End-to-end deployment walkthrough
│   ├── expressroute-setup.md                  Manual ExpressRoute circuit creation runbook
│   ├── checkpoint-first-boot.md               Checkpoint SmartConsole first-time configuration
│   ├── security-baseline.md                   Security controls and evidence mapping
│   └── avm-module-versions.md                 Pinned AVM module version reference
│
├── config/
│   └── inputs.yaml                            Master configuration — all environment parameters
│
├── bicepconfig.json                           Bicep linter rules and module registry aliases
├── .gitleaks.toml                             Gitleaks secret scanning configuration
└── .checkov.yaml                              Checkov SAST policy configuration
```

---

## Prerequisites

### Required Tools

| Tool | Minimum Version | Install |
|---|---|---|
| Azure CLI | 2.60.0 | [docs.microsoft.com/cli/azure](https://docs.microsoft.com/cli/azure/install-azure-cli) |
| Bicep CLI | 0.29.0 | `az bicep install && az bicep upgrade` |
| PowerShell | 7.4 | [github.com/PowerShell](https://github.com/PowerShell/PowerShell/releases) |
| Git | 2.40 | [git-scm.com](https://git-scm.com/downloads) |
| Checkov | 3.x | `pip install checkov` |
| Gitleaks | 8.x | [github.com/gitleaks/gitleaks](https://github.com/gitleaks/gitleaks/releases) |

### Azure Permissions

The deployment service principal requires the following permissions before running the bootstrap:

| Scope | Role | Purpose |
|---|---|---|
| Tenant Root Management Group | Owner | Deploy MG hierarchy, assign policies at root |
| Tenant Root Management Group | Management Group Contributor | Move subscriptions between management groups |
| EA Enrollment Account | Enrollment Account Subscription Creator | Vend new Azure subscriptions |
| Management Subscription | Owner | Deploy Log Analytics, Sentinel, Key Vault |
| Connectivity Subscription | Owner | Deploy Hub VNet, Checkpoint VMSS, ER Gateway |
| Identity Subscription | Owner | Deploy identity VNet and AD DS resources |

### Platform Subscriptions

Create these three platform subscriptions in the EA portal **before** running the bootstrap script. Do not place them in management groups manually — the pipeline handles that.

| Subscription | Purpose |
|---|---|
| `sub-management-prod` | Log Analytics, Sentinel, Key Vault, Automation Account |
| `sub-connectivity-prod` | Hub VNet, Ingress VNet, Checkpoint VMSS, ER Gateway |
| `sub-identity-prod` | Active Directory Domain Services |

---

## Quick Start

> For a complete step-by-step walkthrough, see **[docs/deployment-guide.md](docs/deployment-guide.md)**.

The five-minute overview:

1. **Clone** this repository and review `config/inputs.yaml` — this file contains all environment-specific parameters.

2. **Run the bootstrap script** — creates the service principal, configures OIDC federated credentials in Azure DevOps (no stored secrets), and assigns the required RBAC roles:

   ```powershell
   ./scripts/bootstrap.ps1 `
       -TenantId          "<entra-tenant-id>" `
       -EABillingAccount  "<ea-billing-account-number>" `
       -EAEnrollmentAcct  "<ea-enrollment-account-number>" `
       -ManagementSubId   "<management-subscription-id>" `
       -ConnectivitySubId "<connectivity-subscription-id>" `
       -IdentitySubId     "<identity-subscription-id>"
   ```

3. **Configure Azure DevOps** — add variable groups in DD03 for tenant IDs, subscription IDs, and Key Vault references. No plaintext secrets are stored in pipeline variables — all sensitive values are referenced from Key Vault.

4. **Run pipelines in order** — see [Pipeline Deployment Sequence](#pipeline-deployment-sequence) below.

5. **Complete manual steps** — the ExpressRoute circuit must be created by the network team after the ER Gateway is deployed. See [docs/expressroute-setup.md](docs/expressroute-setup.md) and [docs/checkpoint-first-boot.md](docs/checkpoint-first-boot.md).

---

## Pipeline Deployment Sequence

`00-security-checks` runs automatically on every PR and push — no manual action needed.
All other pipelines run in the order shown for the **initial platform deployment**.
After the platform is established, each pipeline runs independently on code changes to its
source paths.

```
┌─────────────────────────────────────────────────────────────────────┐
│  00 — Security Checks  (every PR + push — no deployment)            │
│  Pipeline: azure-pipelines/00-security-checks.yml                  │
│  Runs:  Bicep lint  |  Checkov SAST  |  Gitleaks secrets scan       │
│  Gate:  All checks must pass before any deployment pipeline runs    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼ (on merge to main)
┌─────────────────────────────────────────────────────────────────────┐
│  Stage 1 — Management Groups                                        │
│  Pipeline: azure-pipelines/01-management-groups.yml                 │
│  Scope: Tenant root                                                  │
│  Deploys: Full ALZ management group hierarchy                        │
│  Output: Management group resource IDs                               │
└───────────────────────────────────┬─────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Stage 2 — Logging                                                   │
│  Pipeline: azure-pipelines/02-logging.yml                           │
│  Scope: Management subscription                                      │
│  Deploys: Log Analytics Workspace, Automation Account,              │
│           LAW Managed Identity (for CMK — activated later)          │
│  → Update alz-platform-secrets: LOG_ANALYTICS_WORKSPACE_ID,        │
│    LAW_MI_PRINCIPAL_ID                                               │
└───────────────────────────────────┬─────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Stage 3 — Connectivity                                              │
│  Pipeline: azure-pipelines/03-connectivity.yml                      │
│  Scope: Connectivity subscription                                    │
│  Deploys: Hub VNet, Ingress VNet, Checkpoint CloudGuard VMSS (2x), │
│           ER Gateway (zone-redundant), 28 Private DNS zones,        │
│           PEZ secondary hub (Perth Extended Zone)                   │
│  → Update alz-platform-secrets: HUB_VNET_ID, ER_GATEWAY_ID,       │
│    MANAGEMENT_SUBNET_ID, ROUTE_TABLE_ID                             │
└───────────────────────────────────┬─────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Stage 3a — Platform Security                                        │
│  Pipeline: azure-pipelines/06-platform-security.yml                 │
│  Scope: Management subscription                                      │
│  Deploys: Key Vault Premium/HSM, immutable audit storage (WORM),   │
│           private endpoints (uses MANAGEMENT_SUBNET_ID from Stage 3)│
│  Post-deploy: grants Key Vault Crypto User to LAW managed identity  │
│  *** Re-run pipeline 02 after this step to activate CMK on LAW ***  │
└───────────────────────────────────┬─────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Stage 3b — ER Connection  (manual trigger only)                    │
│  Pipeline: azure-pipelines/03b-er-connection.yml                    │
│  Scope: Connectivity subscription                                    │
│  Pre-flight: Validates ProviderState = Provisioned before deploying │
│  Deploys: ER Gateway ↔ Circuit connection resource (BFD enabled)    │
│  Output: BGP routes established, on-premises connectivity live       │
│                                                                     │
│  *** MANUAL STEP — Network team creates ExpressRoute Direct circuit │
│      with MACsec in Azure Portal and sends service key to provider. │
│      See: docs/expressroute-setup.md                                 │
│      Wait for ProviderState = Provisioned (typically 1–5 days).     │
│      Then: docs/checkpoint-first-boot.md for Checkpoint first boot. │
└───────────────────────────────────┬─────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Stage 4 — Sentinel                                                  │
│  Pipeline: azure-pipelines/05-sentinel.yml                          │
│  Scope: Management subscription                                      │
│  Deploys: Microsoft Sentinel enablement, 6 scheduled analytics      │
│           rules, UEBA, HSP data scoping (Healthcare Sentinel Pkg)   │
└───────────────────────────────────┬─────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Subscription Vending  (ongoing — triggered per spoke request)      │
│  Pipeline: azure-pipelines/04-subscription-vending.yml              │
│  Scope: Root management group                                        │
│  Trigger: PR adding a new .bicepparam file to                        │
│           subscription-vending/parameters/                          │
│  Deploys: EA subscription, spoke VNet + hub peering, UDR, RBAC,    │
│           Defender plans, budget alerts, diagnostic settings,        │
│           CanNotDelete lock on networking resource group             │
│  Approval: Network review → Security review → Platform lead (3-way) │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Module Reference

| Module | Path | Target Scope | Description |
|---|---|---|---|
| Management Groups | `platform/management-groups/main.bicep` | Tenant | Deploys the full ALZ management group hierarchy (alz root → platform, landingzones, sandbox, decommissioned, and child groups) |
| Logging | `platform/logging/main.bicep` | Management subscription | Log Analytics Workspace with customer-managed key (CMK), Automation Account, diagnostic settings |
| Connectivity | `platform/connectivity/main.bicep` | Connectivity subscription | Hub VNet, Ingress VNet, Checkpoint CloudGuard VMSS cluster, ExpressRoute Gateway, 28 Private DNS zones |
| PEZ (Perth Extended Zone) | `platform/connectivity/pez/main.bicep` | Connectivity subscription | Secondary hub VNet in Perth Extended Zone, peered to primary hub |
| Identity | `platform/identity/main.bicep` | Identity subscription | Identity VNet with AD DS subnets, NSGs, hub VNet peering |
| Policies | `platform/policies/main.bicep` | Root management group | 28 Azure Policy assignments covering deny, audit, and DeployIfNotExists (DINE) effects |
| Sentinel | `platform/sentinel/main.bicep` | Management subscription | Microsoft Sentinel enablement, 6 scheduled analytics rules, UEBA, Healthcare Sentinel Package (HSP) scoping |
| Monitoring | `platform/monitoring/main.bicep` | Management subscription | Action groups (ops and SOC), platform metric alerts, Azure Monitor workbooks |
| Security Baseline | `platform/security/main.bicep` | Management subscription | Key Vault Premium with HSM, immutable audit storage (WORM), private endpoints, resource locks |
| Subscription Vending | `subscription-vending/main.bicep` | Root management group | Automated spoke provisioning using lz-vending AVM: EA subscription, VNet, hub peering, UDR, RBAC, Defender, budget, diagnostics |

### Connectivity Sub-Modules

| Module | Path | Description |
|---|---|---|
| Checkpoint VMSS | `platform/connectivity/modules/checkpoint-vmss.bicep` | Checkpoint CloudGuard R81.10 VMSS cluster, 2 instances, Load Sharing Multicast, autoscale disabled |
| Checkpoint NVA (legacy) | `platform/connectivity/modules/checkpoint-nva.bicep` | Single-VM NVA reference implementation — not deployed in production |
| ER Connection | `platform/connectivity/modules/er-connection.bicep` | ExpressRoute Gateway to circuit connection resource (run after manual circuit creation) |
| Private DNS | `platform/connectivity/modules/private-dns.bicep` | 28 Private DNS zones for Azure PaaS services, linked to hub VNet |
| Private Endpoint | `platform/connectivity/modules/private-endpoint.bicep` | Reusable private endpoint module used across platform modules |

### Security Sub-Modules

| Module | Path | Description |
|---|---|---|
| RBAC Assignments | `platform/security/modules/rbac-assignments.bicep` | Centralised role assignment module with principal type enforcement |
| Resource Lock | `platform/security/modules/resource-lock.bicep` | CanNotDelete lock applied to platform resource groups |
| Private Endpoint | `platform/security/modules/private-endpoint.bicep` | Private endpoint for Key Vault and immutable storage accounts |

### Subscription Vending Sub-Modules

| Module | Path | Description |
|---|---|---|
| Defender Plan | `subscription-vending/modules/defender-plan.bicep` | Enables selected Defender for Cloud plans on vended subscriptions |
| Subscription Budget | `subscription-vending/modules/subscription-budget.bicep` | Budget alerts at 80%, 100%, and 120% of monthly AUD estimate |
| Subscription Diagnostics | `subscription-vending/modules/subscription-diagnostics.bicep` | Subscription-level diagnostic settings forwarded to central Log Analytics |
| Subscription Lock | `subscription-vending/modules/subscription-lock.bicep` | CanNotDelete lock on the networking resource group of each spoke |

---

## Compliance

This landing zone is designed to support WA Health obligations under the following regulatory and policy frameworks. See **[docs/security-baseline.md](docs/security-baseline.md)** for the full control mapping and evidence register.

### APRA CPS 234 — Information Security

| Control Area | Implementation |
|---|---|
| Information security capability | Centralised platform team ownership; policies enforce baseline at every subscription |
| Policy framework | Azure Policy (28 assignments) enforces security baseline automatically |
| Implementation of controls | Defender for Cloud plans deployed to every vended subscription via DINE policy |
| Incident response | Microsoft Sentinel with 6 analytics rules; HSP threat detection package |
| Testing of controls | Checkov SAST on every pipeline run; Defender for Cloud secure score tracked |
| Internal audit | Immutable audit log storage (WORM) on management subscription; 365-day LAW retention |
| Notification to APRA | Sentinel incident workflow triggers SOC action group for reportable incidents |

### Australian Government Information Security Manual (ISM)

| Control Area | Implementation |
|---|---|
| Asset management | Mandatory tags enforced by policy: `environment`, `dataClassification`, `costCenter`, `ownerEmail` |
| Network segmentation | Hub-and-spoke with mandatory NVA inspection; UDR bypass not permitted |
| Cryptography | ExpressRoute Direct with MACsec (L2 encryption); CMK on Log Analytics; Key Vault HSM |
| Access control | RBAC enforced via policy; no classic administrators; no custom owner roles |
| Audit logging | All resources send diagnostics to central Log Analytics; activity logs forwarded per subscription |
| Patching | Azure Update Manager enforced via DINE policy on all vended subscriptions |
| Multi-factor authentication | Enforced via Entra ID Conditional Access (outside scope of this repo) |

### Essential Eight Maturity Level 2

| Strategy | Implementation |
|---|---|
| Application control | Defender for Endpoint deployed to all subscriptions; policy blocks unsigned extensions |
| Patch applications | Update Manager configured via DINE policy; 48-hour patch window enforced |
| Configure macros | Not applicable to Azure IaaS/PaaS workloads |
| User application hardening | Defender for Cloud recommendations surfaced per subscription |
| Restrict administrative privileges | Azure Policy denies custom owner roles; privileged role assignments alerted in Sentinel |
| Patch operating systems | Update Manager enforced; guest configuration policy audits compliance |
| Multi-factor authentication | Enforced via Entra ID (Conditional Access outside this repo scope) |
| Regular backups | Backup policy enforced via Azure Policy DINE on vended subscriptions |

---

## Security

### Secrets Management

All sensitive values are managed exclusively through **Azure Key Vault Premium (HSM-backed)**. The following controls are in place:

- No secrets, passwords, connection strings, or credentials are stored in code, pipeline variables, or parameter files.
- Pipeline authentication uses **OIDC Federated Credentials** (workload identity federation) — no client secrets are created or stored.
- The Checkpoint VMSS admin password is generated at deployment time and stored in Key Vault; it is never passed as a pipeline variable in plaintext.
- Key Vault is configured with private endpoint only (no public network access), HSM-backed keys, soft delete enabled, and purge protection enabled.
- CMK (customer-managed key) is applied to the Log Analytics Workspace and immutable audit storage.

### CI/CD Authentication

Azure DevOps pipelines authenticate to Azure using **OIDC Workload Identity Federation**:

1. A service principal is registered in Entra ID with no client secret.
2. A federated credential is configured that trusts tokens issued by Azure DevOps for this specific organisation, project, and pipeline.
3. Pipelines exchange a short-lived Azure DevOps OIDC token for an Azure access token at runtime — no long-lived credentials exist anywhere.

See the bootstrap script at `scripts/bootstrap.ps1` for setup instructions.

### Static Analysis

Every pull request and pipeline run executes:

| Tool | What it checks | Configuration |
|---|---|---|
| **Checkov** | Bicep and ARM template misconfigurations, insecure defaults, compliance violations | `.checkov.yaml` |
| **Gitleaks** | Secrets, API keys, connection strings, and credentials committed to the repository | `.gitleaks.toml` |
| **Bicep linter** | Syntax errors, best-practice violations, unused parameters | `bicepconfig.json` |

### Network Security Controls

- All spoke traffic is routed through the Checkpoint CloudGuard VMSS cluster via UDR — there is no mechanism to bypass NVA inspection.
- The Checkpoint VMSS cluster operates in **Load Sharing Multicast** mode (active-active, 2 instances). If one instance becomes unhealthy, traffic routes to the remaining instance automatically.
- ExpressRoute Direct uses **MACsec** (IEEE 802.1AE) for Layer 2 encryption of all traffic between the on-premises edge and the Microsoft Enterprise Edge (MSEE).
- 28 Private DNS zones are deployed in the hub and linked to the hub VNet. Spoke VNets resolve private endpoints via VNet peering (no separate DNS links required per spoke).
- NSGs are applied to all subnets including the Checkpoint external and internal subnets with least-privilege inbound and outbound rules.

### Vulnerability Reporting

To report a security vulnerability in this codebase, see **[SECURITY.md](SECURITY.md)**. Do not raise a public GitHub issue for security vulnerabilities.

---

## Contributing

### Branch Strategy

All changes follow a promotion-based branching model:

```
feature/<name>  ──►  dev  ──►  staging  ──►  main
                      │           │             │
                      ▼           ▼             ▼
                   dev env   staging env    prod env
```

| Branch | Purpose | Deploys to | Protection |
|---|---|---|---|
| `main` | Production-ready — single source of truth | Production Azure environment | 2 approvals, status checks, no force push |
| `staging` | Pre-production validation | Staging Azure environment | 1 approval, Bicep lint check |
| `dev` | Active development and feature work | Dev Azure environment | Bicep lint check |
| `feature/*` | Individual feature branches | No automatic deployment | None |

### Pull Request Requirements

All changes to `platform/` or `subscription-vending/` must satisfy the following before merge:

- [ ] Bicep linter passes with zero errors (warnings must be reviewed)
- [ ] Checkov scan passes — all CRITICAL and HIGH findings resolved
- [ ] Gitleaks scan passes — no secrets detected
- [ ] ARM what-if output reviewed and attached to PR
- [ ] Changes to `platform/connectivity/` require network team review
- [ ] Changes to `platform/sentinel/` or `platform/security/` require security team review
- [ ] Changes to `platform/policies/` require platform lead review
- [ ] All changes to `main` require a minimum of 2 approvals from platform team leads

### Commit Standards

Follow [Conventional Commits](https://www.conventionalcommits.org/) format:

```
feat(connectivity): add PEZ secondary hub VNet peering
fix(sentinel): correct analytics rule query for brute-force detection
docs(expressroute): update circuit creation runbook for MACsec
chore(deps): update AVM lz-vending module to 2.4.0
```

### Adding a New Spoke Subscription

Use the vending script to scaffold the parameter file, then open a pull request:

```powershell
./scripts/new-subscription.ps1 `
    -SubscriptionAlias   "sub-<application>-<environment>" `
    -DisplayName         "<Application> — <Environment>" `
    -TargetMG            "alz-landingzones-corp" `
    -SpokeAddressPrefix  "10.101.0.0/16" `
    -OwnerEmail          "<team>@health.wa.gov.au" `
    -OwnerGroupObjectId  "<azure-ad-group-object-id>"
```

The validation script runs automatically on PR creation and checks for IP address space conflicts, naming convention compliance, and mandatory tag presence. See the pipeline for the three-team approval gate process (network, security, platform leads).

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

Internal use: Western Australian Department of Health — Health Support Services (HSS).

---

## Contact

| Role | Contact |
|---|---|
| Platform Engineering Team | platform-engineering@health.wa.gov.au *(update with actual address)* |
| Security Operations Centre (SOC) | soc@health.wa.gov.au *(update with actual address)* |
| Network Team | network-team@health.wa.gov.au *(update with actual address)* |
| Vulnerability Reporting | See [SECURITY.md](SECURITY.md) |

For general questions about the platform, raise an issue in Azure DevOps (DD03) using the platform support request template.
