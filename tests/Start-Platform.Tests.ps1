BeforeAll {
    # Dot-source so we get the functions without running the main block.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Start-Platform.ps1')
    $script:bootstrapPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'bootstrap'

    # What Invoke-Cli returns: an exit code and the combined output.
    function Get-FakeResult {
        param([int] $ExitCode = 0, [string] $Output = '')
        [pscustomobject] @{ ExitCode = $ExitCode; Output = $Output }
    }

    # The value after a flag, e.g. '10.10.3' after '--version'.
    function Get-FlagValue {
        param([string[]] $Arguments, [string] $Flag)
        $index = [array]::IndexOf($Arguments, $Flag)
        if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) {
            $Arguments[$index + 1]
        }
    }

    # Application rows as ConvertFrom-ApplicationList returns them, written 'name=Sync/Health'.
    function Get-ApplicationRow {
        param([string[]] $Spec)
        foreach ($entry in $Spec) {
            $name, $sync, $health = $entry -split '[=/]'
            [pscustomobject] @{ Name = $name; Sync = $sync; Health = $health }
        }
    }

    # The same rows as `kubectl get applications --output json` prints them.
    function ConvertTo-ApplicationListJson {
        param([string[]] $Spec = @())
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($row in (Get-ApplicationRow -Spec $Spec)) {
            $items.Add(@{ metadata = @{ name = $row.Name }; status = @{ sync = @{ status = $row.Sync }; health = @{ status = $row.Health } } })
        }
        @{ apiVersion = 'v1'; kind = 'List'; items = $items } | ConvertTo-Json -Depth 10
    }

    # One Application as kubectl prints it, with the revision in its spec and the one Argo CD last compared.
    function ConvertTo-RevisionItem {
        param([string] $Name, [string] $Revision, [string] $ComparedTo, [string] $RepoUrl = 'https://example.com/repo.git')
        @{
            metadata = @{ name = $Name }
            spec     = @{ source = @{ repoURL = $RepoUrl; targetRevision = $Revision } }
            status   = @{
                sync   = @{ status = 'Synced'; comparedTo = @{ source = @{ repoURL = $RepoUrl; targetRevision = $ComparedTo } } }
                health = @{ status = 'Healthy' }
            }
        }
    }
}

# lib/Cli.ps1 is shared by every script; its tests live here, with its main user.
Describe 'Invoke-Cli' {
    BeforeAll {
        # A function shadows the program of the same name, so the real kubectl never runs.
        # It echoes stdin and its arguments, writes one error line and exits 3.
        function kubectl {
            foreach ($line in $input) { "stdin: $line" }
            "args: $($args -join ' ')"
            Write-Error -Message 'warning on stderr' -ErrorAction Continue
            $global:LASTEXITCODE = 3
        }
    }

    It 'returns the exit code and the output, stderr included' {
        $result = Invoke-Cli -Name kubectl -Arguments @('get', 'pods')
        $result.ExitCode | Should -Be 3
        $result.Output | Should -Be (@('args: get pods', 'warning on stderr') -join [Environment]::NewLine)
    }

    It 'sends -InputText on stdin' {
        $result = Invoke-Cli -Name kubectl -Arguments @('apply', '--filename', '-') -InputText '{"kind":"Application"}'
        ($result.Output -split '\r?\n')[0] | Should -Be 'stdin: {"kind":"Application"}'
    }

    It 'shows each line as it arrives with -Live' {
        Invoke-Cli -Name kubectl -Arguments @('version') -Live -InformationVariable info -InformationAction SilentlyContinue | Out-Null
        $info.MessageData | Should -Be @('    args: version', '    warning on stderr')
    }
}

Describe 'Test-ToolInstalled' {
    It 'is true for a program on PATH' {
        $savedPath = $env:PATH
        try {
            $env:PATH = Split-Path -Path (Get-Process -Id $PID).Path -Parent
            Test-ToolInstalled -Name 'pwsh' | Should -BeTrue
        } finally {
            $env:PATH = $savedPath
        }
    }

    It 'is false for a program that is not on PATH' {
        Test-ToolInstalled -Name 'no-such-tool-7f3a' | Should -BeFalse
    }

    It 'counts only programs, not a cmdlet of the same name' {
        Test-ToolInstalled -Name 'Get-ChildItem' | Should -BeFalse
    }
}

