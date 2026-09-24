# Test runner for install.ps1. Every install runs in a child process of the same PowerShell
# (5.1 or 7) against a fake USERPROFILE/HOME under the temp dir, with Invoke-WebRequest
# stubbed: the real ~\.claude and the network are never touched.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\run.ps1
#   pwsh -NoProfile -File test/run.ps1
#
# -Installer runs the suite against another copy of install.ps1 (it needs
# statusline-command.sh next to it); CI uses it to check that broken installers fail.
# Keep this file ASCII (see install.ps1).

param([string]$Installer)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Installer) { $Installer = Join-Path $Repo 'install.ps1' }
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$RepoScript = Join-Path $Repo 'statusline-command.sh'
$RawScriptUrl = 'https://raw.githubusercontent.com/phucanh08/claude-statusline/main/statusline-command.sh'
# `jq -S -a -c .statusLine` of the contract value (same as install.sh).
$ExpectedSL = '{"command":"bash ~/.claude/statusline-command.sh","type":"command"}'
$HostExe = (Get-Process -Id $PID).Path
$Utf8 = New-Object System.Text.UTF8Encoding $false

$Work = Join-Path ([IO.Path]::GetTempPath()) ('csl-test-ps.' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $Work
$NetLog = Join-Path $Work 'net.log'
$null = New-Item -ItemType File -Path $NetLog

$script:pass = 0; $script:fail = 0
function Check([string]$Name, [scriptblock]$Test) {
    $ok = $false
    try { $ok = [bool](& $Test) } catch { Write-Host "       ($($_.Exception.Message))" }
    if ($ok) { $script:pass++; Write-Host "  ok   $Name" } else { $script:fail++; Write-Host "  FAIL $Name" }
}

$Jq = (Get-Command jq -CommandType Application | Select-Object -First 1).Path
# Canonical, ASCII-only (-a) form of a jq filter's result on a file: no quotes in the filter
# (5.1 mangles them on native command lines) and no code page in the way.
function JqCanon([string]$Filter, [string]$File) { (& $Jq -S -a -c $Filter $File) -join "`n" }

function New-Home([string]$Name) {
    $h = Join-Path $Work "home.$Name"; $null = New-Item -ItemType Directory -Path $h; $h
}
# Path, SHA-256 and mtime of every file under a directory.
function Snapshot([string]$Dir) {
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force | Sort-Object FullName)
    ($files | ForEach-Object {
        $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($_.FullName)))
        "$($_.FullName.Substring($Dir.Length)) $sha $($_.LastWriteTimeUtc.Ticks)"
    }) -join "`n"
}
function Same-Bytes([string]$A, [string]$B) {
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($A)) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($B))
}
function Has-Bom([string]$File) {
    $b = [IO.File]::ReadAllBytes($File); $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
}
function Is-Empty([string]$Dir) { @(Get-ChildItem -LiteralPath $Dir -Force).Count -eq 0 }
# First file named $Name (any PATHEXT extension) in a PATH string, or $null.
function Find-OnPath([string]$PathString, [string]$Name) {
    foreach ($d in $PathString.Split(';')) {
        if (-not $d) { continue }
        foreach ($ext in '', '.exe', '.cmd', '.bat', '.com') {
            $f = Join-Path $d "$Name$ext"
            if (Test-Path -LiteralPath $f -PathType Leaf) { return $f }
        }
    }
    return $null
}

# Child process body. Invoke-WebRequest/Invoke-RestMethod are shadowed by functions: every
# call is logged; only a test that sets CSL_SERVE gets a file back (the repo script).
$ChildBody = @'
function Invoke-WebRequest { param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
    Add-Content -LiteralPath $env:CSL_NET_LOG -Value "Invoke-WebRequest $Uri"
    if (-not $env:CSL_SERVE) { throw 'network disabled in tests' }
    Copy-Item -LiteralPath $env:CSL_SERVE -Destination $OutFile
}
function Invoke-RestMethod { Add-Content -LiteralPath $env:CSL_NET_LOG -Value "Invoke-RestMethod $args"; throw 'network disabled in tests' }
if ($env:CSL_PIPED) {
    # `irm .../install.ps1 | iex`, then prove the session survived a failure.
    $failed = $false
    try { Get-Content -Raw -LiteralPath $env:CSL_INSTALLER | Invoke-Expression }
    catch { [Console]::Error.WriteLine($_.Exception.Message); $failed = $true }
    Write-Output 'CSL-HOST-ALIVE'
    if ($failed) { exit 1 }
    exit 0
}
& $env:CSL_INSTALLER
exit $LASTEXITCODE
'@
$EncodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ChildBody))

