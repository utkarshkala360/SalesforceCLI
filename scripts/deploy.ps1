# Guarded deploy of one or more paths inside a single customer folder.
#
# Usage: .\scripts\deploy.ps1 customers\rudra-motors
#        .\scripts\deploy.ps1 customers\rudra-motors\main\default\classes\RM_Foo.cls

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
$org = Confirm-CustomerOrg $customer 'DEPLOY' $Paths

$sfArgs = @('project', 'deploy', 'start', '--target-org', $org)
foreach ($p in $Paths) { $sfArgs += @('--source-dir', $p) }
& sf @sfArgs
exit $LASTEXITCODE