Describe 'Get-KubeContext' {
    It 'is the context kind creates: kind- and the cluster name' {
        Get-KubeContext -ClusterName 'gitops-local' | Should -Be 'kind-gitops-local'
    }
}

Describe 'Test-Prerequisite' {
    BeforeEach {
        Mock Test-ToolInstalled { $true }
        Mock Invoke-Cli { Get-FakeResult -Output '27.3.1' }
    }

    It 'reports nothing when every tool is on PATH and Docker is running' {
        @(Test-Prerequisite).Count | Should -Be 0
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'docker' -and ($Arguments -join ' ') -eq 'info --format {{.ServerVersion}}'
        }
    }

    It 'reports each missing tool by name' {
        Mock Test-ToolInstalled { $false } -ParameterFilter { $Name -in 'kind', 'helm' }
        $problems = @(Test-Prerequisite)
        $problems.Count | Should -Be 2
        $problems[0] | Should -BeLike 'kind is not on PATH*'
        $problems[1] | Should -BeLike 'helm is not on PATH*'
    }

    It 'reports all four tools and skips the Docker check when nothing is installed' {
        Mock Test-ToolInstalled { $false }
        @(Test-Prerequisite).Count | Should -Be 4
        # Without the docker CLI there is nothing to ask whether the engine runs.
        Should -Invoke Invoke-Cli -Times 0 -Exactly
    }

    It 'reports Docker not running when docker info fails' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'Cannot connect to the Docker daemon' }
        $problems = @(Test-Prerequisite)
        $problems.Count | Should -Be 1
        $problems[0] | Should -BeLike 'Docker is not running*'
    }
}

Describe 'Initialize-Cluster' {
    BeforeEach {
        Mock Invoke-Cli { Get-FakeResult -Output 'other-cluster' } -ParameterFilter { $Arguments[0] -eq 'get' }
        Mock Invoke-Cli { Get-FakeResult } -ParameterFilter { $Arguments[0] -eq 'create' }
    }

    It 'reuses an existing cluster without creating one' {
        Mock Invoke-Cli { Get-FakeResult -Output "other-cluster`r`ngitops-local`r`n" } -ParameterFilter { $Arguments[0] -eq 'get' }
        Initialize-Cluster -ClusterName 'gitops-local' -InformationAction Ignore
        Should -Invoke Invoke-Cli -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'create' }
    }

    It 'creates a missing cluster by name from bootstrap/kind-config.yaml' {
        Initialize-Cluster -ClusterName 'gitops-local' -InformationAction Ignore
        $config = Join-Path -Path $script:bootstrapPath -ChildPath 'kind-config.yaml'
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'kind' -and ($Arguments[0..1] -join ' ') -eq 'create cluster' -and
            (Get-FlagValue -Arguments $Arguments -Flag '--name') -eq 'gitops-local' -and
            (Get-FlagValue -Arguments $Arguments -Flag '--config') -eq $config
        }
        Test-Path -LiteralPath $config | Should -BeTrue
    }

    It 'creates the cluster when kind says "No kind clusters found."' {
        # kind prints this instead of names when there are none; Invoke-Cli merges it into the output.
        Mock Invoke-Cli { Get-FakeResult -Output 'No kind clusters found.' } -ParameterFilter { $Arguments[0] -eq 'get' }
        Initialize-Cluster -ClusterName 'gitops-local' -InformationAction Ignore
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'create' }
    }

    It 'does not take a cluster whose name only starts the same for this one' {
        Mock Invoke-Cli { Get-FakeResult -Output 'gitops-local-old' } -ParameterFilter { $Arguments[0] -eq 'get' }
        Initialize-Cluster -ClusterName 'gitops-local' -InformationAction Ignore
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'create' }
    }

    It 'throws when kind create cluster fails' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 } -ParameterFilter { $Arguments[0] -eq 'create' }
        { Initialize-Cluster -ClusterName 'gitops-local' -InformationAction Ignore } |
            Should -Throw '*kind create cluster failed (exit 1)*'
    }

    It 'throws when kind get clusters fails, and creates nothing' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'permission denied' } -ParameterFilter { $Arguments[0] -eq 'get' }
        { Initialize-Cluster -ClusterName 'gitops-local' -InformationAction Ignore } |
            Should -Throw '*kind get clusters failed: permission denied*'
        Should -Invoke Invoke-Cli -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'create' }
    }
}

