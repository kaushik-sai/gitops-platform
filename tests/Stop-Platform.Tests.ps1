BeforeAll {
    # Dot-source so we get the functions without running the main block.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Stop-Platform.ps1')

    # What Invoke-Cli returns: an exit code and the combined output.
    function Get-FakeResult {
        param([int] $ExitCode = 0, [string] $Output = '')
        [pscustomobject] @{ ExitCode = $ExitCode; Output = $Output }
    }
}

Describe 'Remove-KindCluster' {
    BeforeEach {
        # By default the cluster exists, next to another one.
        Mock Invoke-Cli { Get-FakeResult -Output "other-cluster`ngitops-local" } -ParameterFilter { $Arguments[0] -eq 'get' }
        Mock Invoke-Cli { Get-FakeResult -Output 'Deleting cluster "gitops-local" ...' } -ParameterFilter { $Arguments[0] -eq 'delete' }
    }

    It 'returns NotFound and deletes nothing when the cluster is absent' {
        Mock Invoke-Cli { Get-FakeResult -Output 'other-cluster' } -ParameterFilter { $Arguments[0] -eq 'get' }
        Remove-KindCluster -ClusterName 'gitops-local' | Should -Be 'NotFound'
        Should -Invoke Invoke-Cli -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'delete' }
    }

    It 'returns NotFound when kind says "No kind clusters found."' {
        Mock Invoke-Cli { Get-FakeResult -Output 'No kind clusters found.' } -ParameterFilter { $Arguments[0] -eq 'get' }
        Remove-KindCluster -ClusterName 'gitops-local' | Should -Be 'NotFound'
        Should -Invoke Invoke-Cli -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'delete' }
    }

    It 'deletes the cluster by name and returns Deleted' {
        Remove-KindCluster -ClusterName 'gitops-local' | Should -Be 'Deleted'
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'kind' -and ($Arguments -join ' ') -eq 'delete cluster --name gitops-local'
        }
    }

    It 'throws when kind delete cluster fails' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 } -ParameterFilter { $Arguments[0] -eq 'delete' }
        { Remove-KindCluster -ClusterName 'gitops-local' } | Should -Throw '*kind delete cluster failed (exit 1)*'
    }

    It 'throws when kind get clusters fails, and deletes nothing' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'permission denied' } -ParameterFilter { $Arguments[0] -eq 'get' }
        { Remove-KindCluster -ClusterName 'gitops-local' } | Should -Throw '*kind get clusters failed: permission denied*'
        Should -Invoke Invoke-Cli -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'delete' }
    }

    It 'deletes nothing with -WhatIf' {
        Remove-KindCluster -ClusterName 'gitops-local' -WhatIf | Out-Null
        Should -Invoke Invoke-Cli -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'delete' }
    }
}

Describe 'Stop-Platform.ps1 exit code' {
    # Runs the real script in a child pwsh so we can see its exit code.
    It 'exits 1 with a clear message when kind is not on PATH' {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Stop-Platform.ps1'
        $pwsh = (Get-Process -Id $PID).Path
        $savedPath = $env:PATH
        try {
            # PATH holds only an empty folder, so the child cannot find kind. The cluster name
            # is one no real run uses, so even a kind that slipped through deletes nothing real.
            $env:PATH = $TestDrive
            $output = & $pwsh -NoProfile -NonInteractive -File $scriptPath -ClusterName 'pester-never-created' 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } finally {
            $env:PATH = $savedPath
        }
        $exitCode | Should -Be 1
        $output | Should -Match 'kind is not on PATH'
    }
}
