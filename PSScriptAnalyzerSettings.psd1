# PSScriptAnalyzer settings for the whole repo (the same rules as sk-devops-svc).
# Error and Warning findings fail the build.
# Information findings are reported but do not fail anything.
@{
    Severity     = @('Error', 'Warning', 'Information')

    IncludeDefaultRules = $true
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            # Code must run on PowerShell 7 on Windows (laptop) and Linux (CI).
            TargetVersions = @('7.0')
        }
        PSPlaceOpenBrace = @{
            Enable     = $true
            OnSameLine = $true
        }
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }
    }
}
