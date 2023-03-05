@{
    'Rules'        = @{
        PSAvoidUsingCmdletAliases        = @{
            'allowlist' = @()
        }
        PSAvoidUsingPositionalParameters = @{
            CommandAllowList = 'Write-Host', 'Join-Path'
            Enable           = $true
        }
    }
    'ExcludeRules' = @('PSAvoidUsingWriteHost', 'PSAvoidUsingEmptyCatchBlock')
}
