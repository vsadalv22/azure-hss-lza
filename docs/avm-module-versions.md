# AVM Module Version Tracking

> Updated: 2026-04-13
> Registry: `br/public:avm/` (Azure Verified Modules public registry)

## Module Inventory

| Module Path | Version Used | Latest Stable | Status | Notes |
|-------------|--------------|----------------|--------|-------|
| `avm/res/network/public-ip-address` | `0.7.1` | `0.7.1` | Current | Used in platform/connectivity/main.bicep and platform/connectivity/pez/main.bicep (Checkpoint external PIP, ER Gateway PIP) |
| `avm/res/network/network-security-group` | `0.5.0` | `0.5.0` | Current | Used in platform/connectivity/main.bicep and platform/connectivity/pez/main.bicep (Checkpoint external/internal NSGs, ingress DMZ, management NSG) |
| `avm/res/network/virtual-network` | `0.5.2` | `0.5.2` | Current | Used in platform/connectivity/main.bicep (hub VNet, ingress VNet) and platform/identity/main.bicep (identity VNet) |
| `avm/res/network/virtual-network-gateway` | `0.5.0` | `0.5.0` | Current | Used in platform/connectivity/main.bicep — ExpressRoute gateway |
| `avm/res/network/route-table` | `0.4.0` | `0.4.0` | Current | Used in platform/connectivity/main.bicep and platform/connectivity/pez/main.bicep — UDR forcing egress via Checkpoint internal IP |
| `avm/res/operational-insights/workspace` | `0.9.0` | `0.9.0` | Current | Used in platform/logging/main.bicep — central Log Analytics workspace |
| `avm/res/automation/automation-account` | `0.11.0` | `0.11.0` | Current | Used in platform/logging/main.bicep — Automation Account linked to Log Analytics |
| `avm/res/insights/action-group` | `0.4.0` | `0.4.0` | Current | Used in platform/monitoring/main.bicep — ops and security action groups |
| `avm/ptn/lz/sub-vending` | `0.4.1` | `0.4.1` | Current | Used in subscription-vending/main.bicep — EA subscription creation, MG placement, spoke VNet, hub peering, RBAC |

## File Reference Map

| File | Modules Used |
|------|-------------|
| `platform/connectivity/main.bicep` | `public-ip-address:0.7.1`, `network-security-group:0.5.0`, `virtual-network:0.5.2`, `virtual-network-gateway:0.5.0`, `route-table:0.4.0` |
| `platform/connectivity/pez/main.bicep` | `public-ip-address:0.7.1`, `network-security-group:0.5.0`, `route-table:0.4.0` |
| `platform/identity/main.bicep` | `virtual-network:0.5.2` |
| `platform/logging/main.bicep` | `operational-insights/workspace:0.9.0`, `automation/automation-account:0.11.0` |
| `platform/monitoring/main.bicep` | `insights/action-group:0.4.0` |
| `subscription-vending/main.bicep` | `avm/ptn/lz/sub-vending:0.4.1` |

## How to Check for Updates

```bash
# Check AVM module latest versions via Bicep registry
az bicep registry list-modules --registry mcr.microsoft.com/bicep

# Or browse: https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/
```

## Update Process

1. Review the [AVM release notes](https://github.com/Azure/bicep-registry-modules/releases) for breaking changes.
2. Update the version string in the relevant `.bicep` file (e.g., `br/public:avm/res/network/route-table:0.4.0` → new version).
3. Run `az bicep build` to validate the updated module reference compiles without errors.
4. Deploy to a sandbox subscription before promoting to production.
5. Update the version in this table once verified.
