# Guarded retrieve of components that already exist locally in a customer folder
# (files are overwritten in place). For components not yet in the project, use
# retrieve-new.ps1.
#
# Usage: .\scripts\retrieve.ps1 customers\rudra-motors

param(
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$Paths
)

. (Join-Path $PSScriptRoot 'org-guard.ps1')

try {
    $customer = Get-CustomerForPaths $Paths
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
$org = Confirm-CustomerOrg $customer 'RETRIEVE' $Paths

$sfArgs = @('project', 'retrieve', 'start', '--target-org', $org)
foreach ($p in $Paths) { $sfArgs += @('--source-dir', $p) }
& sf @sfArgs
exit $LASTEXITCODE
