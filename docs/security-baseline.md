# WA Health HSS — Azure Landing Zone Security Baseline

**Classification:** OFFICIAL: Sensitive  
**Aligned With:** APRA CPS 234 | Australian ISM | Essential Eight Maturity Level 2  
**Last Updated:** 2026-04-13

---

## 1. Identity & Access Management

| Control | Implementation | Status |
|---------|---------------|--------|
| No standing privileged access | Azure PIM (Privileged Identity Management) for Owner/Contributor roles | Manual setup required post-deploy |
| MFA for all administrative access | Conditional Access policy enforcing MFA for Azure Portal + CLI | Manual setup in Entra ID |
| No service principal secrets | All automation uses Managed Identities or OIDC federated credentials | ✅ Implemented in pipelines |
| Least-privilege RBAC | Role assignments at narrowest required scope | ✅ `platform/security/modules/rbac-assignments.bicep` |
| No custom subscription owner roles | Azure Policy DENY (policyNoCustomOwner) | ✅ Deployed |
| Regular access reviews | Entra ID Access Reviews on all privileged groups (quarterly) | Manual setup required |

## 2. Network Security

| Control | Implementation | Status |
|---------|---------------|--------|
| Hub-and-spoke with mandatory NVA inspection | Checkpoint CloudGuard VMSS, UDRs on all spoke subnets | ✅ Deployed |
| Dual Security VNet (ingress/egress separation) | `vnet-ingress-*` + `vnet-hub-*` per DD31 | ✅ Deployed |
| No public IPs on VMs | Azure Policy DENY (policyDenyPublicIpVm) | ✅ Deployed |
| No RDP/SSH from internet | Azure Policy DENY (policyDenyRdpFromInternet/policyDenySshFromInternet) | ✅ Deployed |
| DDoS Protection Standard | DDoS plan linked to hub + ingress VNets | ✅ Deployed |
| Private endpoints for PaaS | Key Vault, Storage, Log Analytics via private endpoints | ✅ `platform/security/main.bicep` |
| ExpressRoute MACsec | Configured manually on ER Direct ports by network team | Manual — see `docs/expressroute-setup.md` |

## 3. Data Protection

| Control | Implementation | Status |
|---------|---------------|--------|
| Encryption at rest (platform-managed) | All Azure storage encrypted by default | ✅ Default |
| Encryption at rest (customer-managed key) | Log Analytics workspace CMK via Key Vault | ✅ `platform/security/main.bicep` |
| Encryption in transit | TLS 1.2 minimum enforced via policy | ✅ `policyStorageTls` |
| Key Vault Premium (HSM-backed) | `kv-platform-sec-aue-001` with HSM keys | ✅ Deployed |
| Soft delete + purge protection on Key Vault | 90-day retention, purge protection enabled | ✅ Deployed |
| Immutable audit logs (WORM) | Storage account with immutability policy, 365-day lock | ✅ `platform/security/main.bicep` |

## 4. Monitoring & Incident Response

| Control | Implementation | Status |
|---------|---------------|--------|
| Centralised SIEM | Microsoft Sentinel on shared Log Analytics workspace | ✅ `platform/sentinel/main.bicep` |
| Security alerts | 6 analytics rules including HSP cross-access detection | ✅ Deployed |
| UEBA | User Entity Behaviour Analytics enabled | ✅ Deployed |
| Defender for Cloud | Plans enabled: Servers P2, Storage, KV, SQL, Containers | ✅ Via policy DINE |
| NVA health monitoring | LB DipAvailability alert (severity 1) | ✅ `platform/monitoring/main.bicep` |
| Audit log export | SecurityEvent, AzureActivity, SigninLogs to immutable storage | ✅ Configured |

## 5. Vulnerability Management (Essential Eight)

| Control | Implementation | Status |
|---------|---------------|--------|
| Patch OS (ML2: within 48h for critical) | Azure Update Manager via Automation Account | Manual runbook required |
| Application control | Defender for Endpoint app control policies | Manual configuration |
| Restrict admin privileges | PIM + Conditional Access | Manual setup |
| Multi-factor authentication | Conditional Access: require MFA for all cloud services | Manual setup in Entra ID |
| Regular backups | Azure Backup for critical VMs (Checkpoint, DCs) | Manual runbook required |

## 6. Subscription Vending Security Controls

Every new subscription vended via the landing zone automatically receives:
- [ ] Defender for Cloud plans (Servers P2 + Storage + KV + SQL + Containers)
- [ ] Budget alerts (80% / 100% / 120% of AUD budget)
- [ ] Mandatory tags (environment, managedBy, costCenter, hsp-id)
- [ ] Spoke VNet with UDR forcing all traffic through Checkpoint NVA
- [ ] Diagnostic settings routing logs to central Log Analytics workspace
- [ ] Resource lock (CanNotDelete) on networking resource group
- [ ] Azure Policy inheritance from parent management group

## 7. Compliance Mapping

### APRA CPS 234
- CPS 234.15: Information security capability → Checkpoint NVA + Sentinel + Defender
- CPS 234.17: Systematic testing → Pipeline what-if + Bicep lint + policy compliance scans
- CPS 234.19: Internal audit → Immutable logs + Sentinel analytics rules

### Australian ISM
- ISM-0407: Network segmentation → Hub-and-spoke + NVA inspection enforced by UDR
- ISM-1139: TLS 1.2+ → Policy enforcement on all storage accounts
- ISM-1230: MFA → Conditional Access (manual Entra ID configuration)
- ISM-1277: Privileged access workstations → Management subnet with restricted NSG

### Essential Eight ML2
- Patch applications ≤ 48h → Update Manager + monitoring
- Restrict admin privileges → PIM + RBAC least-privilege
- MFA for privileged access → Conditional Access
- Regular backups → Azure Backup (manual configuration required)

---

## 8. Post-Deployment Checklist

- [ ] Configure Azure PIM for Owner, Contributor, and Security Admin roles
- [ ] Create Conditional Access policies (MFA for all, block legacy auth)
- [ ] Create Checkpoint admin password secret in `kv-platform-sec-aue-001`
- [ ] Configure Checkpoint SmartConsole and enable health check port 8117
- [ ] Enable Access Reviews on platform-engineers, soc, network-engineers groups
- [ ] Set up Azure Update Manager baselines for OS patching
- [ ] Configure Azure Backup for Checkpoint VMSS and Domain Controllers
- [ ] Complete ExpressRoute circuit provisioning with provider (NextDC P1 Perth)
- [ ] Enable MACsec on ExpressRoute Direct ports (see `docs/expressroute-setup.md`)
- [ ] Run 06-platform-security pipeline to deploy Key Vault and immutable storage
- [ ] Grant Log Analytics Managed Identity the Key Vault Crypto User role
- [ ] Test Sentinel analytics rules with simulated events
- [ ] Review and acknowledge all Defender for Cloud recommendations
