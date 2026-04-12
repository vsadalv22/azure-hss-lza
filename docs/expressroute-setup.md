# ExpressRoute Circuit — Manual Setup Runbook

> **Scope:** Network team / Platform team
> **Applies to:** `hss-azure-ea-lza` — Australia East hub connectivity
> **Related workflow:** [03b-platform-er-connection](./.github/workflows/03b-platform-er-connection.yml)

---

## Overview

The ExpressRoute **circuit** is created and managed **manually** — it is not provisioned by IaC.
This is intentional: the circuit has a commercial relationship with a provider (Equinix / Megaport / Telstra),
requires billing approval, and has a long provisioning lead time that sits outside the CI/CD pipeline.

The **gateway** and **connection** resources are still managed as code:

| Resource | How created | Workflow |
|---|---|---|
| ExpressRoute Gateway (`ergw-hub-australiaeast-001`) | **IaC (Bicep)** | `03-platform-connectivity` |
| ExpressRoute Circuit (`erc-hub-australiaeast-001`) | **Manual — this runbook** | — |
| ExpressRoute Connection (`con-ergw-to-circuit-001`) | **IaC (Bicep)** | `03b-platform-er-connection` |

---

## Pre-requisites

Before creating the circuit, confirm the following with the network team:

- [ ] Workflow `03-platform-connectivity` has completed — ER Gateway is deployed
- [ ] Provider and peering location confirmed (see table below)
- [ ] Bandwidth and SKU tier approved by management
- [ ] EA subscription (`sub-connectivity`) has sufficient quota for an ER circuit
- [ ] `ER_GATEWAY_ID` GitHub secret has been set from the workflow 03 output

### Recommended Circuit Settings

| Parameter | Value | Notes |
|---|---|---|
| Circuit name | `erc-hub-australiaeast-001` | Follow naming convention |
| Region | `Australia East` | Must match gateway region |
| Provider | *(your provider)* | e.g. Equinix, Megaport, Telstra |
| Peering location | `Sydney` | Physical ER peering location |
| Bandwidth | `1 Gbps` | Upgradeable online without downtime |
| SKU tier | `Standard` | Upgrade to Premium only if >4000 routes or Global Reach needed |
| SKU family | `UnlimitedData` | Avoids unpredictable egress billing |
| Subscription | `sub-connectivity` | Connectivity subscription |
| Resource group | `rg-connectivity-hub-australiaeast-001` | Same RG as gateway |

---

## Step-by-Step: Create the Circuit

### Option A — Azure Portal (recommended for first setup)

1. Sign in to the **Azure Portal** using an account with at least `Contributor` on the connectivity subscription
2. Search for **ExpressRoute circuits** → **+ Create**
3. Fill in the **Basics** tab:
   - **Subscription:** `sub-connectivity`
   - **Resource group:** `rg-connectivity-hub-australiaeast-001`
   - **Name:** `erc-hub-australiaeast-001`
   - **Region:** `Australia East`
4. Fill in the **Configuration** tab:
   - **Port type:** Provider
   - **Provider:** *(select your provider)*
   - **Peering location:** `Sydney`
   - **Bandwidth:** `1 Gbps`
   - **SKU:** Standard
   - **Billing model:** Unlimited data
5. Apply **tags:**
   ```
   environment  = connectivity
   managedBy    = platform-team
   createdBy    = manual
   costCenter   = platform
   ```
6. Click **Review + create** → **Create**
7. After deployment, go to the circuit **Overview** and copy the **Service Key**

### Option B — Azure CLI

```bash
# Set variables
SUBSCRIPTION_ID="<connectivity-subscription-id>"
RG="rg-connectivity-hub-australiaeast-001"
CIRCUIT_NAME="erc-hub-australiaeast-001"
PROVIDER="<your-provider>"          # e.g. "Equinix" — must match portal dropdown exactly
PEERING_LOCATION="Sydney"
BANDWIDTH=1000
LOCATION="australiaeast"

# Create circuit
az network express-route create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --name "$CIRCUIT_NAME" \
  --location "$LOCATION" \
  --provider "$PROVIDER" \
  --peering-location "$PEERING_LOCATION" \
  --bandwidth "$BANDWIDTH" \
  --sku-tier Standard \
  --sku-family UnlimitedData \
  --tags environment=connectivity managedBy=platform-team createdBy=manual costCenter=platform

# Get service key
az network express-route show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --name "$CIRCUIT_NAME" \
  --query serviceKey \
  --output tsv
```

---

## Step 2 — Send Service Key to Provider

The **Service Key** is a unique GUID that identifies your circuit to the provider.

