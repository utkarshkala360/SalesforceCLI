# Shared guard for the deploy/retrieve scripts (dot-source this file).
# Same rules as the Org Guard VS Code extension (tools/org-guard):
#   - paths must be inside one customers/<name>/ folder
#   - the default org (.sf/config.json) must be the org mapped to <name>
#   - even when it matches, the user must confirm explicitly

$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Get-CustomerMap {
    Get-Content (Join-Path $ProjectRoot 'customers\customers.json') -Raw | ConvertFrom-Json
}

function Get-DefaultOrg {
    $cfg = Join-Path $ProjectRoot '.sf\config.json'
    if (Test-Path $cfg) { (Get-Content $cfg -Raw | ConvertFrom-Json).'target-org' }
}

function Resolve-Username([string]$OrgOrAlias) {
    $aliases = (sf alias list --json | ConvertFrom-Json).result
    $hit = $aliases | Where-Object { $_.alias -eq $OrgOrAlias } | Select-Object -First 1
    if ($hit) { $hit.value } else { $OrgOrAlias }
}

# Returns the customer folder name every path belongs to, or stops with an error.
function Get-CustomerForPaths([string[]]$Paths) {
    $customers = @()
    foreach ($p in $Paths) {
        $full = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $p))
        $rel = $full.Substring($ProjectRoot.Length).TrimStart('\', '/') -split '[\\/]'
        if ($rel.Count -lt 2 -or $rel[0] -ne 'customers' -or $rel[1] -eq 'customers.json') {
            throw "BLOCKED: '$p' is not inside a customers/<name>/ folder."
        }
        $customers += $rel[1]
    }
    $unique = $customers | Select-Object -Unique
    if (@($unique).Count -gt 1) {
        throw "BLOCKED: selection spans several customers ($($unique -join ', ')). Use one customer at a time."
    }
    return @($unique)[0]
}

# Stops on mismatch; asks for explicit confirmation on match. Returns the org alias to use.
function Confirm-CustomerOrg([string]$Customer, [string]$Verb, [string[]]$Paths) {
    $expected = (Get-CustomerMap).$Customer
    if (-not $expected) { throw "BLOCKED: customers/$Customer has no org mapping in customers/customers.json." }

    $current = Get-DefaultOrg
    if (-not $current -or (Resolve-Username $current) -ne (Resolve-Username $expected)) {
        Write-Host ''
        Write-Host 'BLOCKED - ORG MISMATCH' -ForegroundColor White -BackgroundColor Red
        Write-Host "  Folder:              customers/$Customer"
        Write-Host "  Belongs to:          $expected"
        Write-Host "  Current default org: $(if ($current) { $current } else { '(none)' })"
        Write-Host "  Fix: .\scripts\use-customer.ps1 $Customer" -ForegroundColor Yellow
        exit 1
    }

    Write-Host ''
    if ($expected -match 'prod') {
        Write-Host ' PRODUCTION ORG ' -ForegroundColor White -BackgroundColor Red
    }
    Write-Host "$Verb  ->  $expected ($(Resolve-Username $expected))" -ForegroundColor Yellow
    Write-Host "Customer folder: customers/$Customer"
    $Paths | ForEach-Object { Write-Host "  $_" }
    $answer = Read-Host "Type 'yes' to $($Verb.ToLower())"
    if ($answer -ne 'yes') {
        Write-Host 'Cancelled.'
        exit 1
    }
    return $expected
}
