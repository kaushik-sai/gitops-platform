<#
.SYNOPSIS
    Creates the local Kubernetes cluster, installs Argo CD and hands the cluster over to Git.

.DESCRIPTION
    One command from a clean machine with Docker running and kind, helm and kubectl on PATH:
      1. Creates the kind cluster from bootstrap/kind-config.yaml, unless it already exists.
      2. Installs or upgrades Argo CD from its pinned Helm chart with bootstrap/argocd-values.yaml.
      3. Applies the root Application. It points Argo CD at clusters/local in the Git repository
         at -Revision; from then on Argo CD deploys everything else from Git.
      4. Waits until every Application is Synced and Healthy (skip with -NoWait).
    Safe to run again: an existing cluster is reused and Argo CD is upgraded in place.
    Every kubectl and helm call names the cluster's context, so other clusters are never touched.

.PARAMETER ClusterName
    Name of the kind cluster. Its kubectl context is kind-<ClusterName>.

.PARAMETER RepoUrl
    Git repository Argo CD deploys from. CI passes the repository under test.

.PARAMETER Revision
    Branch, tag or commit SHA to deploy. CI passes the commit under test.

.PARAMETER TimeoutSeconds
    How long to wait for every Application to be Synced and Healthy.

.PARAMETER NoWait
    Return right after applying the root Application.

.EXAMPLE
    pwsh ./scripts/Start-Platform.ps1

.EXAMPLE
    pwsh ./scripts/Start-Platform.ps1 -Revision feature/my-change
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string] $ClusterName = 'gitops-local',
    [ValidateNotNullOrEmpty()]
    [string] $RepoUrl = 'https://github.com/kaushik-sai/gitops-platform.git',
    [ValidateNotNullOrEmpty()]
    [string] $Revision = 'main',
    [ValidateRange(30, 3600)]
    [int] $TimeoutSeconds = 900,
    [switch] $NoWait
)

Set-StrictMode -Version Latest
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib' -AdditionalChildPath 'Cli.ps1')

$script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
# Pinned chart: argo-cd 10.10.3 installs Argo CD v3.5.5.
$script:ArgoCdChart = 'oci://ghcr.io/argoproj/argo-helm/argo-cd'
$script:ArgoCdChartVersion = '10.10.3'
$script:ArgoCdNamespace = 'argocd'

# Problems that stop the run before it changes anything, one message each.
function Test-Prerequisite {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $missing = @('docker', 'kind', 'helm', 'kubectl' | Where-Object { -not (Test-ToolInstalled -Name $_) })
    foreach ($tool in $missing) {
        "$tool is not on PATH. See Prerequisites in README.md."
    }
    if ($missing -notcontains 'docker') {
        if ((Invoke-Cli -Name docker -Arguments @('info', '--format', '{{.ServerVersion}}')).ExitCode -ne 0) {
            'Docker is not running. Start Docker Desktop (Linux containers) and run this again.'
        }
    }
}

function Test-KindCluster {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $ClusterName)
    $result = Invoke-Cli -Name kind -Arguments @('get', 'clusters')
    if ($result.ExitCode -ne 0) {
        throw "kind get clusters failed: $($result.Output)"
    }
    # With no clusters, kind prints a message instead of names; it never equals a name.
    @($result.Output -split '\r?\n' | ForEach-Object { $_.Trim() }) -contains $ClusterName
}

# Creates the cluster, or reuses it when it already exists.
function Initialize-Cluster {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ClusterName)
    if (Test-KindCluster -ClusterName $ClusterName) {
        Write-Information "Cluster '$ClusterName' already exists; reusing it."
        return
    }
    Write-Information "Creating kind cluster '$ClusterName' (the first run pulls the node image)..."
    $config = Join-Path -Path $script:RepoRoot -ChildPath 'bootstrap' -AdditionalChildPath 'kind-config.yaml'
    $result = Invoke-Cli -Name kind -Arguments @('create', 'cluster', '--name', $ClusterName, '--config', $config, '--wait', '120s') -Live
    if ($result.ExitCode -ne 0) {
        throw "kind create cluster failed (exit $($result.ExitCode))."
    }
}