Describe 'Install-ArgoCd' {
    BeforeEach {
        $script:helmArguments = @()
        Mock Invoke-Cli {
            $script:helmArguments = $Arguments
            Get-FakeResult
        }
    }

    It 'installs the pinned OCI chart once, with helm' {
        Install-ArgoCd -Context 'kind-test' -InformationAction Ignore
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter { $Name -eq 'helm' }
        # upgrade --install: the first run installs, later runs upgrade in place.
        ($script:helmArguments[0..3] -join ' ') | Should -Be 'upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd'
        Get-FlagValue -Arguments $script:helmArguments -Flag '--version' | Should -Be '10.10.3'
    }

    It 'targets the given context and the argocd namespace' {
        Install-ArgoCd -Context 'kind-test' -InformationAction Ignore
        Get-FlagValue -Arguments $script:helmArguments -Flag '--kube-context' | Should -Be 'kind-test'
        Get-FlagValue -Arguments $script:helmArguments -Flag '--namespace' | Should -Be 'argocd'
        $script:helmArguments | Should -Contain '--create-namespace'
    }

    It 'uses bootstrap/argocd-values.yaml and waits for the release' {
        Install-ArgoCd -Context 'kind-test' -InformationAction Ignore
        $values = Join-Path -Path $script:bootstrapPath -ChildPath 'argocd-values.yaml'
        Get-FlagValue -Arguments $script:helmArguments -Flag '--values' | Should -Be $values
        Test-Path -LiteralPath $values | Should -BeTrue
        $script:helmArguments | Should -Contain '--wait'
    }

    It 'throws when helm fails' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'Error: context deadline exceeded' }
        { Install-ArgoCd -Context 'kind-test' -InformationAction Ignore } |
            Should -Throw '*helm upgrade --install argocd failed (exit 1)*'
    }
}

Describe 'Build-RootApplication' {
    BeforeAll {
        $script:app = Build-RootApplication -RepoUrl 'https://example.test/fork.git' -Revision 'abc1234'
    }

    It 'is an Argo CD Application named root in argocd' {
        $script:app.apiVersion | Should -Be 'argoproj.io/v1alpha1'
        $script:app.kind | Should -Be 'Application'
        $script:app.metadata.name | Should -Be 'root'
        $script:app.metadata.namespace | Should -Be 'argocd'
        $script:app.spec.destination.server | Should -Be 'https://kubernetes.default.svc'
    }

    It 'deploys clusters/local from the given repository and revision' {
        $script:app.spec.source.repoURL | Should -Be 'https://example.test/fork.git'
        $script:app.spec.source.targetRevision | Should -Be 'abc1234'
        $script:app.spec.source.path | Should -Be 'clusters/local'
    }

    It 'passes the same repository and revision to the chart, so the child Applications follow them' {
        $script:app.spec.source.helm.valuesObject.repoURL | Should -Be 'https://example.test/fork.git'
        $script:app.spec.source.helm.valuesObject.targetRevision | Should -Be 'abc1234'
    }

    It 'syncs automatically, with prune and selfHeal' {
        $script:app.spec.syncPolicy.automated.prune | Should -BeTrue
        $script:app.spec.syncPolicy.automated.selfHeal | Should -BeTrue
    }
}

