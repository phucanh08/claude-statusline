# Remove what install.ps1 / install.sh added to %USERPROFILE%\.claude, and only that.
#
#   irm https://raw.githubusercontent.com/phucanh08/claude-statusline/main/uninstall.ps1 | iex
#
# Windows PowerShell 5.1 or PowerShell 7. Same rules as uninstall.sh:
# - statusLine is removed from settings.json only if it is exactly the value the installers
#   write; every other key is kept (settings.json is edited by jq, never ConvertTo-Json).
# - statusline-command.sh is removed only if it is byte-identical to this repo's script (so
#   local edits are never lost).
# - Backups (*.bak.*) are never restored or deleted; their paths are printed.
# Needs jq, not Git Bash. Run from a local clone
# (`powershell -ExecutionPolicy Bypass -File uninstall.ps1`) it compares against the script
# next to it instead of downloading.
#
# Keep this file ASCII: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page.

# Everything runs from functions called on the last line, so a truncated `irm | iex` download
# is a parse error and never runs half a script.

# Run jq with arguments that are file paths or flags (filters come from -f files, so no
# argument carries quotes). Its UTF-8 output is decoded as UTF-8 whatever the console code
# page is, and CRLF (a native jq.exe's text-mode line ending) becomes LF, as uninstall.sh
# writes. JSON strings escape a literal CR, so every CR in the output is a line ending.
function Invoke-Jq([string]$Jq, [string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Jq
    $psi.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Replace("`r`n", "`n"); Err = $err.Result }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Uninstall-ClaudeStatusLine([string]$SourceDir) {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # 5.1's progress bar makes downloads crawl

    $RawUrl = 'https://raw.githubusercontent.com/phucanh08/claude-statusline/main'
    $ClaudeDir = Join-Path $env:USERPROFILE '.claude'
    $Script = Join-Path $ClaudeDir 'statusline-command.sh'
    $Settings = Join-Path $ClaudeDir 'settings.json'
    # The value the installers write, key for key; any other statusLine is the user's.
    $StatusLine = '{"type":"command","command":"bash ~/.claude/statusline-command.sh"}'

    $jq = Get-Command jq -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $jq) {
        throw ("claude-statusline: jq is required but was not found in PATH.`n" +
            "Install it first ('winget install jqlang.jq'), open a new PowerShell window, then re-run.")
    }
    $jq = $jq.Path

    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('claude-statusline.' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $tmpDir
    try {
        $filters = @{
            isObject = 'type == "object"'
            hasSL    = 'has("statusLine")'
            isOurs   = ".statusLine == $StatusLine"
            remove   = 'del(.statusLine)'
        }
        foreach ($name in @($filters.Keys)) {
            $file = Join-Path $tmpDir "$name.jq"
            [IO.File]::WriteAllText($file, $filters[$name])
            $filters[$name] = $file
        }

        if ((Test-Path -LiteralPath $Settings -PathType Leaf) -and
            (Invoke-Jq $jq '-e', '-f', $filters.isObject, $Settings).Code -ne 0) {
            throw "claude-statusline: $Settings is not a valid JSON object; fix it and re-run."
        }

        # ---- script: reference copy (local clone if run from a file, else download) ----
        $refScript = Join-Path $tmpDir 'statusline-command.sh'
        if (Test-Path -LiteralPath $Script -PathType Leaf) {
            if ($SourceDir -and (Test-Path -LiteralPath (Join-Path $SourceDir 'statusline-command.sh') -PathType Leaf)) {
                Copy-Item -LiteralPath (Join-Path $SourceDir 'statusline-command.sh') -Destination $refScript
            } else {
                if ($PSVersionTable.PSVersion.Major -lt 6) {
                    # raw.githubusercontent.com needs TLS 1.2, which .NET Framework may not offer by default.
                    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                }
                Invoke-WebRequest -UseBasicParsing -Uri "$RawUrl/statusline-command.sh" -OutFile $refScript
            }
        }

        # ---- settings.json: drop statusLine only if it is ours ----
        if ((Test-Path -LiteralPath $Settings -PathType Leaf) -and
            (Invoke-Jq $jq '-e', '-f', $filters.hasSL, $Settings).Code -eq 0) {
            if ((Invoke-Jq $jq '-e', '-f', $filters.isOurs, $Settings).Code -eq 0) {
                $r = Invoke-Jq $jq '-f', $filters.remove, $Settings
                if ($r.Code -ne 0) { throw "claude-statusline: jq failed on ${Settings}: $($r.Err)" }
                Write-Utf8NoBom $Settings $r.Out
                Write-Host "Removed statusLine from $Settings"
            } else {
                Write-Host "Kept statusLine in ${Settings}: it is not the one the installer sets."
            }
        } else {
            Write-Host 'No statusLine in settings.json; nothing to remove.'
        }

        # ---- script: remove only an unmodified copy ----
        if (Test-Path -LiteralPath $Script -PathType Leaf) {
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Script)) -ceq
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($refScript))) {
                Remove-Item -LiteralPath $Script -Force
                Write-Host "Removed $Script"
            } else {
                Write-Host "Kept ${Script}: it differs from the released script (local changes?)."
            }
        } else {
            Write-Host "No $Script; nothing to remove."
        }

        if (Test-Path -LiteralPath $ClaudeDir -PathType Container) {
            $backups = @(Get-ChildItem -LiteralPath $ClaudeDir -File -Force |
                Where-Object { $_.Name -like 'statusline-command.sh.bak.*' -or $_.Name -like 'settings.json.bak.*' } |
                Sort-Object Name)
            if ($backups.Count) {
                Write-Host 'Backups left in place (restore manually if you want them back):'
                foreach ($b in $backups) { Write-Host "  $($b.FullName)" }
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Done. Restart Claude Code to apply.'
}

# Run as a file: exit with a status. Run through `irm | iex`: throw instead, since `exit`
# would close the user's PowerShell window.
function Invoke-ClaudeStatusLineUninstall([string]$CommandPath) {
    $fromFile = $CommandPath -and (Split-Path -Leaf $CommandPath) -eq 'uninstall.ps1'
    $sourceDir = if ($fromFile) { Split-Path -Parent $CommandPath } else { '' }
    try {
        Uninstall-ClaudeStatusLine $sourceDir
    } catch {
        if (-not $fromFile) { throw }
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}

Invoke-ClaudeStatusLineUninstall $PSCommandPath
