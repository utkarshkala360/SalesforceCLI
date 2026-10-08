# Switches the project's default org to the org mapped to a customer folder
# (see customers/customers.json). VS Code Explorer menus (Deploy/Retrieve
# This Source) always use this default org, so run this before working on
# a different customer.
#
# Usage: .\scripts\use-customer.ps1 rudra-motors

param(
    [Parameter(Mandatory = $true)][string]$Customer
)

$root = Split-Path -Parent $PSScriptRoot
$map = Get-Content (Join-Path $root 'customers\customers.json') -Raw | ConvertFrom-Json
$org = $map.$Customer
if (-not $org) {
    Write-Error "Unknown customer '$Customer'. Known: $($map.PSObject.Properties.Name -join ', ')"
    exit 1
}

Push-Location $root
try {
    sf config set target-org="$org"
    Write-Host "Default org is now '$org' for customers/$Customer" -ForegroundColor Green
}
finally {
    Pop-Location
}
