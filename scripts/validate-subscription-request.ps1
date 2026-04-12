#Requires -Version 7.0
<#
.SYNOPSIS
    Validates a subscription vending .bicepparam file before deployment.
    Checks: naming convention, IP overlap, mandatory tags, MG placement.

.OUTPUTS
    Writes validation results to stdout.
    Exits 1 if any VALIDATION FAILED check fails (blocks the pipeline).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]  $ParamFile,
    [string] $HubCIDR            = '10.0.0.0/16',
    [string] $IdentityCIDR       = '10.10.0.0/16',
    [int]    $CorpRangeStart      = 100,
    [int]    $CorpRangeEnd        = 199,
    [int]    $OnlineRangeStart    = 200,
    [int]    $OnlineRangeEnd      = 254
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$passes   = [System.Collections.Generic.List[string]]::new()

function Pass   { param($msg) $passes.Add("  ✅ PASS   : $msg") }
function Fail   { param($msg) $failures.Add("  ❌ FAIL   : $msg") }
function Warn   { param($msg) $warnings.Add("  ⚠️  WARN   : $msg") }

# ── Helper: parse param value from bicepparam file ─────────────
function Get-ParamValue {
    param([string[]] $Lines, [string] $ParamName)
    $line = $Lines | Where-Object { $_ -match "^\s*param\s+$ParamName\s*=" }
    if (-not $line) { return $null }
    return ($line -replace "^\s*param\s+$ParamName\s*=\s*'?", '') -replace "'.*$", ''
}

# ── Helper: CIDR to numeric range ─────────────────────────────
function Get-CIDRRange {
    param([string] $CIDR)
    $parts    = $CIDR -split '/'
    $ip       = $parts[0]
    $prefix   = [int]$parts[1]
    $ipBytes  = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    [Array]::Reverse($ipBytes)
    $ipInt    = [System.BitConverter]::ToUInt32($ipBytes, 0)
    $mask     = if ($prefix -eq 0) { 0 } else { [uint32](0xFFFFFFFF -shl (32 - $prefix)) }
    $network  = $ipInt -band $mask
    $broadcast = $network -bor (-bnot $mask -band 0xFFFFFFFF)
    return [pscustomobject]@{ Start = $network; End = $broadcast }
}

function Test-CIDROverlap {
    param([string] $CIDR1, [string] $CIDR2)
    $r1 = Get-CIDRRange $CIDR1
    $r2 = Get-CIDRRange $CIDR2
    return ($r1.Start -le $r2.End) -and ($r2.Start -le $r1.End)
}

# ── Read file ──────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════"
Write-Host "  HSS Azure LZ — Subscription Vending Validation"
Write-Host "  File: $ParamFile"
Write-Host "═══════════════════════════════════════════════════════════"
Write-Host ""