# Installs Argo CD, or upgrades it in place to the pinned chart and values.
function Install-ArgoCd {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Context)
    $values = Join-Path -Path $script:RepoRoot -ChildPath 'bootstrap' -AdditionalChildPath 'argocd-values.yaml'
    Write-Information "Installing Argo CD (chart argo-cd $script:ArgoCdChartVersion)..."
    $arguments = @('upgrade', '--install', 'argocd', $script:ArgoCdChart, '--version', $script:ArgoCdChartVersion,
        '--namespace', $script:ArgoCdNamespace, '--create-namespace', '--values', $values,
        '--kube-context', $Context, '--wait', '--timeout', '10m')
    $result = Invoke-Cli -Name helm -Arguments $arguments -Live
    if ($result.ExitCode -ne 0) {
        throw "helm upgrade --install argocd failed (exit $($result.ExitCode))."
    }
}

# The root Application, as data. It deploys the chart in clusters/local, which creates one
# Application per environment, all at the same repository and revision.
function Build-RootApplication {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [string] $RepoUrl,
        [Parameter(Mandatory)] [string] $Revision
    )
    [ordered] @{
        apiVersion = 'argoproj.io/v1alpha1'
        kind       = 'Application'
        metadata   = [ordered] @{ name = 'root'; namespace = $script:ArgoCdNamespace }
        spec       = [ordered] @{
            project     = 'default'
            source      = [ordered] @{
                repoURL        = $RepoUrl
                targetRevision = $Revision
                path           = 'clusters/local'
                # The chart passes these on to every child Application.
                helm           = [ordered] @{
                    valuesObject = [ordered] @{ repoURL = $RepoUrl; targetRevision = $Revision }
                }
            }
            destination = [ordered] @{ server = 'https://kubernetes.default.svc'; namespace = $script:ArgoCdNamespace }
            syncPolicy  = [ordered] @{ automated = [ordered] @{ prune = $true; selfHeal = $true } }
        }
    }
}

function Install-RootApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Context,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Application
    )
    # JSON is valid YAML, so kubectl applies it from stdin as it is.
    $json = $Application | ConvertTo-Json -Depth 20
    $result = Invoke-Cli -Name kubectl -Arguments @('--context', $Context, 'apply', '--filename', '-') -InputText $json
    if ($result.ExitCode -ne 0) {
        throw "kubectl apply of the root Application failed: $($result.Output)"
    }
    Write-Information $result.Output
}

# Value at a property path, or $null when any part is missing (a new Application has no status yet).
function Get-NestedValue {
    [CmdletBinding()]
    param(
        [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory)] [string[]] $Path
    )
    $value = $InputObject
    foreach ($name in $Path) {
        if ($null -eq $value) { return $null }
        $property = $value.PSObject.Properties[$name]
        if (-not $property) { return $null }
        $value = $property.Value
    }
    $value
}

# One row per Application from `kubectl get applications --output json`.
function ConvertFrom-ApplicationList {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $Json)
    $list = $Json | ConvertFrom-Json
    foreach ($item in @(Get-NestedValue -InputObject $list -Path 'items')) {
        if ($null -eq $item) { continue }
        $sync = Get-NestedValue -InputObject $item -Path 'status', 'sync', 'status'
        $health = Get-NestedValue -InputObject $item -Path 'status', 'health', 'status'
        # Sync and health describe the source in comparedTo. Right after the spec changes they
        # still describe the old source, until Argo CD has fetched and compared the new one.
        [pscustomobject] @{
            Name            = $item.metadata.name
            Sync            = if ($sync) { $sync } else { 'Unknown' }
            Health          = if ($health) { $health } else { 'Unknown' }
            RepoUrl         = Get-NestedValue -InputObject $item -Path 'spec', 'source', 'repoURL'
            Revision        = Get-NestedValue -InputObject $item -Path 'spec', 'source', 'targetRevision'
            ComparedRepoUrl = Get-NestedValue -InputObject $item -Path 'status', 'sync', 'comparedTo', 'source', 'repoURL'
            ComparedTo      = Get-NestedValue -InputObject $item -Path 'status', 'sync', 'comparedTo', 'source', 'targetRevision'
        }
    }
}

