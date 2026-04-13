# Security Policy

## Supported Versions

| Branch | Supported | Notes |
|--------|-----------|-------|
| `main` | ✅ Active | Production-grade, protected |
| `staging` | ✅ Active | Pre-production validation |
| `prod` | ✅ Active | Production deployment gate |
| `dev` | ⚠️ Best-effort | Development, not hardened |

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.**

This repository contains infrastructure-as-code for WA Health / HSS Azure Landing Zone.
A vulnerability here could affect production health systems.

**To report a security issue:**

1. Email the platform security team: `platform-security@health.wa.gov.au` *(replace with actual address)*
2. Include:
   - Clear description of the vulnerability
   - Affected files / components (e.g., Bicep module, pipeline YAML)
   - Steps to reproduce or exploit
   - Potential impact assessment
3. **Response SLA:**
   - Acknowledgement: within 24 business hours
   - Initial triage: within 3 business days
   - Remediation plan: within 10 business days for High/Critical

## Security Controls In This Repository

### Code Quality Gates (automated on every PR)
- ✅ **Bicep Lint** — syntax and best-practice enforcement
- ✅ **Checkov IaC SAST** — static analysis for security misconfigurations
- ✅ **Gitleaks** — secret and credential detection
- ✅ **Bicep Build Validation** — ARM template output verification

### Branch Protection (must be configured in GitHub Settings)
- `main`, `staging`, `prod` require:
  - At least 2 approving reviews
  - All status checks passing (00-security-checks workflow)
  - No direct pushes — PRs only
  - Signed commits required

### Authentication & Secrets
- **Azure authentication**: OIDC federated workload identity — no client secrets stored
- **Checkpoint password**: Stored exclusively in `kv-platform-sec-aue-001` Key Vault
- **Pipeline variables**: Azure DevOps variable groups (secret variables encrypted at rest)
- **GitHub secrets**: Repository secrets only (never in YAML files)
- **No hardcoded credentials** in any file — enforced by Gitleaks on every PR

### Infrastructure Security
- All Bicep modules follow Azure Verified Modules (AVM) standards
- Private endpoints used for all PaaS services (Key Vault, Storage, Log Analytics)
- TLS 1.2 minimum enforced via Azure Policy
- Resource locks (CanNotDelete) on all critical platform resources
- Immutable audit log storage (365-day WORM) for tamper-evident logging

## Dependency Management

AVM module versions are tracked in [`docs/avm-module-versions.md`](../docs/avm-module-versions.md).

To check for updates:
```bash
# Browse AVM module catalogue
# https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/
```

Update modules in `dev` branch first, test in `staging`, then promote to `main`/`prod`.

## Compliance

This repository implements controls aligned with:
- **APRA CPS 234** — Information Security for Financial Institutions
- **Australian ISM** — Information Security Manual (Australian Signals Directorate)
- **Essential Eight ML2** — Australian Government maturity model
- **WA Health Information Security Policy**

See [`docs/security-baseline.md`](../docs/security-baseline.md) for the full compliance mapping.
