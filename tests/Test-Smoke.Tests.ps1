BeforeAll {
    # Dot-source so we get the functions without running the main block.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Test-Smoke.ps1')

    # What Invoke-Probe returns. The default page holds every text the checks look for.
    function Get-FakeResponse {
        param([int] $StatusCode = 200, [string] $Content = 'ok Online Boutique Sunglasses Shopping Cart')
        [pscustomobject] @{ StatusCode = $StatusCode; Content = $Content }
    }
}

Describe 'Get-SmokeCheck' {
    It 'checks health, the home page, a product page and the cart, in that order' {
        $checks = @(Get-SmokeCheck)
        $checks.Count | Should -Be 4
        $checks.Path | Should -Be @('/_healthz', '/', '/product/OLJCESPC7Z', '/cart')
    }

    It 'expects some text on every page' {
        foreach ($check in Get-SmokeCheck) {
            $check.Expect | Should -Not -BeNullOrEmpty -Because "$($check.Path) needs a text to look for"
        }
    }
}

Describe 'Open-PortForward' {
    It 'forwards the local port to the frontend Service in the given context and namespace' {
        Mock Start-Process { }
        Open-PortForward -Context 'kind-test' -Namespace 'boutique-dev' -LocalPort 18080
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'kubectl' -and $PassThru -and
            ($ArgumentList -join ' ') -eq '--context kind-test --namespace boutique-dev port-forward svc/frontend 18080:80'
        }
    }
}

Describe 'Test-LocalPortFree' {
    It 'is true for a port nothing listens on' {
        # Port 0 asks the OS for a free port; release it again and test that one.
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $port = $probe.LocalEndpoint.Port
        $probe.Stop()
        Test-LocalPortFree -Port $port | Should -BeTrue
    }

    It 'is false while something listens on the port' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            Test-LocalPortFree -Port $listener.LocalEndpoint.Port | Should -BeFalse
        } finally {
            $listener.Stop()
        }
    }
}

Describe 'Assert-PortForward' {
    BeforeEach {
        Mock Get-PortForwardLogPath { Join-Path -Path $TestDrive -ChildPath 'port-forward-boutique-dev' }
    }

    It 'does nothing while the process runs' {
        { Assert-PortForward -Process (Get-Process -Id $PID) -Namespace 'boutique-dev' } | Should -Not -Throw
    }

    It 'throws with the exit code and kubectl''s error output once the process has stopped' {
        Set-Content -Path (Join-Path -Path $TestDrive -ChildPath 'port-forward-boutique-dev.err') -Value 'unable to listen on any of the requested ports'
        $pwsh = (Get-Process -Id $PID).Path
        $stopped = Start-Process -FilePath $pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'exit 3' -PassThru -NoNewWindow
        $stopped.WaitForExit()
        { Assert-PortForward -Process $stopped -Namespace 'boutique-dev' } |
            Should -Throw '*port-forward for boutique-dev stopped (exit 3): unable to listen on any of the requested ports*'
    }
}

Describe 'Close-PortForward' {
    It 'does nothing when there is no process' {
        Mock Stop-Process { }
        Close-PortForward -Process $null
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
}

Describe 'Invoke-Probe' {
    It 'returns the status code and body, even for an error status' {
        Mock Invoke-WebRequest { [pscustomobject] @{ StatusCode = 503; Content = 'unavailable' } }
        $probe = Invoke-Probe -Uri 'http://127.0.0.1:18080/_healthz'
        $probe.StatusCode | Should -Be 503
        $probe.Content | Should -Be 'unavailable'
        # Without -SkipHttpErrorCheck a 503 would throw and look the same as no answer at all.
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'http://127.0.0.1:18080/_healthz' -and $SkipHttpErrorCheck
        }
    }

    It 'never goes through a proxy' {
        # A proxy from HTTP_PROXY cannot reach this machine's 127.0.0.1.
        Mock Invoke-WebRequest { [pscustomobject] @{ StatusCode = 200; Content = 'ok' } }
        Invoke-Probe -Uri 'http://127.0.0.1:18080/_healthz' | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $NoProxy }
    }

    It 'returns $null when nothing answers' {
        Mock Invoke-WebRequest { throw 'No connection could be made because the target machine actively refused it.' }
        Invoke-Probe -Uri 'http://127.0.0.1:18080/_healthz' | Should -BeNullOrEmpty
    }
}