Describe 'Install-RootApplication' {
    BeforeEach {
        $script:app = Build-RootApplication -RepoUrl 'https://example.test/fork.git' -Revision 'abc1234'
        $script:stdin = ''
        Mock Invoke-Cli {
            $script:stdin = $InputText
            Get-FakeResult -Output 'application.argoproj.io/root created'
        }
    }

    It 'applies from stdin (--filename -) in the given context' {
        Install-RootApplication -Context 'kind-test' -Application $script:app -InformationAction Ignore
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'kubectl' -and ($Arguments -join ' ') -eq '--context kind-test apply --filename -' -and $InputText
        }
    }

    It 'sends the whole Application as JSON, nested values included' {
        Install-RootApplication -Context 'kind-test' -Application $script:app -InformationAction Ignore
        $sent = $script:stdin | ConvertFrom-Json
        $sent.kind | Should -Be 'Application'
        # The deepest values: a shallow ConvertTo-Json would turn these into strings.
        $sent.spec.source.helm.valuesObject.targetRevision | Should -Be 'abc1234'
        $sent.spec.syncPolicy.automated.selfHeal | Should -BeTrue
    }

    It 'throws with kubectl''s output when the apply fails' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'error: no matches for kind "Application"' }
        { Install-RootApplication -Context 'kind-test' -Application $script:app -InformationAction Ignore } |
            Should -Throw '*root Application failed: error: no matches for kind*'
    }
}

