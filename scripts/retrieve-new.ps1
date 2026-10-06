# Retrieves components that do not exist locally yet straight into a customer
# folder. A normal retrieve puts new components in the default package
# directory (force-app), so this retrieves into a temp folder inside the
# project (the CLI requires that) and copies the result into customers/<Customer>.
#
# Usage: .\scripts\retrieve-new.ps1 rudra-motors "ApexClass:RM_Foo" "LightningComponentBundle:rmBar"
#        .\scripts\retrieve-new.ps1 rudra-motors -Manifest manifest\package.xml

param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Customer,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Metadata,
    [string]$Manifest
)

. (Join-Path $PSScriptRoot 'org-guard.ps1')

if (-not (Get-CustomerMap).$Customer) {
    Write-Host "Unknown customer '$Customer'. Known: $((Get-CustomerMap).PSObject.Properties.Name -join ', ')" -ForegroundColor Red
    exit 1
}
if (-not $Metadata -and -not $Manifest) {
    Write-Host 'Pass metadata names (e.g. "ApexClass:Foo") or -Manifest <path>.' -ForegroundColor Red
    exit 1
}

$what = if ($Manifest) { @("manifest: $Manifest") } else { $Metadata }
$org = Confirm-CustomerOrg $Customer 'RETRIEVE' $what

# --output-dir writes <dir>/classes/... (no main/default level), so copy into main/default.
$target = Join-Path $ProjectRoot "customers\$Customer\main\default"
# Not dot-prefixed: the CLI silently ignores files under hidden folders.
$tmpRel = "retrieve-tmp\" + [guid]::NewGuid()
$tmp = Join-Path $ProjectRoot $tmpRel

$sfArgs = @('project', 'retrieve', 'start', '--target-org', $org, '--output-dir', $tmpRel)
if ($Manifest) { $sfArgs += @('--manifest', $Manifest) }
foreach ($m in $Metadata) { $sfArgs += @('--metadata', $m) }

Push-Location $ProjectRoot
try {
    & sf @sfArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (Test-Path $tmp) {
        Copy-Item -Path (Join-Path $tmp '*') -Destination $target -Recurse -Force
        Write-Host "Copied retrieved source into customers/$Customer from '$org'" -ForegroundColor Green
    }
}
finally {
    Pop-Location
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    $tmpRoot = Split-Path -Parent $tmp
    if ((Test-Path $tmpRoot) -and -not (Get-ChildItem $tmpRoot)) { Remove-Item $tmpRoot }
}