Describe 'Wait-Frontend' {
    BeforeEach {
        Mock Start-Sleep { }
    }

    It 'returns true once /_healthz answers 200, after retries' {
        $script:probes = 0
        Mock Invoke-Probe {
            $script:probes++
            # Nothing listening yet, then a frontend still starting, then a healthy one.
            switch ($script:probes) {
                1 { $null }
                2 { Get-FakeResponse -StatusCode 503 }
                default { Get-FakeResponse }
            }
        }
        Wait-Frontend -BaseUrl 'http://127.0.0.1:18080' -TimeoutSeconds 60 -IntervalSeconds 2 | Should -BeTrue
        Should -Invoke Invoke-Probe -Times 3 -Exactly -ParameterFilter { $Uri -eq 'http://127.0.0.1:18080/_healthz' }
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'returns false after ceil(Timeout / Interval) attempts' {
        Mock Invoke-Probe { $null }
        Wait-Frontend -BaseUrl 'http://127.0.0.1:18080' -TimeoutSeconds 9 -IntervalSeconds 2 | Should -BeFalse
        # ceil(9 / 2) = 5 attempts, with a sleep between each, none after the last.
        Should -Invoke Invoke-Probe -Times 5 -Exactly
        Should -Invoke Start-Sleep -Times 4 -Exactly
    }

    It 'stops at the timeout even when each probe is slow' {
        # Each probe takes 1.1 s. ceil(3 / 1) = 3 probes would take longer than 3 s,
        # so the clock stops it after the second.
        Mock Invoke-Probe { [System.Threading.Thread]::Sleep(1100); $null }
        Wait-Frontend -BaseUrl 'http://127.0.0.1:18080' -TimeoutSeconds 3 -IntervalSeconds 1 | Should -BeFalse
        Should -Invoke Invoke-Probe -Times 2 -Exactly
    }
}

Describe 'Invoke-SmokeCheck' {
    BeforeEach {
        Mock Invoke-Probe { Get-FakeResponse }
    }

    It 'passes every check when each page answers 200 with its text' {
        $results = @(Invoke-SmokeCheck -BaseUrl 'http://127.0.0.1:18080')
        $results.Count | Should -Be 4
        $results.Ok | Should -Not -Contain $false
        $results[2].Detail | Should -Be "HTTP 200, found 'Sunglasses'"
        foreach ($path in '/_healthz', '/', '/product/OLJCESPC7Z', '/cart') {
            Should -Invoke Invoke-Probe -Times 1 -Exactly -ParameterFilter { $Uri -eq "http://127.0.0.1:18080$path" }
        }
    }

    It 'fails only the check whose page returns an error status' {
        Mock Invoke-Probe { Get-FakeResponse -StatusCode 500 -Content 'Internal Server Error' } -ParameterFilter { $Uri -like '*/cart' }
        $results = @(Invoke-SmokeCheck -BaseUrl 'http://127.0.0.1:18080')
        $failed = @($results | Where-Object { -not $_.Ok })
        $failed.Count | Should -Be 1
        $failed[0].Path | Should -Be '/cart'
        $failed[0].Detail | Should -Be 'HTTP 500'
    }

    It 'fails a page that answers 200 without its text' {
        # A 200 alone is not enough: the page must show what the check expects.
        Mock Invoke-Probe { Get-FakeResponse -Content '<html>Uh, oh!</html>' } -ParameterFilter { $Uri -like '*/product/*' }
        $product = Invoke-SmokeCheck -BaseUrl 'http://127.0.0.1:18080' | Where-Object Path -EQ '/product/OLJCESPC7Z'
        $product.Ok | Should -BeFalse
        $product.Detail | Should -Be "HTTP 200 but no 'Sunglasses' on the page"
    }

    It 'fails a check that gets no response' {
        Mock Invoke-Probe { $null } -ParameterFilter { $Uri -like '*/_healthz' }
        $health = Invoke-SmokeCheck -BaseUrl 'http://127.0.0.1:18080' | Where-Object Path -EQ '/_healthz'
        $health.Ok | Should -BeFalse
        $health.Detail | Should -Be 'no response'
    }
}

Describe 'Test-Environment' {
    BeforeEach {
        # An unstarted process object stands in for kubectl: Close-PortForward is mocked,
        # so nothing is ever stopped.
        $script:process = [System.Diagnostics.Process]::new()
        Mock Test-LocalPortFree { $true }
        Mock Open-PortForward { $script:process }
        Mock Assert-PortForward { }
        Mock Close-PortForward { }
        Mock Start-Sleep { }
        Mock Invoke-Probe { Get-FakeResponse }
    }

    It 'returns one result per check and closes the port-forward' {
        $results = @(Test-Environment -Context 'kind-test' -Namespace 'boutique-dev' -LocalPort 18080 -TimeoutSeconds 30)
        $results.Count | Should -Be 4
        $results.Ok | Should -Not -Contain $false
        Should -Invoke Open-PortForward -Times 1 -Exactly -ParameterFilter {
            $Context -eq 'kind-test' -and $Namespace -eq 'boutique-dev' -and $LocalPort -eq 18080
        }
        Should -Invoke Invoke-Probe -Times 1 -Exactly -ParameterFilter { $Uri -eq 'http://127.0.0.1:18080/cart' }
        Should -Invoke Close-PortForward -Times 1 -Exactly -ParameterFilter { $Process -eq $script:process }
    }

    It 'checks that the port-forward still runs, before and after the page checks' {
        Test-Environment -Context 'kind-test' -Namespace 'boutique-dev' -LocalPort 18080 -TimeoutSeconds 30 | Out-Null
        Should -Invoke Assert-PortForward -Times 2 -Exactly -ParameterFilter { $Process -eq $script:process -and $Namespace -eq 'boutique-dev' }
    }

    It 'throws before starting a port-forward when the local port is already in use' {
        # Whatever holds the port would answer the checks in place of the frontend.
        Mock Test-LocalPortFree { $false }
        { Test-Environment -Context 'kind-test' -Namespace 'boutique-dev' -LocalPort 18080 -TimeoutSeconds 30 } |
            Should -Throw '*Port 18080 on 127.0.0.1 is already in use*'
        Should -Invoke Open-PortForward -Times 0 -Exactly
        Should -Invoke Invoke-Probe -Times 0 -Exactly
    }

    It 'throws, runs no page checks and closes the port-forward when it has stopped' {
        # Something answers /_healthz, but it is not this port-forward.
        Mock Assert-PortForward { throw 'kubectl port-forward for boutique-dev stopped (exit 1): error' }
        { Test-Environment -Context 'kind-test' -Namespace 'boutique-dev' -LocalPort 18080 -TimeoutSeconds 30 } |
            Should -Throw '*port-forward for boutique-dev stopped*'
        Should -Invoke Invoke-Probe -Times 0 -Exactly -ParameterFilter { $Uri -notlike '*/_healthz' }
        Should -Invoke Close-PortForward -Times 1 -Exactly -ParameterFilter { $Process -eq $script:process }
    }

    It 'returns a failed check as a result instead of throwing' {
        Mock Invoke-Probe { Get-FakeResponse -StatusCode 500 } -ParameterFilter { $Uri -like '*/cart' }
        $results = @(Test-Environment -Context 'kind-test' -Namespace 'boutique-dev' -LocalPort 18080 -TimeoutSeconds 30)
        $results.Count | Should -Be 4
        @($results | Where-Object { -not $_.Ok }).Path | Should -Be '/cart'
        Should -Invoke Close-PortForward -Times 1 -Exactly
    }

    It 'closes the port-forward and throws when the frontend never answers' {
        Mock Invoke-Probe { $null }
        { Test-Environment -Context 'kind-test' -Namespace 'boutique-dev' -LocalPort 18080 -TimeoutSeconds 10 } |
            Should -Throw '*frontend in boutique-dev did not answer /_healthz within 10 s*'
        Should -Invoke Close-PortForward -Times 1 -Exactly -ParameterFilter { $Process -eq $script:process }
        # The page checks never run against a frontend that is not there.
        Should -Invoke Invoke-Probe -Times 0 -Exactly -ParameterFilter { $Uri -notlike '*/_healthz' }
    }

    It 'closes the port-forward when a check throws' {
        Mock Invoke-Probe { throw 'probe crashed' } -ParameterFilter { $Uri -like '*/cart' }
        { Test-Environment -Context 'kind-test' -Namespace 'boutique-dev' -LocalPort 18080 -TimeoutSeconds 30 } |
            Should -Throw '*probe crashed*'
        Should -Invoke Close-PortForward -Times 1 -Exactly -ParameterFilter { $Process -eq $script:process }
    }

    It 'still calls Close-PortForward, with no process, when the port-forward cannot start' {
        Mock Open-PortForward { throw 'kubectl was not found' }
        { Test-Environment -Context 'kind-test' -Namespace 'boutique-dev' -LocalPort 18080 -TimeoutSeconds 30 } |
            Should -Throw '*kubectl was not found*'
        Should -Invoke Close-PortForward -Times 1 -Exactly -ParameterFilter { $null -eq $Process }
        Should -Invoke Invoke-Probe -Times 0 -Exactly
    }
}