Describe 'Get-NestedValue' {
    BeforeAll {
        $script:object = [pscustomobject] @{ status = [pscustomobject] @{ sync = [pscustomobject] @{ status = 'Synced' } } }
    }

    It 'returns the value at the path' {
        Get-NestedValue -InputObject $script:object -Path 'status', 'sync', 'status' | Should -Be 'Synced'
    }

    It 'returns $null when a part of the path is missing' {
        Get-NestedValue -InputObject $script:object -Path 'status', 'health', 'status' | Should -BeNullOrEmpty
    }

    It 'returns $null for a $null input' {
        Get-NestedValue -InputObject $null -Path 'status' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-ApplicationList' {
    It 'returns one row per Application with its sync and health' {
        $rows = @(ConvertFrom-ApplicationList -Json (ConvertTo-ApplicationListJson -Spec 'root=Synced/Healthy', 'boutique-dev=OutOfSync/Progressing'))
        $rows.Count | Should -Be 2
        $rows[1].Name | Should -Be 'boutique-dev'
        $rows[1].Sync | Should -Be 'OutOfSync'
        $rows[1].Health | Should -Be 'Progressing'
    }

    It 'gives Unknown when an Application has no status yet' {
        # Argo CD adds status only after it first looks at a new Application.
        $row = ConvertFrom-ApplicationList -Json '{"items":[{"metadata":{"name":"boutique-dev"}}]}'
        $row.Name | Should -Be 'boutique-dev'
        $row.Sync | Should -Be 'Unknown'
        $row.Health | Should -Be 'Unknown'
    }

    It 'gives Unknown health when only sync is reported' {
        $row = ConvertFrom-ApplicationList -Json '{"items":[{"metadata":{"name":"root"},"status":{"sync":{"status":"Synced"}}}]}'
        $row.Sync | Should -Be 'Synced'
        $row.Health | Should -Be 'Unknown'
    }

    It 'reads the source in the spec and the source Argo CD last compared' {
        $json = @{ items = @(ConvertTo-RevisionItem -Name 'boutique-dev' -Revision 'feature/x' -ComparedTo 'main') } | ConvertTo-Json -Depth 10
        $row = ConvertFrom-ApplicationList -Json $json
        $row.RepoUrl | Should -Be 'https://example.com/repo.git'
        $row.Revision | Should -Be 'feature/x'
        $row.ComparedRepoUrl | Should -Be 'https://example.com/repo.git'
        $row.ComparedTo | Should -Be 'main'
    }

    It 'returns nothing for an empty list' {
        @(ConvertFrom-ApplicationList -Json (ConvertTo-ApplicationListJson)).Count | Should -Be 0
    }

    It 'returns nothing when the list has no items field' {
        @(ConvertFrom-ApplicationList -Json '{"kind":"List"}').Count | Should -Be 0
    }
}

Describe 'Test-PlatformReady' {
    It 'is false with no Applications' {
        Test-PlatformReady -Status @() | Should -BeFalse
    }

    It 'is false with only the root, whose children do not exist yet' {
        Test-PlatformReady -Status @(Get-ApplicationRow -Spec 'root=Synced/Healthy') | Should -BeFalse
    }

    It 'is false when one Application is <Sync> and <Health>' -ForEach @(
        @{ Sync = 'OutOfSync'; Health = 'Healthy' }
        @{ Sync = 'Synced'; Health = 'Progressing' }
        @{ Sync = 'Synced'; Health = 'Degraded' }
        @{ Sync = 'Unknown'; Health = 'Unknown' }
    ) {
        $status = @(Get-ApplicationRow -Spec 'root=Synced/Healthy', 'boutique-dev=Synced/Healthy', "boutique-prod=$Sync/$Health")
        Test-PlatformReady -Status $status | Should -BeFalse
    }

    It 'is false while an Application still reports its status for the previous revision' {
        # A re-run with a new -Revision: the spec changed, the status has not caught up yet.
        $json = @{ items = @(
                ConvertTo-RevisionItem -Name 'root' -Revision 'feature/x' -ComparedTo 'feature/x'
                ConvertTo-RevisionItem -Name 'boutique-dev' -Revision 'feature/x' -ComparedTo 'main'
            ) } | ConvertTo-Json -Depth 10
        $status = @(ConvertFrom-ApplicationList -Json $json)
        Test-PlatformReady -Status $status -RepoUrl 'https://example.com/repo.git' -Revision 'feature/x' | Should -BeFalse
    }

    It 'is false while a child Application still points at the previous revision' {
        # The root has synced, but has not rewritten the child's spec yet.
        $json = @{ items = @(
                ConvertTo-RevisionItem -Name 'root' -Revision 'feature/x' -ComparedTo 'feature/x'
                ConvertTo-RevisionItem -Name 'boutique-dev' -Revision 'main' -ComparedTo 'main'
            ) } | ConvertTo-Json -Depth 10
        Test-PlatformReady -Status @(ConvertFrom-ApplicationList -Json $json) -Revision 'feature/x' | Should -BeFalse
    }

    It 'is false when an Application deploys from another repository' {
        $json = @{ items = @(
                ConvertTo-RevisionItem -Name 'root' -Revision 'main' -ComparedTo 'main'
                ConvertTo-RevisionItem -Name 'boutique-dev' -Revision 'main' -ComparedTo 'main' -RepoUrl 'https://example.com/fork.git'
            ) } | ConvertTo-Json -Depth 10
        Test-PlatformReady -Status @(ConvertFrom-ApplicationList -Json $json) -RepoUrl 'https://example.com/repo.git' -Revision 'main' |
            Should -BeFalse
    }

    It 'is true when every Application points at and was compared against the repository and revision' {
        $json = @{ items = @(
                ConvertTo-RevisionItem -Name 'root' -Revision 'feature/x' -ComparedTo 'feature/x'
                ConvertTo-RevisionItem -Name 'boutique-dev' -Revision 'feature/x' -ComparedTo 'feature/x'
            ) } | ConvertTo-Json -Depth 10
        Test-PlatformReady -Status @(ConvertFrom-ApplicationList -Json $json) -RepoUrl 'https://example.com/repo.git' -Revision 'feature/x' |
            Should -BeTrue
    }

    It 'is true when two or more Applications are all Synced and Healthy' {
        Test-PlatformReady -Status @(Get-ApplicationRow -Spec 'root=Synced/Healthy', 'boutique-dev=Synced/Healthy') | Should -BeTrue
        Test-PlatformReady -Status @(Get-ApplicationRow -Spec 'root=Synced/Healthy', 'boutique-dev=Synced/Healthy', 'boutique-prod=Synced/Healthy') |
            Should -BeTrue
    }
}

Describe 'Format-ApplicationStatus' {
    It 'says so when there are no Applications yet' {
        Format-ApplicationStatus -Status @() | Should -Be '(no Applications yet)'
    }

    It 'lists the Applications sorted by name' {
        $table = Format-ApplicationStatus -Status @(Get-ApplicationRow -Spec 'root=Synced/Healthy', 'boutique-dev=OutOfSync/Missing')
        $lines = @($table -split '\r?\n')
        $lines.Count | Should -Be 4
        $lines[2] | Should -Match '^boutique-dev\s+OutOfSync\s+Missing\s*$'
        $lines[3] | Should -Match '^root\s+Synced\s+Healthy\s*$'
    }
}

Describe 'Wait-PlatformReady' {
    BeforeEach {
        Mock Start-Sleep { }
        # Each poll returns the next response in $script:responses; the last one repeats.
        $script:responses = @()
        $script:polls = 0
        Mock Invoke-Cli {
            $script:polls++
            $script:responses[[math]::Min($script:polls, $script:responses.Count) - 1]
        }
        $script:notReady = Get-FakeResult -Output (ConvertTo-ApplicationListJson -Spec 'root=Synced/Healthy', 'boutique-dev=OutOfSync/Progressing')
        $script:ready = Get-FakeResult -Output (ConvertTo-ApplicationListJson -Spec 'root=Synced/Healthy', 'boutique-dev=Synced/Healthy')
    }

    It 'returns the Applications once all are Synced and Healthy, after 3 polls' {
        $script:responses = @(
            Get-FakeResult -Output (ConvertTo-ApplicationListJson -Spec 'root=Synced/Healthy')
            $script:notReady
            $script:ready
        )
        $status = @(Wait-PlatformReady -Context 'kind-test' -TimeoutSeconds 60 -IntervalSeconds 10 -InformationAction Ignore)
        $status.Count | Should -Be 2
        Should -Invoke Invoke-Cli -Times 3 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -eq '--context kind-test get applications.argoproj.io --namespace argocd --output json'
        }
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 10 }
    }

    It 'treats a kubectl failure as not ready and polls again' {
        # Right after Argo CD installs, the Application API may not answer yet.
        $script:responses = @(
            Get-FakeResult -ExitCode 1 -Output 'error: the server doesn''t have a resource type "applications"'
            $script:ready
        )
        @(Wait-PlatformReady -Context 'kind-test' -TimeoutSeconds 60 -IntervalSeconds 10 -InformationAction Ignore).Count | Should -Be 2
        Should -Invoke Invoke-Cli -Times 2 -Exactly
    }

    It 'treats an empty list as not ready and polls again' {
        $script:responses = @(
            Get-FakeResult -Output (ConvertTo-ApplicationListJson)
            $script:ready
        )
        @(Wait-PlatformReady -Context 'kind-test' -TimeoutSeconds 60 -IntervalSeconds 10 -InformationAction Ignore).Count | Should -Be 2
        Should -Invoke Invoke-Cli -Times 2 -Exactly
    }

    It 'gives up after ceil(<Timeout> / <Interval>) = <Polls> polls with the last table in the error' -ForEach @(
        @{ Timeout = 30; Interval = 10; Polls = 3 }
        @{ Timeout = 25; Interval = 10; Polls = 3 }
        @{ Timeout = 5; Interval = 10; Polls = 1 }
    ) {
        $script:responses = @($script:notReady)
        $thrown = { Wait-PlatformReady -Context 'kind-test' -TimeoutSeconds $Timeout -IntervalSeconds $Interval -InformationAction Ignore } |
            Should -Throw -PassThru
        $thrown.Exception.Message | Should -BeLike "Timed out after $Timeout s*"
        $thrown.Exception.Message | Should -Match 'boutique-dev\s+OutOfSync\s+Progressing'
        Should -Invoke Invoke-Cli -Times $Polls -Exactly
        # No sleep after the last poll: it would only delay the error.
        Should -Invoke Start-Sleep -Times ($Polls - 1) -Exactly
    }

    It 'keeps polling while the status is for the previous revision, with -Revision' {
        $stale = @{ items = @(
                ConvertTo-RevisionItem -Name 'root' -Revision 'feature/x' -ComparedTo 'main'
                ConvertTo-RevisionItem -Name 'boutique-dev' -Revision 'main' -ComparedTo 'main'
            ) } | ConvertTo-Json -Depth 10
        $current = @{ items = @(
                ConvertTo-RevisionItem -Name 'root' -Revision 'feature/x' -ComparedTo 'feature/x'
                ConvertTo-RevisionItem -Name 'boutique-dev' -Revision 'feature/x' -ComparedTo 'feature/x'
            ) } | ConvertTo-Json -Depth 10
        $script:responses = @((Get-FakeResult -Output $stale), (Get-FakeResult -Output $current))
        $status = @(Wait-PlatformReady -Context 'kind-test' -TimeoutSeconds 60 -IntervalSeconds 10 -Revision 'feature/x' -InformationAction Ignore)
        $status.ComparedTo | Should -Be @('feature/x', 'feature/x')
        Should -Invoke Invoke-Cli -Times 2 -Exactly
    }

    It 'stops at the timeout even when each poll is slow' {
        # Each kubectl call takes 1.1 s. ceil(3 / 1) = 3 polls would take longer than 3 s,
        # so the clock stops it after the second.
        $script:responses = @($script:notReady)
        Mock Invoke-Cli { [System.Threading.Thread]::Sleep(1100); $script:notReady }
        { Wait-PlatformReady -Context 'kind-test' -TimeoutSeconds 3 -IntervalSeconds 1 -InformationAction Ignore } | Should -Throw 'Timed out after 3 s*'
        Should -Invoke Invoke-Cli -Times 2 -Exactly
    }

    It 'prints the table only when it changes' {
        $script:responses = @($script:notReady, $script:notReady, $script:ready)
        Wait-PlatformReady -Context 'kind-test' -TimeoutSeconds 60 -IntervalSeconds 10 -InformationVariable info -InformationAction SilentlyContinue |
            Out-Null
        # The "Waiting up to" line, the first table and the final one; the repeated table is not printed.
        $info.Count | Should -Be 3
        "$($info[1].MessageData)" | Should -Match 'OutOfSync'
        "$($info[2].MessageData)" | Should -Not -Match 'OutOfSync'
    }
}

