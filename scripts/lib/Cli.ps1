Set-StrictMode -Version Latest

# Shared by the scripts in scripts/. Not run on its own: each script dot-sources it.

# The one place that runs docker, kind, helm and kubectl. Tests mock this function,
# so they never need Docker or a cluster.
# -InputText is sent on stdin. -Live also shows each output line as it arrives, for the slow steps.
# Returns the exit code and the combined stdout and stderr.
function Invoke-Cli {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('docker', 'kind', 'helm', 'kubectl')] [string] $Name,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $InputText,
        [switch] $Live
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $run = if ($PSBoundParameters.ContainsKey('InputText')) {
        { $InputText | & $Name @Arguments 2>&1 }
    } else {
        { & $Name @Arguments 2>&1 }
    }
    & $run | ForEach-Object {
        $line = "$_"
        $lines.Add($line)
        if ($Live) {
            Write-Information "    $line"
        }
    }
    [pscustomobject] @{
        ExitCode = $LASTEXITCODE
        Output   = ($lines -join [Environment]::NewLine)
    }
}

# True when a program is on PATH.
function Test-ToolInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Name)
    [bool] (Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
}

# The kubectl context kind creates for a cluster. Every kubectl and helm call names it,
# so a script never acts on another cluster that happens to be the current context.
function Get-KubeContext {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ClusterName)
    "kind-$ClusterName"
}
