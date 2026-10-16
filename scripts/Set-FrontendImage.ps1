<#
.SYNOPSIS
    Sets, copies or shows the frontend image of one environment's overlay.

.DESCRIPTION
    The frontend image of each environment is one entry in the `images:` list of
    apps/boutique/overlays/<environment>/kustomization.yaml, the entry whose name is the
    upstream frontend image. This script rewrites only that entry's fields, to a repository
    and a digest, so a release or a promotion is a one-entry diff:
      -Image             sets the given image reference (the release workflow, for dev)
      -FromEnvironment   copies another environment's image (the promote workflow, dev to prod)
      -Show              prints the current image reference and changes nothing
    References must be pinned by digest: repository@sha256:<64 hex>.

.PARAMETER Environment
    dev or prod: the overlay to change or show.

.PARAMETER Image
    The new image, as repository@sha256:<digest>.

.PARAMETER FromEnvironment
    The environment whose frontend image is copied.

.PARAMETER Show
    Print the environment's current frontend image reference.

.PARAMETER RepoRoot
    Root of this repository. Tests point it at a temporary copy.

.EXAMPLE
    pwsh ./scripts/Set-FrontendImage.ps1 -Environment dev -Image ghcr.io/kaushik-sai/gitops-platform/frontend@sha256:<digest>

.EXAMPLE
    pwsh ./scripts/Set-FrontendImage.ps1 -Environment prod -FromEnvironment dev
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Show')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'prod')]
    [string] $Environment,
    [Parameter(Mandatory, ParameterSetName = 'Set')]
    [string] $Image,
    [Parameter(Mandatory, ParameterSetName = 'Copy')]
    [ValidateSet('dev', 'prod')]
    [string] $FromEnvironment,
    [Parameter(ParameterSetName = 'Show')]
    [switch] $Show,
    [string] $RepoRoot = (Join-Path -Path $PSScriptRoot -ChildPath '..')
)

Set-StrictMode -Version Latest

# The image name in the vendored upstream manifest. Kustomize matches the entry by this name.
$script:FrontendUpstreamImage = 'us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/frontend'

function Get-OverlayFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Environment
    )
    Join-Path -Path $RepoRoot -ChildPath 'apps' -AdditionalChildPath 'boutique', 'overlays', $Environment, 'kustomization.yaml'
}

# Splits repository@sha256:<digest>. Throws unless the reference is pinned by digest.
function Split-ImageReference {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $Reference)
    if ($Reference -notmatch '^(?<repo>[a-z0-9]+(?:[._-][a-z0-9]+)*(?:\.[a-z0-9-]+)*(?::[0-9]+)?(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+)@(?<digest>sha256:[0-9a-f]{64})$') {
        throw "Not an image reference pinned by digest (repository@sha256:<64 hex>): '$Reference'."
    }
    [pscustomobject] @{ Repository = $Matches.repo; Digest = $Matches.digest }
}

# Finds the frontend entry in a kustomization's lines. Returns the index of its '- name:' line,
# the indices of its field lines and the indentation of those fields. Throws unless there is
# exactly one such entry.
function Find-FrontendEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines)
    $pattern = '^(?<indent>\s*)- name:\s*' + [regex]::Escape($script:FrontendUpstreamImage) + '\s*$'
    $starts = @(for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match $pattern) { $i } })
    if ($starts.Count -ne 1) {
        throw "Expected one images entry named $($script:FrontendUpstreamImage), found $($starts.Count)."
    }
    $start = $starts[0]
    $null = $Lines[$start] -match $pattern
    # The fields line up under 'name', two columns right of the dash.
    $fieldIndent = $Matches.indent + '  '
    $fields = @(for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -notmatch ('^' + [regex]::Escape($fieldIndent) + '[A-Za-z]')) { break }
            $i
        })
    [pscustomobject] @{ Start = $start; Fields = $fields; FieldIndent = $fieldIndent }
}

# Reads the frontend entry. Returns NewName, NewTag and Digest (each $null when absent) and
# Reference: repository@digest when pinned, otherwise $null.
function Get-FrontendImage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines)
    $entry = Find-FrontendEntry -Lines $Lines
    $values = @{}
    foreach ($i in $entry.Fields) {
        if ($Lines[$i] -match '^\s*(?<key>[A-Za-z]+):\s*(?<value>\S+)\s*$') {
            $values[$Matches.key] = $Matches.value
        }
    }
    $newName = $values['newName']
    $digest = $values['digest']
    [pscustomobject] @{
        NewName   = $newName
        NewTag    = $values['newTag']
        Digest    = $digest
        Reference = if ($newName -and $digest) { "$newName@$digest" } else { $null }
    }
}

# Returns the lines with the frontend entry's fields replaced by newName and digest.
# Everything else, comments included, stays as it was.
function Set-FrontendImageLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines,
        [Parameter(Mandatory)] [string] $Reference
    )
    $image = Split-ImageReference -Reference $Reference
    $entry = Find-FrontendEntry -Lines $Lines
    $after = if ($entry.Fields.Count -gt 0) { $entry.Fields[-1] + 1 } else { $entry.Start + 1 }
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -le $entry.Start; $i++) { $result.Add($Lines[$i]) }
    $result.Add("$($entry.FieldIndent)newName: $($image.Repository)")
    $result.Add("$($entry.FieldIndent)digest: $($image.Digest)")
    for ($i = $after; $i -lt $Lines.Count; $i++) { $result.Add($Lines[$i]) }
    , $result.ToArray()
}

function Read-Overlay {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Overlay not found: $Path"
    }
    # Split keeps a last empty element for the final newline, so writing back keeps it.
    , ([System.IO.File]::ReadAllText($Path) -split '\r?\n')
}

function Write-Overlay {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines
    )
    if ($PSCmdlet.ShouldProcess($Path, 'Set the frontend image')) {
        # LF and no BOM, as .gitattributes asks for.
        [System.IO.File]::WriteAllText($Path, ($Lines -join "`n"), [System.Text.UTF8Encoding]::new($false))
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'
    try {
        $path = Get-OverlayFile -RepoRoot $RepoRoot -Environment $Environment
        $lines = Read-Overlay -Path $path
        $current = Get-FrontendImage -Lines $lines
        if ($PSCmdlet.ParameterSetName -eq 'Show') {
            if (-not $current.Reference) {
                throw "The $Environment frontend is not pinned by digest yet (newName '$($current.NewName)', newTag '$($current.NewTag)')."
            }
            Write-Output $current.Reference
            exit 0
        }
        $reference = if ($PSCmdlet.ParameterSetName -eq 'Copy') {
            $source = Get-FrontendImage -Lines (Read-Overlay -Path (Get-OverlayFile -RepoRoot $RepoRoot -Environment $FromEnvironment))
            if (-not $source.Reference) {
                throw "The $FromEnvironment frontend is not pinned by digest yet, so there is nothing to copy."
            }
            $source.Reference
        } else {
            $Image
        }
        if ($current.Reference -eq $reference) {
            Write-Information "$Environment frontend is already $reference."
            exit 0
        }
        Write-Overlay -Path $path -Lines (Set-FrontendImageLine -Lines $lines -Reference $reference)
        $name = if ($current.NewName) { $current.NewName } else { $script:FrontendUpstreamImage }
        $was = if ($current.Reference) { $current.Reference } else { "${name}:$($current.NewTag)" }
        Write-Information "$Environment frontend: $was -> $reference"
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
    exit 0
}
