# Ghostty Shell Integration for PowerShell
#
# This script provides shell integration features for Ghostty when running
# PowerShell. It enables:
# - Prompt marking (OSC 133) for semantic prompt detection
# - Current working directory reporting (OSC 7)
# - Command status reporting
#
# To use, source this file in your PowerShell profile:
#   . "$env:GHOSTTY_RESOURCES_DIR\shell-integration\powershell\ghostty-integration.ps1"
#
# Or add it to your $PROFILE file.

# Only run if we're inside Ghostty
if ($env:TERM_PROGRAM -ne "ghostty") {
    return
}

# Mark that shell integration is active
$env:GHOSTTY_SHELL_INTEGRATION = "1"

# ESC sequences
$ESC = [char]0x1b
$BEL = [char]0x07

# OSC 133 prompt marking sequences
$_ghostty_prompt_start = "${ESC}]133;A${BEL}"
$_ghostty_cmd_start = "${ESC}]133;B${BEL}"
$_ghostty_cmd_end = "${ESC}]133;C${BEL}"

function _ghostty_osc7 {
    # Report current working directory via OSC 7
    $cwd = (Get-Location).Path -replace '\\', '/'
    $hostname = [System.Net.Dns]::GetHostName()
    Write-Host -NoNewline "${ESC}]7;file://${hostname}/${cwd}${BEL}"
}

function _ghostty_prompt_mark {
    param([int]$ExitCode = 0)
    # Report command exit status via OSC 133;D
    Write-Host -NoNewline "${ESC}]133;D;${ExitCode}${BEL}"
    # Mark prompt start
    Write-Host -NoNewline $_ghostty_prompt_start
    # Report CWD
    _ghostty_osc7
}

# Save the original prompt function
$_ghostty_original_prompt = $function:prompt

# Override the prompt function to include Ghostty markers
function prompt {
    $lastExit = if ($?) { 0 } else { 1 }
    _ghostty_prompt_mark -ExitCode $lastExit
    $result = & $_ghostty_original_prompt
    # Mark end of prompt / start of command input
    "${result}${_ghostty_cmd_start}"
}

# Hook into command execution to mark command output start
# PSReadLine provides PreCommandExecution hooks if available
if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
    $existingHandler = (Get-PSReadLineOption).AddToHistoryHandler
    Set-PSReadLineOption -AddToHistoryHandler {
        param($line)
        # Mark start of command output
        Write-Host -NoNewline $_ghostty_cmd_end
        if ($existingHandler) {
            return & $existingHandler $line
        }
        return $true
    }
}
