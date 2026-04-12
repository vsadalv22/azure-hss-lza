## Pull Request — HSS Azure Landing Zone

### Type of Change
<!-- Check all that apply -->
- [ ] 🆕 New subscription vending (`.bicepparam` file added)
- [ ] 🔧 Platform change (management groups / logging / connectivity / sentinel)
- [ ] 🔒 Security / policy update
- [ ] 🐛 Bug fix
- [ ] 📖 Documentation only
- [ ] ♻️ Refactor (no functional change)

---

### Linked Issue
<!-- For subscription vending PRs, link the approved GitHub Issue -->
Closes #<!-- issue number -->

---

## Subscription Vending Checklist
<!-- Complete this section only for PRs adding a new .bicepparam file -->
<!-- Skip for non-vending PRs -->

<details>
<summary>Click to expand subscription vending checklist</summary>

#### 1. Identity & Ownership
- [ ] Subscription alias follows naming convention: `sub-<appname>-<env>` (lowercase, hyphens only)
- [ ] Display name is descriptive and matches the linked Issue
- [ ] AAD group Object ID verified — group exists and contains correct members
- [ ] Owner email is a valid distribution list (not an individual)
- [ ] Cost centre / business unit tag populated

#### 2. Management Group Placement
- [ ] Target MG is appropriate:
  - `alz-landingzones-corp` → private / internal workloads
  - `alz-landingzones-online` → internet-facing workloads
  - `alz-sandbox` → experimental only
- [ ] Workload type (`Production` / `DevTest`) is set correctly

#### 3. Networking
- [ ] Spoke CIDR is a /16 and does not overlap with:
  - [ ] Hub: `10.0.0.0/16`
  - [ ] Identity: `10.10.0.0/16`
  - [ ] All existing corp spokes (`10.100.x.0/16` — `10.199.x.0/16`)
  - [ ] All existing online spokes (`10.200.x.0/16` — `10.254.x.0/16`)
- [ ] Subnet CIDRs are within the spoke CIDR
- [ ] Route table ID points to hub UDR (`udr-to-checkpoint-001`)
- [ ] Hub VNet ID is correct (matches `HUB_VNET_ID` secret)
- [ ] `useRemoteGateways: true` — traffic uses ExpressRoute via hub

#### 4. Security & Compliance
- [ ] Data classification documented in tags
- [ ] Defender for Cloud plan selected appropriately
- [ ] Budget alert threshold set (`budgetAmountAUD` parameter)
- [ ] Compliance tags populated (APRA / ISM / Essential Eight as applicable)

#### 5. What-If Review
- [ ] What-if output has been reviewed (see workflow run comments below)
- [ ] No unexpected resource deletions or modifications shown in what-if
- [ ] Deployment scope (management group) is correct

#### 6. Approvals Required
- [ ] ✅ **Platform Team** — architecture + naming + MG placement (`@platform-team`)
- [ ] ✅ **Network Team** — IP allocation confirmed (`@network-team`)
- [ ] ✅ **Security Team** — access + compliance + Defender plan (`@security-team`)

</details>

---

## Platform Change Checklist
<!-- Complete this section for non-vending platform changes -->

- [ ] Bicep lint passes locally (`az bicep build --file <file>`)
- [ ] What-if reviewed — changes are expected and understood
- [ ] No hardcoded subscription IDs, passwords, or secrets
- [ ] Diagnostic settings included on all new resources
- [ ] Resource tags applied consistently
- [ ] Outputs exposed for downstream modules

---

## What-If Summary
<!-- Paste key lines from the what-if output, or link to the Actions run -->

```
Paste what-if output here or reference the Actions run link
```

---

## Testing Evidence
<!-- How has this change been validated? -->

- Environment tested in: `dev` / `staging`
- Actions run link: <!-- link -->

---

## Rollback Plan
<!-- How do we revert if this causes issues in production? -->

- Revert PR: this PR can be reverted via `git revert`
- Impact of revert: <!-- describe -->
