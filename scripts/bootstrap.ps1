#Requires -Modules Az.Accounts, Az.Resources, Az.ManagedServiceIdentity
<#
.SYNOPSIS
    Bootstrap script - create the service principal and GitHub secrets required
    for ALZ Bicep pipelines. Run this ONCE from a machine with Owner on the
    root management group and EA billing account access.

.DESCRIPTION
    1. Creates an App Registration + Service Principal in Entra ID
    2. Assigns the required RBAC roles (tenant root, EA enrollment)
    3. Configures Federated Credentials for GitHub OIDC (no secrets stored)
    4. Outputs the GitHub secrets to set in your repository

.EXAMPLE
    ./scripts/bootstrap.ps1 `
        -TenantId          "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -GitHubOrg         "your-org" `
        -GitHubRepo        "alz-bicep" `
        -EABillingAccount  "12345678" `
        -EAEnrollmentAcct  "987654" `
        -ManagementSubId   "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ConnectivitySubId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -IdentitySubId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $GitHubOrg,
    [Parameter(Mandatory)] [string] $GitHubRepo,
    [Parameter(Mandatory)] [string] $EABillingAccount,
    [Parameter(Mandatory)] [string] $EAEnrollmentAcct,
    [Parameter(Mandatory)] [string] $ManagementSubId,
    [Parameter(Mandatory)] [string] $ConnectivitySubId,
    [Parameter(Mandatory)] [string] $IdentitySubId,
    [string] $AppDisplayName = "sp-alz-bicep-deployer"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Prerequisites Check ──────────────────────────────────────
Write-Host "`n[PRE-FLIGHT] Checking prerequisites..." -ForegroundColor Cyan

$prereqs = @{
    'Azure CLI'     = { az --version 2>$null | Select-String 'azure-cli' }
    'Bicep CLI'     = { az bicep version 2>$null }
    'Git'           = { git --version 2>$null }
    'PowerShell 7+' = { $PSVersionTable.PSVersion.Major -ge 7 }
}

$allPassed = $true
foreach ($name in $prereqs.Keys) {
    try {
        $result = & $prereqs[$name]
        if ($result) {
            Write-Host "  ✅ $name : Found" -ForegroundColor Green
        } else {
            Write-Host "  ❌ $name : NOT FOUND" -ForegroundColor Red
            $allPassed = $false
        }
    } catch {
        Write-Host "  ❌ $name : Error checking - $_" -ForegroundColor Red
        $allPassed = $false
    }
}

if (-not $allPassed) {
    throw "One or more prerequisites are missing. Install them before running bootstrap."
}

# ---- Login ----
Write-Host "`n[1/6] Connecting to Azure tenant $TenantId..." -ForegroundColor Cyan
Connect-AzAccount -TenantId $TenantId

# ---- Create App Registration ----
Write-Host "[2/6] Creating App Registration: $AppDisplayName..." -ForegroundColor Cyan
$app = New-AzADApplication -DisplayName $AppDisplayName
$sp  = New-AzADServicePrincipal -ApplicationId $app.AppId

Write-Host "      App Client ID : $($app.AppId)" -ForegroundColor Green
Write-Host "      Object ID     : $($sp.Id)" -ForegroundColor Green

# ---- Federated Credentials (OIDC - no secrets) ----
Write-Host "[3/6] Configuring GitHub OIDC Federated Credentials..." -ForegroundColor Cyan

$federatedCredentials = @(
    @{ name = "github-main";   subject = "repo:${GitHubOrg}/${GitHubRepo}:ref:refs/heads/main" }
    @{ name = "github-pr";     subject = "repo:${GitHubOrg}/${GitHubRepo}:pull_request" }
    @{ name = "github-manual"; subject = "repo:${GitHubOrg}/${GitHubRepo}:environment:platform-production" }
    @{ name = "github-vend";   subject = "repo:${GitHubOrg}/${GitHubRepo}:environment:subscription-vending" }
)