# Run the installer with USERPROFILE/HOME = $H plus environment overrides ($null value =
# unset). Sets $script:rc and $script:out (stdout + stderr).
function Install-Into([string]$H, [hashtable]$Overrides = @{}, [switch]$Piped, [string]$Cwd = $Work) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HostExe
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $EncodedChild"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $Cwd
    $vars = @{ USERPROFILE = $H; HOME = $H; CSL_NET_LOG = $NetLog; CSL_INSTALLER = $Installer; CSL_SERVE = $null; CSL_PIPED = $null }
    if ($Piped) { $vars.CSL_PIPED = '1' }
    foreach ($k in $Overrides.Keys) { $vars[$k] = $Overrides[$k] }
    foreach ($k in $vars.Keys) {
        if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) }
        if ($null -ne $vars[$k]) { $psi.EnvironmentVariables[$k] = $vars[$k] }
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEndAsync()
    $o = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $script:rc = $p.ExitCode
    $script:out = $o + $err.Result
    if ($env:CSL_VERBOSE) { Write-Host $script:out }
}

Write-Host "host: $HostExe (PowerShell $($PSVersionTable.PSVersion))"
Write-Host "installer: $Installer"
Write-Host "jq: $Jq"

Write-Host '1. fresh install from a local checkout'
$H = New-Home 1
Install-Into $H
Check 'installer exits 0' { $rc -eq 0 }
Check 'installed script byte-identical to repo script' { Same-Bytes "$H\.claude\statusline-command.sh" $RepoScript }
Check 'fresh settings.json statusLine equals contract value' { (JqCanon '.statusLine' "$H\.claude\settings.json") -ceq $ExpectedSL }
Check 'fresh settings.json has no BOM' { -not (Has-Bom "$H\.claude\settings.json") }
Check 'fresh settings.json has LF line endings' { -not ([IO.File]::ReadAllBytes("$H\.claude\settings.json") -contains 13) }
Check 'repo script has no BOM and no CR' { -not (Has-Bom $RepoScript) -and -not ([IO.File]::ReadAllBytes($RepoScript) -contains 13) }

Write-Host '2. existing settings + script are preserved and backed up'
$H = New-Home 2; $null = New-Item -ItemType Directory -Path "$H\.claude"
$emoji = [char]::ConvertFromUtf32(0x1F680)
$viet = "Ti$([char]0x1EBF)ng Vi$([char]0x1EC7)t"
$fixture = @"
{
  "theme": "dark",
  "model": "opus",
  "permissions": { "allow": ["Bash(ls:*)"], "deny": [] },
  "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo \"hi\" \\ there" } ] } ] },
  "deep": { "a": { "b": { "c": { "d": { "e": [ 1 ] } } } } },
  "one": [ "only" ],
  "objInArray": [ { "k": "v" } ],
  "text": "$emoji $viet <&>",
  "num": 42, "big": 12345678901, "neg": -3, "frac": 1.5, "exp": 1e-7,
  "yes": true, "no": false, "nothing": null,
  "emptyObj": {}, "emptyArr": [],
  "statusLine": { "type": "command", "command": "sh ~/old-statusline.sh" }
}
"@
[IO.File]::WriteAllText("$H\.claude\settings.json", $fixture.Replace("`r`n", "`n"), $Utf8)
[IO.File]::WriteAllText("$H\.claude\statusline-command.sh", "echo old`n", $Utf8)
Copy-Item -LiteralPath "$H\.claude\settings.json" -Destination "$Work\settings.orig"
Install-Into $H
Check 'installer exits 0' { $rc -eq 0 }
Check 'fixture parses (precondition)' { (JqCanon '.deep.a.b.c.d.e' "$Work\settings.orig") -ceq '[1]' }
Check 'every other key keeps its value (nested, 1-element arrays, unicode, numbers, bool, null)' {
    (JqCanon 'del(.statusLine)' "$H\.claude\settings.json") -ceq (JqCanon 'del(.statusLine)' "$Work\settings.orig")
}
Check 'unicode written as UTF-8 text' {
    [IO.File]::ReadAllText("$H\.claude\settings.json", $Utf8).Contains("$emoji $viet")
}
Check 'statusLine equals contract value' { (JqCanon '.statusLine' "$H\.claude\settings.json") -ceq $ExpectedSL }
Check 'rewritten settings.json has no BOM' { -not (Has-Bom "$H\.claude\settings.json") }
Check 'rewritten settings.json has LF line endings' { -not ([IO.File]::ReadAllBytes("$H\.claude\settings.json") -contains 13) }
Check 'script replaced, byte-identical to repo script' { Same-Bytes "$H\.claude\statusline-command.sh" $RepoScript }
Check 'settings backup holds original bytes' {
    $b = @(Get-ChildItem -LiteralPath "$H\.claude" -Filter 'settings.json.bak.*')
    $b.Count -eq 1 -and (Same-Bytes $b[0].FullName "$Work\settings.orig")
}
Check 'script backup holds original' {
    $b = @(Get-ChildItem -LiteralPath "$H\.claude" -Filter 'statusline-command.sh.bak.*')
    $b.Count -eq 1 -and [IO.File]::ReadAllText($b[0].FullName) -ceq "echo old`n"
}

