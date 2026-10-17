# butaglyph: PowerShell integration (Windows PowerShell 5.1 and PowerShell 7+).
# Load with:  Invoke-Expression (& buta init powershell | Out-String)

$global:__buta_bin = ::BUTA::
$global:__buta_history_id = -1

function global:prompt {
    # Read these first: every command below changes them.
    $origDollarQuestion = $global:?
    $origLastExitCode = $global:LASTEXITCODE

    # Status and duration describe the last command entered, so pressing
    # Enter on an empty line shows neither again.
    $status = 0
    $duration = ''
    $last = Get-History -Count 1
    if ($last -and $last.Id -ne $global:__buta_history_id) {
        $global:__buta_history_id = $last.Id
        $duration = [long]($last.EndExecutionTime - $last.StartExecutionTime).TotalMilliseconds
        if (-not $origDollarQuestion) {
            # A failed native command sets $LASTEXITCODE; a failed cmdlet doesn't.
            $status = if ($origLastExitCode) { $origLastExitCode } else { 1 }
        }
    }
    $jobs = @(Get-Job -State Running -ErrorAction Ignore).Count

    # PowerShell's location is not the process's working directory.
    $arguments = @('prompt', '--shell=powershell', "--status=$status", "--duration-ms=$duration", "--jobs=$jobs")
    $location = $executionContext.SessionState.Path.CurrentLocation
    if ($location.Provider.Name -eq 'FileSystem') {
        $arguments += "--cwd=$($location.ProviderPath)"
    }

    # buta writes UTF-8; Windows PowerShell would decode it with the OEM code page.
    $origEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $lines = @(& $global:__buta_bin @arguments)
    } finally {
        [Console]::OutputEncoding = $origEncoding
    }

    # PSReadLine redraws multi-line prompts correctly only if told their height.
    if (Get-Module PSReadLine) {
        Set-PSReadLineOption -ExtraPromptLineCount ([Math]::Max(0, $lines.Count - 1))
    }

    $global:LASTEXITCODE = $origLastExitCode
    if ($global:? -ne $origDollarQuestion) {
        # Restore $? as well, for anything that inspects it after the prompt.
        if ($origDollarQuestion) { $null = 1 } else { Write-Error '' -ErrorAction Ignore }
    }
    $lines -join "`n"
}
