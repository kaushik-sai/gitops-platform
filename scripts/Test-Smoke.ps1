<#
.SYNOPSIS
    Smoke-tests Online Boutique in one environment through a kubectl port-forward.

.DESCRIPTION
    Forwards a local port to the frontend Service, waits for /_healthz, then checks pages that
    need the other services to answer:
      /_healthz              frontend is up
      /                      home page (product catalog, currency, ads)
      /product/OLJCESPC7Z    product page (catalog, currency, recommendations, ads)
      /cart                  cart (cart service and Redis, plus shipping, currency, recommendations)
    Prints PASS or FAIL per check. Exits 1 if any check fails. Always stops the port-forward.

.PARAMETER Environment
    dev or prod: tests the namespace boutique-<Environment>.

.PARAMETER ClusterName
    Name of the kind cluster.

.PARAMETER LocalPort
    Local port for the port-forward.

.PARAMETER TimeoutSeconds
    How long to wait for the frontend to answer /_healthz.

.EXAMPLE
    pwsh ./scripts/Test-Smoke.ps1 -Environment prod
#>
[CmdletBinding()]
param(
    [ValidateSet('dev', 'prod')]
    [string] $Environment = 'dev',
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string] $ClusterName = 'gitops-local',
    [ValidateRange(1024, 65535)]
    [int] $LocalPort = 18080,
    [ValidateRange(5, 600)]
    [int] $TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib' -AdditionalChildPath 'Cli.ps1')

# The checks, in order: path, and text the page must contain.
function Get-SmokeCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject] @{ Path = '/_healthz'; Expect = 'ok' }
    [pscustomobject] @{ Path = '/'; Expect = 'Online Boutique' }
    [pscustomobject] @{ Path = '/product/OLJCESPC7Z'; Expect = 'Sunglasses' }
    [pscustomobject] @{ Path = '/cart'; Expect = 'Shopping Cart' }
}

# Starts kubectl port-forward in the background and returns its process.
function Open-PortForward {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [Parameter(Mandatory)] [string] $Context,
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [int] $LocalPort
    )
    $log = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "port-forward-$Namespace"
    Start-Process -FilePath 'kubectl' -PassThru -NoNewWindow `
        -ArgumentList @('--context', $Context, '--namespace', $Namespace, 'port-forward', 'svc/frontend', "$($LocalPort):80") `
        -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
}

function Close-PortForward {
    [CmdletBinding()]
    param([AllowNull()] [System.Diagnostics.Process] $Process)
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

# One HTTP GET. Returns the status code and body, or $null when nothing answers yet.
function Invoke-Probe {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $Uri)
    try {
        $response = Invoke-WebRequest -Uri $Uri -TimeoutSec 10 -SkipHttpErrorCheck -ErrorAction Stop
        [pscustomobject] @{ StatusCode = [int] $response.StatusCode; Content = [string] $response.Content }
    } catch {
        $null
    }
}

# Waits until the frontend answers through the port-forward. Returns $true or $false.
function Wait-Frontend {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [ValidateRange(1, 60)] [int] $IntervalSeconds = 2
    )
    $attempts = [math]::Max(1, [math]::Ceiling($TimeoutSeconds / $IntervalSeconds))
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $probe = Invoke-Probe -Uri "$BaseUrl/_healthz"
        if ($probe -and $probe.StatusCode -eq 200) {
            return $true
        }
        if ($attempt -lt $attempts) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    $false
}

# Runs every check once. Returns one result per check: Path, Ok, Detail.
function Invoke-SmokeCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $BaseUrl)
    foreach ($check in Get-SmokeCheck) {
        $probe = Invoke-Probe -Uri "$BaseUrl$($check.Path)"
        $detail = if (-not $probe) {
            'no response'
        } elseif ($probe.StatusCode -ne 200) {
            "HTTP $($probe.StatusCode)"
        } elseif ($probe.Content -notmatch [regex]::Escape($check.Expect)) {
            "HTTP 200 but no '$($check.Expect)' on the page"
        } else {
            "HTTP 200, found '$($check.Expect)'"
        }
        [pscustomobject] @{
            Path   = $check.Path
            Ok     = [bool] ($probe -and $probe.StatusCode -eq 200 -and $probe.Content -match [regex]::Escape($check.Expect))
            Detail = $detail
        }
    }
}

# Opens the port-forward, runs the checks and always closes it. Returns the results;
# throws when the frontend never answers.
function Test-Environment {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Context,
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [int] $LocalPort,
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )
    $baseUrl = "http://127.0.0.1:$LocalPort"
    $process = $null
    try {
        $process = Open-PortForward -Context $Context -Namespace $Namespace -LocalPort $LocalPort
        if (-not (Wait-Frontend -BaseUrl $baseUrl -TimeoutSeconds $TimeoutSeconds)) {
            throw "The frontend in $Namespace did not answer /_healthz within $TimeoutSeconds s."
        }
        Invoke-SmokeCheck -BaseUrl $baseUrl
    } finally {
        Close-PortForward -Process $process
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'
    $namespace = "boutique-$Environment"
    try {
        $results = @(Test-Environment -Context (Get-KubeContext -ClusterName $ClusterName) -Namespace $namespace `
                -LocalPort $LocalPort -TimeoutSeconds $TimeoutSeconds)
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
    foreach ($r in $results) {
        $state = if ($r.Ok) { 'PASS' } else { 'FAIL' }
        Write-Information "$state $namespace $($r.Path): $($r.Detail)"
    }
    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        Write-Error "$($failed.Count) of $($results.Count) smoke check(s) failed in $namespace." -ErrorAction Continue
        exit 1
    }
    Write-Information "All $($results.Count) smoke checks passed in $namespace."
    exit 0
}
