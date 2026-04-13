# Checkpoint CloudGuard — First Boot & Cluster Configuration

**Applies to:** `platform/connectivity/modules/checkpoint-vmss.bicep`
**Must complete after:** `03-connectivity` pipeline deploys the VMSS successfully
**Estimated time:** 2–3 hours for first deployment

---

## ⚠️ Critical: Complete Before Any Traffic Flows

Until Steps 1–4 are complete:
- Internal LB health probe (port 8117) will mark all instances **Unhealthy**
- All spoke UDRs point to the LB frontend IP — traffic will be **silently dropped**
- No internet egress or hybrid connectivity is available to spoke workloads

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| SmartConsole | Version R81.10 or later, installed on admin workstation |
| Network access | Workstation reachable to management subnet via ExpressRoute or jump host |
| Azure RBAC | Contributor on `rg-connectivity-hub-australiaeast-001` |
| Checkpoint licence | BYOL activation code, or PAYG (confirm with licensing team) |
| Key Vault access | `Key Vault Secrets User` on `kv-platform-sec-aue-001` to retrieve admin password |

---

## Step 1 — Retrieve Admin Password from Key Vault

```bash
# Get the Checkpoint admin password (never stored in code — Key Vault only)
az keyvault secret show \
  --vault-name kv-platform-sec-aue-001 \
  --name checkpoint-admin-password \
  --query value -o tsv
```

---

## Step 2 — Identify VMSS Instance IPs

```bash
# List all VMSS instance private IPs
az vmss nic list \
  --resource-group rg-connectivity-hub-australiaeast-001 \
  --vmss-name vmss-checkpoint-hub-001 \
  --query "[].{Instance:virtualMachine.id, IP:ipConfigurations[0].privateIPAddress}" \
  --output table
```

---

## Step 3 — Enable Health Check Port on Every Instance

> ⚠️ Must be done on **every** VMSS instance. The LB health probe on port 8117 will
> fail until this is enabled, preventing traffic from reaching the NVA.

Connect from the management jump host (in `snet-management`) to each instance:

```bash
# SSH to each VMSS instance from the management jump host
ssh azureadmin@<instance-private-ip>

# Switch to expert mode
clish
set expert-password

# Enable web management on port 8117 (used as health probe)
set web ssl-port 8117
set web daemon enable
save config

# Verify port is listening
netstat -tlnp | grep 8117
```

After enabling on all instances, verify the LB health probe is succeeding:

```bash
# Check DipAvailability metric (should be 100%)
az monitor metrics list \
  --resource "/subscriptions/<sub-id>/resourceGroups/rg-connectivity-hub-australiaeast-001/providers/Microsoft.Network/loadBalancers/lbi-checkpoint-hub-001" \
  --metric DipAvailability \
  --interval PT1M \
  --query "value[0].timeseries[0].data[-3:]"
```

---

## Step 4 — Register Gateways in SmartConsole

1. Open **SmartConsole R81.10**
2. Navigate to **Gateways & Servers** → **New** → **Gateway**
3. Enter the **internal LB frontend IP** (derived from `hubVnetAddressPrefix` — check `cidrHost(cidrSubnet(<prefix>,12,16), 4)`)
4. Set **Platform** to `Microsoft Azure`
5. Enable **ClusterXL** → mode: **Load Sharing Multicast**
6. Complete the **First Time Wizard**

---

## Step 5 — Add Both Instances as Cluster Members

In SmartConsole → select the cluster gateway object:

1. **Topology** tab → **Edit** → add each VMSS instance by its private IP
2. Set `eth0` (external NIC) to the `snet-checkpoint-external` subnet
3. Set `eth1` (internal NIC) to the `snet-checkpoint-internal` subnet with the VIP (LB frontend IP)
4. **ClusterXL** tab → confirm **Load Sharing Multicast** mode

---

## Step 6 — Create and Install Baseline Security Policy

1. In SmartConsole → **Security Policies** → **New Policy Layer**
2. Create baseline rules:

| Rule | Source | Destination | Service | Action |
|------|--------|-------------|---------|--------|
| Allow-ER-to-Spokes | On-Prem (ER) | Spoke subnets | Any | Accept + Log |
| Allow-Spokes-to-Internet | Spoke subnets | Any | HTTPS, HTTP | Accept + Inspect |
| Allow-Management | Management subnet | Any | Any | Accept + Log |
| Cleanup | Any | Any | Any | Drop + Log |

3. **Install Policy** → select the cluster object → **Install**

---

## Step 7 — Verify End-to-End Traffic

```bash
# From a VM in a spoke subnet, test internet egress
curl -I https://api.ipify.org

# Check Checkpoint logs in SmartConsole → Logs & Monitor
# Verify traffic is being inspected (not bypassed)

# Verify BGP routes are propagated from the ER gateway
az network vnet-gateway list-bgp-peer-status \
  --resource-group rg-connectivity-hub-australiaeast-001 \
  --name ergw-hub-australiaeast-001 \
  --output table
```

---

## Step 8 — Update Monitoring

Once the cluster is healthy, update the monitoring module with the LB resource ID:

```bash
# Get the internal LB resource ID
az network lb show \
  --resource-group rg-connectivity-hub-australiaeast-001 \
  --name lbi-checkpoint-hub-001 \
  --query id -o tsv
```

Add this as `checkpointInternalLbId` in the `07-platform-monitoring` pipeline parameters.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| All LB backends unhealthy | Port 8117 not enabled | Complete Step 3 |
| Traffic dropped at spoke UDR | Checkpoint policy Cleanup rule | Add allow rules in Step 6 |
| Cannot SSH to instance | NSG or route table | Verify `snet-management` NSG allows SSH from on-prem |
| SmartConsole cannot connect | ER not provisioned | Check ER circuit status (`docs/expressroute-setup.md`) |
| Health probe intermittent | Single instance upgraded | Check VMSS upgrade mode (must be Manual) |

---

## See Also

- `docs/checkpoint-upgrade-procedure.md` — Rolling upgrade for VMSS instances
- `docs/expressroute-setup.md` — ExpressRoute circuit provisioning
- `docs/security-baseline.md` — Security compliance mapping
- `platform/connectivity/modules/checkpoint-vmss.bicep` — VMSS Bicep module