Describe 'Get-AccessHint' {
    It 'names the context in every command' {
        $hint = Get-AccessHint -Context 'kind-test'
        [regex]::Matches($hint, 'kubectl --context kind-test ').Count | Should -Be 3
    }

    It 'gives the Argo CD, dev and prod addresses' {
        $hint = Get-AccessHint -Context 'kind-test'
        $hint | Should -Match 'svc/argocd-server 8080:80'
        $hint | Should -Match '-n boutique-dev port-forward svc/frontend 8081:80'
        $hint | Should -Match '-n boutique-prod port-forward svc/frontend 8082:80'
    }
}

Describe 'Start-Platform.ps1 exit code' {
    # Runs the real script in a child pwsh so we can see its exit code.
    It 'exits 1 and names each missing tool when none is on PATH' {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Start-Platform.ps1'
        $pwsh = (Get-Process -Id $PID).Path
        $savedPath = $env:PATH
        try {
            # PATH holds only an empty folder, so the child finds none of the tools and stops
            # at the prerequisite check. The cluster name is one no real run uses, to be safe.
            $env:PATH = $TestDrive
            $output = & $pwsh -NoProfile -NonInteractive -File $scriptPath -ClusterName 'pester-never-created' 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } finally {
            $env:PATH = $savedPath
        }
        $exitCode | Should -Be 1
        foreach ($tool in 'docker', 'kind', 'helm', 'kubectl') {
            $output | Should -Match "$tool is not on PATH"
        }
    }
}