foreach ($fc in $federatedCredentials) {
    New-AzADAppFederatedCredential `
        -ApplicationObjectId $app.Id `
        -Audience "api://AzureADTokenExchange" `
        -Issuer   "https://token.actions.githubusercontent.com" `
        -Name     $fc.name `
        -Subject  $fc.subject | Out-Null
    Write-Host "      Created: $($fc.name)" -ForegroundColor Green
}

# ---- RBAC Assignments ----
Write-Host "[4/6] Assigning RBAC roles..." -ForegroundColor Cyan

# Tenant root management group - Owner (for MG and policy deployments)
$tenantRootMgId = "/providers/Microsoft.Management/managementGroups/$TenantId"
New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Owner" `
    -Scope $tenantRootMgId | Out-Null
Write-Host "      Owner on Tenant Root MG" -ForegroundColor Green

# Management Group Contributor (for subscription placement)
New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Management Group Contributor" `
    -Scope $tenantRootMgId | Out-Null
Write-Host "      Management Group Contributor on Tenant Root MG" -ForegroundColor Green

# Owner on platform subscriptions
foreach ($subId in @($ManagementSubId, $ConnectivitySubId, $IdentitySubId)) {
    New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Owner" `
        -Scope "/subscriptions/$subId" | Out-Null
    Write-Host "      Owner on subscription: $subId" -ForegroundColor Green
}

# EA Enrollment Account role (for subscription creation via vending)
# Note: This must be done via Azure portal or EA billing REST API
Write-Host ""
Write-Host "  [ACTION REQUIRED] Manually assign the service principal as 'Enrollment Account Subscription Creator'" -ForegroundColor Yellow
Write-Host "  in the EA portal: https://ea.azure.com -> Account -> Add service principal" -ForegroundColor Yellow
Write-Host "  SP Object ID: $($sp.Id)" -ForegroundColor Yellow

# ---- Output GitHub Secrets ----
Write-Host "`n[5/6] GitHub Secrets to configure in: https://github.com/$GitHubOrg/$GitHubRepo/settings/secrets/actions" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

$secrets = [ordered]@{
    AZURE_TENANT_ID              = $TenantId
    AZURE_CLIENT_ID              = $app.AppId
    MANAGEMENT_SUBSCRIPTION_ID   = $ManagementSubId
    CONNECTIVITY_SUBSCRIPTION_ID = $ConnectivitySubId
    IDENTITY_SUBSCRIPTION_ID     = $IdentitySubId
    EA_BILLING_ACCOUNT           = $EABillingAccount
    EA_ENROLLMENT_ACCOUNT        = $EAEnrollmentAcct
    CHECKPOINT_ADMIN_PASSWORD    = "<SET_STRONG_PASSWORD>"
    LOG_ANALYTICS_WORKSPACE_ID   = "<SET_AFTER_LOGGING_DEPLOYMENT>"
    HUB_VNET_ID                  = "<SET_AFTER_CONNECTIVITY_DEPLOYMENT>"
    ROUTE_TABLE_ID               = "<SET_AFTER_CONNECTIVITY_DEPLOYMENT>"
}

foreach ($secret in $secrets.GetEnumerator()) {
    Write-Host ("  {0,-40} = {1}" -f $secret.Key, $secret.Value)
}

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

# ---- GitHub Environments ----
Write-Host "`n[6/6] GitHub Environments to create (with required reviewers):" -ForegroundColor Cyan
Write-Host "  platform-production    - for MG, logging, connectivity deployments"
Write-Host "  subscription-vending   - for new subscription provisioning"
Write-Host "  platform-review        - for what-if review (optional)"
Write-Host ""
Write-Host "  Configure at: https://github.com/$GitHubOrg/$GitHubRepo/settings/environments" -ForegroundColor Yellow
Write-Host ""
Write-Host "Bootstrap complete! Next step: run workflow 01-platform-management-groups" -ForegroundColor Green

# ── Bootstrap Summary ────────────────────────────────────────
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "  BOOTSTRAP SUMMARY — Resources Created" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  App Registration" -ForegroundColor White
Write-Host ("    Display Name : {0}" -f $AppDisplayName)
Write-Host ("    Client ID    : {0}" -f $app.AppId)
Write-Host ("    Object ID    : {0}" -f $sp.Id)
Write-Host ""
Write-Host "  Federated Credentials (GitHub OIDC — no client secrets)" -ForegroundColor White
foreach ($fc in $federatedCredentials) {
    Write-Host ("    {0,-20} -> {1}" -f $fc.name, $fc.subject)
}
Write-Host ""
Write-Host "  RBAC Assignments" -ForegroundColor White
Write-Host "    Owner                        on Tenant Root MG"
Write-Host "    Management Group Contributor on Tenant Root MG"
foreach ($subId in @($ManagementSubId, $ConnectivitySubId, $IdentitySubId)) {
    Write-Host ("    Owner                        on /subscriptions/{0}" -f $subId)
}
Write-Host ""
Write-Host "  Next Steps" -ForegroundColor White
Write-Host "    1. Set GitHub secrets listed above in your repository"
Write-Host "    2. Create GitHub Environments: platform-production, subscription-vending"
Write-Host "    3. Manually assign EA Enrollment Account Subscription Creator role"
Write-Host "    4. Run: gh workflow run 01-platform-management-groups.yml --ref main"
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