Write-Host '3. second install is a no-op'
$before = Snapshot $H
Install-Into $H
Check 'installer exits 0' { $rc -eq 0 }
Check 'same files, same content, same mtimes, no new backups' { (Snapshot $H) -ceq $before }

Write-Host '4. settings.json not a JSON object -> refuse, nothing touched'
foreach ($case in @(@('broken', '{"theme": "dark",'), @('array', '["not", "an", "object"]'))) {
    $H = New-Home "4$($case[0])"; $null = New-Item -ItemType Directory -Path "$H\.claude"
    [IO.File]::WriteAllText("$H\.claude\settings.json", $case[1], $Utf8)
    $before = Snapshot $H
    Install-Into $H
    Check "$($case[0]): fails non-zero" { $rc -ne 0 }
    Check "$($case[0]): message names settings.json" { $out -match 'not a valid JSON object' }
    Check "$($case[0]): nothing changed or created" { (Snapshot $H) -ceq $before }
}

Write-Host '5. jq missing -> install hint, nothing touched'
$noJq = ($env:PATH.Split(';') | Where-Object { $_ -and -not (Find-OnPath $_ 'jq') }) -join ';'
Check 'no jq on the jq-less PATH (precondition)' { -not (Find-OnPath $noJq 'jq') }
$H = New-Home 5a
Install-Into $H @{ PATH = $noJq }
Check 'fails non-zero' { $rc -ne 0 }
Check 'message names winget install jqlang.jq' { $out.Contains('winget install jqlang.jq') }
Check 'empty USERPROFILE: nothing created' { Is-Empty $H }
$H = New-Home 5b; $null = New-Item -ItemType Directory -Path "$H\.claude"
[IO.File]::WriteAllText("$H\.claude\settings.json", '{"theme":"light"}', $Utf8)
[IO.File]::WriteAllText("$H\.claude\statusline-command.sh", "echo mine`n", $Utf8)
$before = Snapshot $H
Install-Into $H @{ PATH = $noJq }
Check 'fails non-zero (seeded)' { $rc -ne 0 }
Check 'seeded USERPROFILE: files unchanged' { (Snapshot $H) -ceq $before }

Write-Host '6. Git Bash missing -> install hint, nothing touched; a WSL-style bash.exe does not count'
# PATH: only the directory holding jq, plus a bash.exe that is not Git's (as WSL's
# C:\Windows\System32\bash.exe would be). Default Git locations point at empty dirs.
$fakeWsl = Join-Path $Work 'wsl-bin'; $null = New-Item -ItemType Directory -Path $fakeWsl
[IO.File]::WriteAllBytes((Join-Path $fakeWsl 'bash.exe'), [byte[]](0x4D, 0x5A))
$noGitPath = "$(Split-Path -Parent $Jq);$fakeWsl"
$empty = Join-Path $Work 'empty'; $null = New-Item -ItemType Directory -Path $empty
$noGit = @{ PATH = $noGitPath; ProgramFiles = $empty; ProgramW6432 = $empty; 'ProgramFiles(x86)' = $empty
            LOCALAPPDATA = $empty; CLAUDE_CODE_GIT_BASH_PATH = $null }
