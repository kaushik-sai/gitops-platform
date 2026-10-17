<#
.SYNOPSIS
    Deletes the local kind cluster and everything in it.

.DESCRIPTION
    Nothing lives outside the cluster: Git holds the configuration, so Start-Platform.ps1
    rebuilds the same platform from scratch. Safe to run when the cluster does not exist.

.PARAMETER ClusterName
    Name of the kind cluster to delete.

.EXAMPLE
    pwsh ./scripts/Stop-Platform.ps1

.EXAMPLE
    pwsh ./scripts/Stop-Platform.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string] $ClusterName = 'gitops-local'
)

Set-StrictMode -Version Latest
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib' -AdditionalChildPath 'Cli.ps1')

# Returns 'Deleted', 'NotFound', or 'Skipped' when -WhatIf or -Confirm declined it. Throws when kind fails.
function Remove-KindCluster {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ClusterName)
    $clusters = Invoke-Cli -Name kind -Arguments @('get', 'clusters')
    if ($clusters.ExitCode -ne 0) {
        throw "kind get clusters failed: $($clusters.Output)"
    }
    if (@($clusters.Output -split '\r?\n' | ForEach-Object { $_.Trim() }) -notcontains $ClusterName) {
        return 'NotFound'
    }
    if (-not $PSCmdlet.ShouldProcess($ClusterName, 'Delete kind cluster')) {
        return 'Skipped'
    }
    $result = Invoke-Cli -Name kind -Arguments @('delete', 'cluster', '--name', $ClusterName) -Live
    if ($result.ExitCode -ne 0) {
        throw "kind delete cluster failed (exit $($result.ExitCode))."
    }
    'Deleted'
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'
    if (-not (Test-ToolInstalled -Name 'kind')) {
        Write-Error 'kind is not on PATH.' -ErrorAction Continue
        exit 1
    }
    try {
        $outcome = Remove-KindCluster -ClusterName $ClusterName
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
    switch ($outcome) {
        'Deleted' { Write-Information "Cluster '$ClusterName' deleted." }
        'Skipped' { Write-Information "Cluster '$ClusterName' not deleted." }
        default { Write-Information "No cluster named '$ClusterName'; nothing to delete." }
    }
    exit 0
}
