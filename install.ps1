# Install the Claude Code status line into %USERPROFILE%\.claude and point settings.json at it.
#
#   irm https://raw.githubusercontent.com/phucanh08/claude-statusline/main/install.ps1 | iex
#
# Windows PowerShell 5.1 or PowerShell 7. Same result as install.sh: the status line is a bash
# script that Claude Code runs through Git Bash, so Git for Windows and jq are required.
# Run from a local clone (`powershell -ExecutionPolicy Bypass -File install.ps1`) it copies the
# script sitting next to it instead of downloading. Existing files are backed up as
# <file>.bak.<timestamp> before being changed; unchanged files are left alone, so re-running
# is a no-op. settings.json is edited by jq, as in install.sh, so every other key keeps its
# exact value (ConvertTo-Json would not: depth limit, one-element arrays, escaping).
#
# Keep this file ASCII: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page.

# Everything runs from functions called on the last line, so a truncated `irm | iex` download
# is a parse error and never runs half a script.

function Test-UnderWindowsDir([string]$Path) {
    if (-not $env:SystemRoot) { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    return $full.StartsWith($env:SystemRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

# The bash.exe of Git for Windows (what Claude Code runs the status line with), or $null.
# Only <git root>\bin\bash.exe is accepted, never whatever `bash` is on PATH:
# C:\Windows\System32\bash.exe is WSL's launcher.
function Find-GitBash {
    if ($env:CLAUDE_CODE_GIT_BASH_PATH) {
        # Claude Code's own override: it runs this one, so it is the one that must exist.
        $p = $env:CLAUDE_CODE_GIT_BASH_PATH
        if ((Test-Path -LiteralPath $p -PathType Leaf) -and -not (Test-UnderWindowsDir $p)) { return $p }
        return $null
    }
    $roots = @()
    # git.exe on PATH lives in <root>\cmd, <root>\bin or <root>\mingw64\bin.
    foreach ($git in @(Get-Command git.exe -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $root = Split-Path -Parent (Split-Path -Parent $git.Path)
        if ((Split-Path -Leaf $root) -eq 'mingw64') { $root = Split-Path -Parent $root }
        $roots += $root
    }
    # Default install locations (machine-wide and per-user), in case git is not on PATH.
    foreach ($base in $env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
        if ($base) { $roots += Join-Path $base 'Git' }
    }
    if ($env:LOCALAPPDATA) { $roots += Join-Path $env:LOCALAPPDATA 'Programs\Git' }
    foreach ($root in $roots) {
        $bash = Join-Path $root 'bin\bash.exe'
        if ((Test-Path -LiteralPath $bash -PathType Leaf) -and -not (Test-UnderWindowsDir $bash)) { return $bash }
    }
    return $null
}

# Run jq with arguments that are file paths or flags (filters come from -f files, so no
# argument carries quotes). Its UTF-8 output is decoded as UTF-8 whatever the console code
# page is, and CRLF (a native jq.exe's text-mode line ending) becomes LF, as install.sh writes.
# JSON strings escape a literal CR, so every CR in the output is a line ending.
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

function Install-ClaudeStatusLine([string]$SourceDir) {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # 5.1's progress bar makes downloads crawl

    $RawUrl = 'https://raw.githubusercontent.com/phucanh08/claude-statusline/main'
    $ClaudeDir = Join-Path $env:USERPROFILE '.claude'
    $Script = Join-Path $ClaudeDir 'statusline-command.sh'
    $Settings = Join-Path $ClaudeDir 'settings.json'
    # The value install.sh writes, key for key: uninstall.sh / uninstall.ps1 remove only this one.
    $StatusLine = '{"type":"command","command":"bash ~/.claude/statusline-command.sh"}'
    $Stamp = Get-Date -Format 'yyyyMMddHHmmss'

    $jq = Get-Command jq -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $jq) {
        throw ("claude-statusline: jq is required but was not found in PATH.`n" +
            "Install it first ('winget install jqlang.jq'), open a new PowerShell window, then re-run.")
    }
    $jq = $jq.Path
    if (-not (Find-GitBash)) {
        throw ("claude-statusline: Git Bash (Git for Windows) is required: Claude Code runs the status line with it.`n" +
            "Install it first ('winget install Git.Git'), open a new PowerShell window, then re-run.`n" +
            "Installed somewhere else? Set CLAUDE_CODE_GIT_BASH_PATH to its bin\bash.exe.")
    }

    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('claude-statusline.' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $tmpDir
    try {
        $filters = @{
            isObject = 'type == "object"'
            isOurs   = ".statusLine == $StatusLine"
            set      = ".statusLine = $StatusLine"
            create   = "{statusLine: $StatusLine}"
        }
        foreach ($name in @($filters.Keys)) {
            $file = Join-Path $tmpDir "$name.jq"
            [IO.File]::WriteAllText($file, $filters[$name])
            $filters[$name] = $file
        }

        # ---- fetch the script: local clone if we were run from a file, else download ----
        $newScript = Join-Path $tmpDir 'statusline-command.sh'
        if ($SourceDir -and (Test-Path -LiteralPath (Join-Path $SourceDir 'statusline-command.sh') -PathType Leaf)) {
            Copy-Item -LiteralPath (Join-Path $SourceDir 'statusline-command.sh') -Destination $newScript
        } else {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                # raw.githubusercontent.com needs TLS 1.2, which .NET Framework may not offer by default.
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            }
            Invoke-WebRequest -UseBasicParsing -Uri "$RawUrl/statusline-command.sh" -OutFile $newScript
        }

        # ---- validate settings.json before touching anything ----
        if (Test-Path -LiteralPath $Settings -PathType Leaf) {
            if ((Invoke-Jq $jq '-e', '-f', $filters.isObject, $Settings).Code -ne 0) {
                throw "claude-statusline: $Settings is not a valid JSON object; fix it and re-run."
            }
        }

        $null = New-Item -ItemType Directory -Force -Path $ClaudeDir

        # ---- install the script, byte for byte (LF, no BOM) ----
        $bytes = [IO.File]::ReadAllBytes($newScript)
        if ((Test-Path -LiteralPath $Script -PathType Leaf) -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($Script)) -ceq [Convert]::ToBase64String($bytes)) {
            Write-Host "Script already up to date: $Script"
        } else {
            if (Test-Path -LiteralPath $Script -PathType Leaf) {
                Copy-Item -LiteralPath $Script -Destination "$Script.bak.$Stamp"
                Write-Host "Backed up $Script -> $Script.bak.$Stamp"
            }
            [IO.File]::WriteAllBytes($Script, $bytes)
            Write-Host "Installed $Script"
        }

        # ---- point settings.json at it, keeping every other key ----
        if (Test-Path -LiteralPath $Settings -PathType Leaf) {
            if ((Invoke-Jq $jq '-e', '-f', $filters.isOurs, $Settings).Code -eq 0) {
                Write-Host "settings.json already configured: $Settings"
            } else {
                $r = Invoke-Jq $jq '-f', $filters.set, $Settings
                if ($r.Code -ne 0) { throw "claude-statusline: jq failed on ${Settings}: $($r.Err)" }
                Copy-Item -LiteralPath $Settings -Destination "$Settings.bak.$Stamp"
                Write-Host "Backed up $Settings -> $Settings.bak.$Stamp"
                Write-Utf8NoBom $Settings $r.Out
                Write-Host "Updated statusLine in $Settings"
            }
        } else {
            $r = Invoke-Jq $jq '-n', '-f', $filters.create
            if ($r.Code -ne 0) { throw "claude-statusline: jq failed: $($r.Err)" }
            Write-Utf8NoBom $Settings $r.Out
            Write-Host "Created $Settings"
        }
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Done. Restart Claude Code to see the new status line.'
}

# Run as a file: exit with a status. Run through `irm | iex`: throw instead, since `exit`
# would close the user's PowerShell window.
function Invoke-ClaudeStatusLineInstall([string]$CommandPath) {
    $fromFile = $CommandPath -and (Split-Path -Leaf $CommandPath) -eq 'install.ps1'
    $sourceDir = if ($fromFile) { Split-Path -Parent $CommandPath } else { '' }
    try {
        Install-ClaudeStatusLine $sourceDir
    } catch {
        if (-not $fromFile) { throw }
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}

Invoke-ClaudeStatusLineInstall $PSCommandPath