Check 'no git on the git-less PATH, jq and a bash.exe are (precondition)' {
    -not (Find-OnPath $noGitPath 'git') -and (Find-OnPath $noGitPath 'jq') -and (Find-OnPath $noGitPath 'bash')
}
$H = New-Home 6a
Install-Into $H $noGit
Check 'fails non-zero' { $rc -ne 0 }
Check 'message names winget install Git.Git' { $out.Contains('winget install Git.Git') }
Check 'empty USERPROFILE: nothing created' { Is-Empty $H }
$H = New-Home 6b; $null = New-Item -ItemType Directory -Path "$H\.claude"
[IO.File]::WriteAllText("$H\.claude\settings.json", '{"theme":"light"}', $Utf8)
$before = Snapshot $H
Install-Into $H $noGit
Check 'fails non-zero (seeded)' { $rc -ne 0 }
Check 'seeded USERPROFILE: files unchanged' { (Snapshot $H) -ceq $before }
$H = New-Home 6c
$bogus = $noGit.Clone(); $bogus.CLAUDE_CODE_GIT_BASH_PATH = Join-Path $Work 'no\such\bash.exe'
Install-Into $H $bogus
Check 'CLAUDE_CODE_GIT_BASH_PATH to a missing file: fails, nothing created' { $rc -ne 0 -and (Is-Empty $H) }
# The real Git bash via CLAUDE_CODE_GIT_BASH_PATH, with git itself off PATH.
$gitBash = Join-Path (Split-Path -Parent (Split-Path -Parent (Get-Command git.exe -CommandType Application | Select-Object -First 1).Path)) 'bin\bash.exe'
$H = New-Home 6d
$viaEnv = $noGit.Clone(); $viaEnv.CLAUDE_CODE_GIT_BASH_PATH = $gitBash
Install-Into $H $viaEnv
Check "CLAUDE_CODE_GIT_BASH_PATH to Git's bash.exe: installs" { $rc -eq 0 -and (Same-Bytes "$H\.claude\statusline-command.sh" $RepoScript) }

Write-Host '7. piped install (irm | iex) downloads from raw.githubusercontent.com'
$H = New-Home 7
Set-Content -LiteralPath $NetLog -Value $null
Install-Into $H @{ CSL_SERVE = $RepoScript } -Piped
Check 'installer exits 0' { $rc -eq 0 }
Check 'downloaded from main on raw.githubusercontent.com' { @(Get-Content -LiteralPath $NetLog) -ccontains "Invoke-WebRequest $RawScriptUrl" }
Check 'installed script byte-identical to repo script' { Same-Bytes "$H\.claude\statusline-command.sh" $RepoScript }
Check 'settings.json statusLine equals contract value' { (JqCanon '.statusLine' "$H\.claude\settings.json") -ceq $ExpectedSL }
Set-Content -LiteralPath $NetLog -Value $null

Write-Host '8. piped install failure throws instead of closing the PowerShell session'
$H = New-Home 8
Install-Into $H @{ PATH = $noJq } -Piped
Check 'fails non-zero' { $rc -ne 0 }
Check 'session still alive after the failure (no exit)' { $out.Contains('CSL-HOST-ALIVE') }
Check 'message names winget install jqlang.jq' { $out.Contains('winget install jqlang.jq') }
Check 'nothing created' { Is-Empty $H }
Check 'no download attempted' { -not (Get-Content -LiteralPath $NetLog) }

Write-Host '9. install.ps1 source'
Check 'ASCII only (5.1 reads BOM-less scripts in the ANSI code page)' { -not ([IO.File]::ReadAllBytes($Installer) | Where-Object { $_ -gt 127 }) }
Check 'parses without errors' {
    $errs = $null; $null = [Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$null, [ref]$errs); $errs.Count -eq 0
}

Write-Host 'guard: no network calls outside test 7'
Check 'Invoke-WebRequest/Invoke-RestMethod stubs never called' { -not (Get-Content -LiteralPath $NetLog) }

Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "$pass passed, $fail failed"
if ($fail -ne 0) { exit 1 }
exit 0