1. Log in to your provider portal:
   - **Equinix:** [ecx.equinix.com](https://ecx.equinix.com)
   - **Megaport:** [portal.megaport.com](https://portal.megaport.com)
   - **Telstra:** contact your account manager
2. Create a new **Azure ExpressRoute** connection
3. Enter the **Service Key** when prompted
4. Select the correct **bandwidth** and **peering location** (Sydney)
5. Submit — the provider will provision the circuit (typically **1–5 business days**)

---

## Step 3 — Verify Circuit Provisioning

Monitor the provisioning status in the Azure Portal or via CLI:

```bash
az network express-route show \
  --subscription "<connectivity-subscription-id>" \
  --resource-group "rg-connectivity-hub-australiaeast-001" \
  --name "erc-hub-australiaeast-001" \
  --query "{CircuitState:circuitProvisioningState, ProviderState:serviceProviderProvisioningState}" \
  --output table
```

Wait until both values show:

| Field | Expected Value |
|---|---|
| `CircuitState` | `Enabled` |
| `ProviderState` | `Provisioned` |

> **Note:** `NotProvisioned` or `Provisioning` means the provider has not yet completed their side. This is normal and can take 1–5 business days. Do **not** proceed to Step 4 until `ProviderState = Provisioned`.

---

## Step 4 — Copy Circuit Resource ID

Get the circuit resource ID — you will need it for workflow `03b`:

```bash
az network express-route show \
  --subscription "<connectivity-subscription-id>" \
  --resource-group "rg-connectivity-hub-australiaeast-001" \
  --name "erc-hub-australiaeast-001" \
  --query id \
  --output tsv
```

It will look like:
```
/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-connectivity-hub-australiaeast-001/providers/Microsoft.Network/expressRouteCircuits/erc-hub-australiaeast-001
```

---

## Step 5 — Update GitHub Secret

Set the `ER_CIRCUIT_RESOURCE_ID` secret in the repository:

**Settings → Secrets and variables → Actions → New repository secret**

| Secret | Value |
|---|---|
| `ER_CIRCUIT_RESOURCE_ID` | *(circuit resource ID from Step 4)* |

---

## Step 6 — Run Workflow 03b

Once the circuit is provisioned, trigger the connection workflow:

1. Go to **Actions → "03b - Platform: ExpressRoute Connection"**
2. Click **Run workflow**
3. Paste the circuit resource ID in the input field
4. Leave other inputs as defaults unless creating a second circuit
5. Click **Run workflow**

The workflow will:
- Verify the circuit `ProviderState = Provisioned` before proceeding
- Run a Bicep what-if
- Require platform team approval (environment gate: `platform-production`)
- Deploy the `Microsoft.Network/connections` resource
- Post a verification checklist in the job summary

---

## Step 7 — Verify End-to-End Connectivity

After the connection is deployed, verify:

```bash
# Check connection state (should be 'Connected')
az network vpn-connection show \
  --subscription "<connectivity-subscription-id>" \
  --resource-group "rg-connectivity-hub-australiaeast-001" \
  --name "con-ergw-to-circuit-001" \
  --query connectionStatus \
  --output tsv

# Check BGP routes learned from on-prem
az network vnet-gateway list-learned-routes \
  --subscription "<connectivity-subscription-id>" \
  --resource-group "rg-connectivity-hub-australiaeast-001" \
  --name "ergw-hub-australiaeast-001" \
  --output table
```

Expected BGP peers and on-prem prefixes should appear in the learned routes table.

---

## Bandwidth Upgrade

ExpressRoute bandwidth can be **increased without downtime**:

```bash
az network express-route update \
  --subscription "<connectivity-subscription-id>" \
  --resource-group "rg-connectivity-hub-australiaeast-001" \
  --name "erc-hub-australiaeast-001" \
  --bandwidth 2000   # Mbps — increase only, never decrease
```

> **Note:** Bandwidth can only be increased, not decreased. Coordinate with your provider before changing bandwidth as they must also update their side.

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| `ProviderState: NotProvisioned` after 5+ days | Provider has not acted on the service key | Contact provider support with service key |
| Connection in `Connecting` state | BGP peering not established | Verify on-prem CE router BGP config; check ASN |
| No routes learned by gateway | Peering not configured on circuit | Configure Private Peering on the circuit (Portal → Peerings → + Add) |
| Spokes can't reach on-prem | UDR missing or wrong next hop | Verify `udr-to-checkpoint-001` has `0.0.0.0/0 → 10.0.1.4` and is attached to spoke subnets |
| On-prem can't reach spokes | On-prem router not advertising Azure prefixes | Verify CE router is receiving and accepting BGP prefixes from ER |

---

## Circuit Deletion

> ⚠️ **Warning:** Deleting an ER circuit immediately terminates all traffic. Always decommission workloads first.

Deletion order:
1. Delete the connection resource (`03b` workflow in reverse or Portal)
2. Notify the provider to deprovision their side
3. Wait for `ProviderState: NotProvisioned`
4. Delete the circuit resource via Portal or CLI
5. Delete the gateway if no longer needed (via `03-platform-connectivity` — update template)
