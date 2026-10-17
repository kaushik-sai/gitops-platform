BeforeAll {
    # Dot-source so we get the functions without running the main block.
    $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Set-FrontendImage.ps1'
    . $script:ScriptPath -Environment dev

    $script:Upstream = 'us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/frontend'
    $script:Digest = 'sha256:' + ('a' * 64)
    $script:OtherDigest = 'sha256:' + ('b' * 64)
    $script:Ghcr = 'ghcr.io/kaushik-sai/gitops-platform/frontend'

    # An overlay shaped like the real ones: a comment, the frontend entry, then more YAML.
    function Get-OverlayLine {
        param([string[]] $Fields = @('    newTag: v0.10.7'))
        @(
            'namespace: boutique-dev'
            ''
            'images:'
            '  # The frontend.'
            "  - name: $script:Upstream"
        ) + $Fields + @(
            ''
            'patches:'
            '  - patch: |-'
            '      kind: Deployment'
            ''
        )
    }
}

Describe 'Split-ImageReference' {
    It 'splits a GHCR reference pinned by digest' {
        $image = Split-ImageReference -Reference "$script:Ghcr@$script:Digest"
        $image.Repository | Should -Be $script:Ghcr
        $image.Digest | Should -Be $script:Digest
    }

    It 'accepts a registry with a port' {
        (Split-ImageReference -Reference "localhost:5000/frontend@$script:Digest").Repository | Should -Be 'localhost:5000/frontend'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a tag'; Reference = "$script:Ghcr`:v1" }
        @{ Case = 'a tag and a digest'; Reference = "$script:Ghcr`:v1@$script:Digest" }
        @{ Case = 'a short digest'; Reference = "$script:Ghcr@sha256:abc" }
        @{ Case = 'upper case'; Reference = "GHCR.IO/Kaushik/frontend@$script:Digest" }
        @{ Case = 'no registry path'; Reference = "frontend@$script:Digest" }
        @{ Case = 'text after the digest'; Reference = "$script:Ghcr@$script:Digest; rm -rf /" }
    ) {
        { Split-ImageReference -Reference $Reference } | Should -Throw '*pinned by digest*'
    }
}

Describe 'Find-FrontendEntry' {
    It 'finds the entry and its fields, and stops at the blank line after it' {
        $entry = Find-FrontendEntry -Lines (Get-OverlayLine -Fields @('    newName: x', '    newTag: y'))
        $entry.Start | Should -Be 4
        $entry.Fields | Should -Be @(5, 6)
        $entry.FieldIndent | Should -Be '    '
    }

    It 'stops at the next entry in the list' {
        $lines = Get-OverlayLine -Fields @('    newTag: y', '  - name: redis', '    newTag: 7')
        (Find-FrontendEntry -Lines $lines).Fields | Should -Be @(5)
    }

    It 'throws when there is no frontend entry' {
        { Find-FrontendEntry -Lines @('images:', '  - name: redis') } | Should -Throw '*found 0*'
    }

    It 'throws when there are two' {
        $lines = (Get-OverlayLine) + "  - name: $script:Upstream"
        { Find-FrontendEntry -Lines $lines } | Should -Throw '*found 2*'
    }
}

Describe 'Get-FrontendImage' {
    It 'has no reference while the entry is the upstream tag' {
        $image = Get-FrontendImage -Lines (Get-OverlayLine)
        $image.NewTag | Should -Be 'v0.10.7'
        $image.Reference | Should -BeNullOrEmpty
    }

    It 'returns repository@digest once pinned' {
        $image = Get-FrontendImage -Lines (Get-OverlayLine -Fields @("    newName: $script:Ghcr", "    digest: $script:Digest"))
        $image.Reference | Should -Be "$script:Ghcr@$script:Digest"
    }
}

