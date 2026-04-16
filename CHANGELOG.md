# Changelog

All notable changes to the WA Health HSS Azure Landing Zone are documented here.

Format: [Semantic Versioning](https://semver.org/) — `MAJOR.MINOR.PATCH`
- **MAJOR**: breaking changes to module interfaces or topology
- **MINOR**: new features, new modules, new policy assignments
- **PATCH**: bug fixes, documentation updates, parameter additions

---

## [Unreleased]

### Planned
- Checkpoint upgrade procedure automation runbook
- Azure Update Manager baselines for OS patching
- PIM (Privileged Identity Management) configuration module

---

## [2.0.0] — 2026-04-13

### Added — Enterprise Security Hardening
- `platform/security/` module: Platform Key Vault (Premium/HSM), immutable audit log
  storage (WORM 365-day), private endpoint module, resource locks
- `platform/security/modules/rbac-assignments.bicep`: least-privilege RBAC model
- `subscription-vending/modules/subscription-lock.bicep`: EA subscription CanNotDelete lock
- Defender CSPM (CloudPosture plan) on all vended subscriptions
- `.github/workflows/00-security-checks.yml`: Checkov SAST + Gitleaks + Bicep lint
- `azure-pipelines/00-security-checks.yml`: same controls for Azure DevOps
- `.gitleaks.toml`: 6 custom secret detection rules
- `docs/security-baseline.md`: APRA CPS 234 / ISM / Essential Eight ML2 compliance mapping
- `docs/checkpoint-first-boot.md`: 8-step first boot runbook

### Added — Policy Expansion
- 7 new Azure Policy assignments (TLS 1.2, no public blob, storage HTTPS,
  KV purge protection, Azure Monitor Agent, KV private endpoint audit,
  Defender for Containers)
- Total: 28 policy assignments (18 root + 3 sub-scope + 7 new)

### Changed
- Log Analytics workspace: User-Assigned MI for CMK, audit log data export to
  immutable storage, workspace-level resource permission access control
- Checkpoint VMSS boot diagnostics: TLS 1.2, no public access, deny network ACLs
- Hub connectivity resource group: CanNotDelete lock

---

## [1.3.0] — 2026-04-13

### Fixed — 30 Code Review Issues
- Critical: parameterised internal LB IP (no hardcoded 10.0.1.4)
- Critical: Key Vault params for Checkpoint admin password
- Critical: pipeline timeouts (120m connectivity, 90m vending)
- High: removed UDR from management subnet (platform traffic unblocked)
- High: added NSG to management subnet (on-prem RDP/SSH only)
- High: ER Gateway diagnostic settings
- High: DC subnet UDR for identity module
- Medium: HSP cross-access KQL query corrected
- Medium: 3-attempt retry loop for ER provisioning status check
- Medium: GitHub Actions what-if job added to connectivity workflow
- All: replaced hardcoded IPs with cidrSubnet()/cidrHost() derivations

---

## [1.2.0] — 2026-04-13

### Added — Excel Requirements Alignment (DD03–DD40)
- `platform/connectivity/pez/main.bicep`: Perth Extended Zone secondary hub (DD17/DD22)
- `platform/connectivity/modules/checkpoint-vmss.bicep`: VMSS cluster model (DD30)
- Dual Security VNet architecture: ingress + hub (DD31)
- DDoS Protection Standard (DD34)
- `azure-pipelines/`: 6 Azure DevOps pipeline files (DD03)
- Sentinel HSP row-level data scoping (DD40)
- Tiered policy scope at sub-MG level (DD36)

---

## [1.1.0] — 2026-04-12

### Added
- ExpressRoute gateway (zone-redundant, ErGw1AZ)
- Microsoft Sentinel with 5 analytics rules and UEBA
- 4-stage subscription vending approval (validate → what-if → 3-team review → deploy)
- 15 Azure Policy assignments (baseline security)
- Private DNS zones (28 zones for PaaS)
- Monitoring: action groups, activity log alerts, Network Watcher

### Changed
- ExpressRoute circuit separated from IaC — manual creation by network team
- Removed Azure Bastion (out of scope)
- Removed VPN Gateway (replaced by ExpressRoute)

---

## [1.0.0] — 2026-04-11

### Added — Initial Release
- Hub-and-spoke topology (Australia East)
- Checkpoint CloudGuard NVA (single VM, dual NIC)
- EA subscription vending machine
- Management group hierarchy (ALZ standard)
- Log Analytics workspace + Automation Account
- GitHub Actions CI/CD pipelines
- Initial README