if (-not (Test-Path $ParamFile)) { Fail "Parameter file not found: $ParamFile"; }
else {
    $lines = Get-Content $ParamFile
    Pass "Parameter file exists"

    # ── 1. Naming convention ────────────────────────────────────
    Write-Host "── [1] Naming Convention ──────────────────────────────────"
    $alias = Get-ParamValue $lines 'subscriptionAlias'
    if (-not $alias) {
        Fail "subscriptionAlias not found in param file"
    } elseif ($alias -cmatch '^sub-[a-z0-9]+(-[a-z0-9]+)*$') {
        Pass "subscriptionAlias '$alias' matches convention: sub-<app>-<env>"
    } else {
        Fail "subscriptionAlias '$alias' does NOT match convention. Expected: sub-<appname>-<env> (lowercase, hyphens)"
    }

    $displayName = Get-ParamValue $lines 'subscriptionDisplayName'
    if ($displayName) { Pass "subscriptionDisplayName is set: '$displayName'" }
    else              { Fail "subscriptionDisplayName is not set" }

    # ── 2. Management Group ────────────────────────────────────
    Write-Host ""
    Write-Host "── [2] Management Group Placement ─────────────────────────"
    $targetMg = Get-ParamValue $lines 'targetManagementGroupId'
    $validMgs = @('alz-landingzones-corp','alz-landingzones-online','alz-sandbox')
    if ($targetMg -in $validMgs) {
        Pass "targetManagementGroupId '$targetMg' is valid"
    } elseif ($targetMg) {
        Fail "targetManagementGroupId '$targetMg' is not a recognised MG. Valid: $($validMgs -join ', ')"
    } else {
        Fail "targetManagementGroupId is not set"
    }

    # ── 3. Networking / IP Overlap ─────────────────────────────
    Write-Host ""
    Write-Host "── [3] Network — IP Overlap Check ─────────────────────────"
    $spokeCIDR = Get-ParamValue $lines 'spokeVnetAddressPrefix'
    if (-not $spokeCIDR) {
        Fail "spokeVnetAddressPrefix is not set"
    } else {
        $spokeCIDR = $spokeCIDR.Trim()

        # Validate it's a /16
        if ($spokeCIDR -match '^\d+\.\d+\.\d+\.\d+/(\d+)$') {
            $prefixLen = [int]$Matches[1]
            if ($prefixLen -eq 16) { Pass "Spoke CIDR prefix length is /16" }
            else                   { Warn  "Spoke CIDR is /$prefixLen — recommended is /16" }
        } else {
            Fail "spokeCIDR '$spokeCIDR' is not a valid CIDR"
        }

        # Check overlap with reserved ranges
        foreach ($reserved in @($HubCIDR, $IdentityCIDR)) {
            if (Test-CIDROverlap $spokeCIDR $reserved) {
                Fail "Spoke CIDR $spokeCIDR OVERLAPS reserved range $reserved"
            } else {
                Pass "Spoke CIDR $spokeCIDR does not overlap $reserved"
            }
        }

        # Validate range alignment with target MG
        if ($spokeCIDR -match '^10\.(\d+)\.') {
            $secondOctet = [int]$Matches[1]
            if ($targetMg -eq 'alz-landingzones-corp') {
                if ($secondOctet -ge $CorpRangeStart -and $secondOctet -le $CorpRangeEnd) {
                    Pass "Corp spoke CIDR $spokeCIDR is in corp range (10.$CorpRangeStart-$CorpRangeEnd.x.x)"
                } else {
                    Warn "Corp spoke CIDR $spokeCIDR second octet ($secondOctet) is outside recommended corp range ($CorpRangeStart-$CorpRangeEnd)"
                }
            } elseif ($targetMg -eq 'alz-landingzones-online') {
                if ($secondOctet -ge $OnlineRangeStart -and $secondOctet -le $OnlineRangeEnd) {
                    Pass "Online spoke CIDR $spokeCIDR is in online range (10.$OnlineRangeStart-$OnlineRangeEnd.x.x)"
                } else {
                    Warn "Online spoke CIDR $spokeCIDR second octet ($secondOctet) is outside recommended online range ($OnlineRangeStart-$OnlineRangeEnd)"
                }
            }
        }
    }

    # ── 4. Mandatory Tags ──────────────────────────────────────
    Write-Host ""
    Write-Host "── [4] Mandatory Tags ──────────────────────────────────────"
    $tagsBlock = ($lines | Select-String -Pattern 'param tags' -Context 0,20).Context.PostContext -join "`n"
    foreach ($tag in @('environment','ownerEmail','dataClassification','costCenter','managedBy')) {
        if ($tagsBlock -match $tag -or ($lines -join "`n") -match $tag) {
            Pass "Tag '$tag' is referenced"
        } else {
            Warn "Tag '$tag' not found — ensure it is set in the tags parameter"
        }
    }

    # ── 5. Owner fields ────────────────────────────────────────
    Write-Host ""
    Write-Host "── [5] Ownership ───────────────────────────────────────────"
    $ownerEmail = Get-ParamValue $lines 'ownerEmail'
    if ($ownerEmail -and $ownerEmail -match '@') {
        Pass "ownerEmail is set: $ownerEmail"
    } else {
        Fail "ownerEmail is not set or invalid"
    }

    $ownerObjId = Get-ParamValue $lines 'ownerGroupObjectId'
    if ($ownerObjId -and $ownerObjId -match '^[0-9a-f\-]{36}$') {
        Pass "ownerGroupObjectId looks like a valid GUID"
    } elseif ($ownerObjId -match '<') {
        Fail "ownerGroupObjectId still contains placeholder value: $ownerObjId"
    } else {
        Warn "ownerGroupObjectId '$ownerObjId' — verify this is a valid AAD group GUID"
    }

    # ── 6. EA Billing placeholders ────────────────────────────
    Write-Host ""
    Write-Host "── [6] EA Billing ──────────────────────────────────────────"
    $billingAccount = Get-ParamValue $lines 'eaBillingAccountName'
    if ($billingAccount -match '<') {
        Warn "eaBillingAccountName still contains placeholder — ensure it is overridden by pipeline secrets"
    } else {
        Pass "eaBillingAccountName is set (will be overridden by pipeline secret)"
    }

    # ── 7. Budget ─────────────────────────────────────────────
    Write-Host ""
    Write-Host "── [7] Budget Alert ────────────────────────────────────────"
    $budget = Get-ParamValue $lines 'budgetAmountAUD'
    if ($budget -and [int]$budget -gt 0) {
        Pass "budgetAmountAUD is set: AUD $budget/month"
    } else {
        Warn "budgetAmountAUD not set — defaulting to AUD 5,000/month. Update if higher spend expected."
    }
}

# ── Summary ────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════"
Write-Host "  RESULTS"
Write-Host "═══════════════════════════════════════════════════════════"
$passes   | ForEach-Object { Write-Host $_ -ForegroundColor Green }
$warnings | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
$failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
Write-Host ""
Write-Host "  Passed  : $($passes.Count)"
Write-Host "  Warnings: $($warnings.Count)"
Write-Host "  Failed  : $($failures.Count)"
Write-Host "═══════════════════════════════════════════════════════════"

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "VALIDATION FAILED — fix the errors above before this PR can proceed." -ForegroundColor Red
    exit 1
} else {
    Write-Host ""
    Write-Host "Validation passed — ready for human review." -ForegroundColor Green
    exit 0
}