Describe 'Edit-FrontendImageLine' {
    It 'replaces only the entry fields, keeping the comment and the rest of the file' {
        $before = Get-OverlayLine
        $after = Edit-FrontendImageLine -Lines $before -Reference "$script:Ghcr@$script:Digest"
        $expected = Get-OverlayLine -Fields @("    newName: $script:Ghcr", "    digest: $script:Digest")
        $after | Should -Be $expected
    }

    It 'replaces an earlier digest' {
        $before = Get-OverlayLine -Fields @("    newName: $script:Ghcr", "    digest: $script:Digest")
        $after = Edit-FrontendImageLine -Lines $before -Reference "$script:Ghcr@$script:OtherDigest"
        (Get-FrontendImage -Lines $after).Reference | Should -Be "$script:Ghcr@$script:OtherDigest"
        $after.Count | Should -Be $before.Count
    }

    It 'adds the fields to an entry that has none' {
        $after = Edit-FrontendImageLine -Lines (Get-OverlayLine -Fields @()) -Reference "$script:Ghcr@$script:Digest"
        (Get-FrontendImage -Lines $after).Reference | Should -Be "$script:Ghcr@$script:Digest"
    }

    It 'throws and changes nothing for a reference without a digest' {
        { Edit-FrontendImageLine -Lines (Get-OverlayLine) -Reference "$script:Ghcr`:latest" } | Should -Throw '*pinned by digest*'
    }
}

Describe 'Set-FrontendImage.ps1 on a copy of the repository' {
    BeforeEach {
        # The real overlays, copied, so the test also proves the script understands them.
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid())
        foreach ($env in 'dev', 'prod') {
            $dir = Join-Path -Path $script:Root -ChildPath 'apps' -AdditionalChildPath 'boutique', 'overlays', $env
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $source = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'apps', 'boutique', 'overlays', $env, 'kustomization.yaml'
            Copy-Item -Path $source -Destination $dir
        }
        $script:Dev = Get-OverlayFile -RepoRoot $script:Root -Environment dev
        $script:Prod = Get-OverlayFile -RepoRoot $script:Root -Environment prod

        # Runs the script in its own process, as the workflows do. Returns the exit code and output.
        function Invoke-Script {
            param([string[]] $Arguments)
            $output = & pwsh -NoProfile -File $script:ScriptPath -RepoRoot $script:Root @Arguments 2>&1
            [pscustomobject] @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
        }
    }

    It 'sets dev, leaves prod alone, and keeps LF line endings' {
        $prodBefore = Get-Content -Path $script:Prod -Raw
        $run = Invoke-Script -Arguments @('-Environment', 'dev', '-Image', "$script:Ghcr@$script:Digest")
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match ([regex]::Escape("-> $script:Ghcr@$script:Digest"))
        $dev = Get-Content -Path $script:Dev -Raw
        $dev | Should -Match ([regex]::Escape("    newName: $script:Ghcr`n    digest: $script:Digest`n"))
        $dev | Should -Not -Match "`r"
        $dev | Should -Not -Match 'newTag'
        Get-Content -Path $script:Prod -Raw | Should -Be $prodBefore
    }

    It 'copies dev to prod' {
        (Invoke-Script -Arguments @('-Environment', 'dev', '-Image', "$script:Ghcr@$script:Digest")).ExitCode | Should -Be 0
        (Invoke-Script -Arguments @('-Environment', 'prod', '-FromEnvironment', 'dev')).ExitCode | Should -Be 0
        $show = Invoke-Script -Arguments @('-Environment', 'prod', '-Show')
        $show.ExitCode | Should -Be 0
        $show.Output | Should -Be "$script:Ghcr@$script:Digest"
    }

    It 'says so and changes nothing when the image is already set' {
        (Invoke-Script -Arguments @('-Environment', 'dev', '-Image', "$script:Ghcr@$script:Digest")).ExitCode | Should -Be 0
        $before = Get-Content -Path $script:Dev -Raw
        $run = Invoke-Script -Arguments @('-Environment', 'dev', '-Image', "$script:Ghcr@$script:Digest")
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'already'
        Get-Content -Path $script:Dev -Raw | Should -Be $before
    }

    It 'fails to copy from an environment that is not pinned yet' {
        $run = Invoke-Script -Arguments @('-Environment', 'prod', '-FromEnvironment', 'dev')
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'nothing to copy'
    }

    It 'fails -Show while the environment runs the upstream tag' {
        $run = Invoke-Script -Arguments @('-Environment', 'dev', '-Show')
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'not pinned by digest'
    }

    It 'fails and leaves the file alone for an image without a digest' {
        $before = Get-Content -Path $script:Dev -Raw
        $run = Invoke-Script -Arguments @('-Environment', 'dev', '-Image', "$script:Ghcr`:latest")
        $run.ExitCode | Should -Be 1
        Get-Content -Path $script:Dev -Raw | Should -Be $before
    }
}