# Ready when there is more than the root (its children exist) and every Application is Synced and Healthy.
# With -RepoUrl and -Revision, every Application must also point at them and have been compared
# against them: on a re-run, the old status says Synced and Healthy for the previous revision.
function Test-PlatformReady {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Status,
        [string] $RepoUrl,
        [string] $Revision
    )
    if ($Status.Count -lt 2) {
        return $false
    }
    if ($Status | Where-Object { $_.Sync -ne 'Synced' -or $_.Health -ne 'Healthy' }) {
        return $false
    }
    if ($RepoUrl -and ($Status | Where-Object { $_.RepoUrl -ne $RepoUrl -or $_.ComparedRepoUrl -ne $RepoUrl })) {
        return $false
    }
    if ($Revision -and ($Status | Where-Object { $_.Revision -ne $Revision -or $_.ComparedTo -ne $Revision })) {
        return $false
    }
    $true
}

function Format-ApplicationStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Status)
    if ($Status.Count -eq 0) {
        return '(no Applications yet)'
    }
    ($Status | Sort-Object Name | Format-Table Name, Sync, Health, ComparedTo -AutoSize | Out-String).Trim()
}

# Polls the Applications until all are Synced and Healthy (at -RepoUrl and -Revision when given).
# Prints the table when it changes. Throws with the last table when the time is up.
function Wait-PlatformReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Context,
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [ValidateRange(1, 300)] [int] $IntervalSeconds = 10,
        [string] $RepoUrl,
        [string] $Revision
    )
    Write-Information "Waiting up to $TimeoutSeconds s for every Application to be Synced and Healthy..."
    $attempts = [math]::Max(1, [math]::Ceiling($TimeoutSeconds / $IntervalSeconds))
    # The attempts cap the polls; the clock stops them too, because each kubectl call takes time.
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $table = ''
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $result = Invoke-Cli -Name kubectl -Arguments @('--context', $Context, 'get', 'applications.argoproj.io',
            '--namespace', $script:ArgoCdNamespace, '--output', 'json')
        $status = @(if ($result.ExitCode -eq 0) { ConvertFrom-ApplicationList -Json $result.Output })
        $current = Format-ApplicationStatus -Status $status
        if ($current -ne $table) {
            Write-Information $current
            $table = $current
        }
        if (Test-PlatformReady -Status $status -RepoUrl $RepoUrl -Revision $Revision) {
            return $status
        }
        if ($attempt -ge $attempts -or $clock.Elapsed.TotalSeconds + $IntervalSeconds -gt $TimeoutSeconds) {
            break
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    throw "Timed out after $TimeoutSeconds s waiting for every Application to be Synced and Healthy:$([Environment]::NewLine)$table"
}

# How to reach the UIs once the platform is up.
function Get-AccessHint {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Context)
    @(
        ''
        'To open the UIs (each command runs until you press Ctrl+C):'
        "  Argo CD (read-only, no login): kubectl --context $Context -n argocd port-forward svc/argocd-server 8080:80        -> http://127.0.0.1:8080"
        "  Boutique dev:                  kubectl --context $Context -n boutique-dev port-forward svc/frontend 8081:80   -> http://127.0.0.1:8081"
        "  Boutique prod:                 kubectl --context $Context -n boutique-prod port-forward svc/frontend 8082:80  -> http://127.0.0.1:8082"
    ) -join [Environment]::NewLine
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'

    $problems = @(Test-Prerequisite)
    if ($problems.Count -gt 0) {
        $problems | ForEach-Object { Write-Error $_ -ErrorAction Continue }
        exit 1
    }

    $context = Get-KubeContext -ClusterName $ClusterName
    try {
        Initialize-Cluster -ClusterName $ClusterName
        Install-ArgoCd -Context $context
        Write-Information "Handing the cluster to Git: $RepoUrl at '$Revision'"
        Install-RootApplication -Context $context -Application (Build-RootApplication -RepoUrl $RepoUrl -Revision $Revision)
        if (-not $NoWait) {
            Wait-PlatformReady -Context $context -TimeoutSeconds $TimeoutSeconds -RepoUrl $RepoUrl -Revision $Revision | Out-Null
        }
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
    Write-Information $(if ($NoWait) { 'Not waiting (-NoWait): Argo CD keeps syncing in the background.' } else { 'Platform is up: every Application is Synced and Healthy.' })
    Write-Information (Get-AccessHint -Context $context)
    exit 0
}
