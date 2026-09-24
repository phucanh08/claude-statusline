# Test runner for install.ps1 and uninstall.ps1. Every run is a child process of the same
# PowerShell (5.1 or 7) against a fake USERPROFILE/HOME under the temp dir, with
# Invoke-WebRequest stubbed: the real ~\.claude and the network are never touched.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\run.ps1
#   pwsh -NoProfile -File test/run.ps1
#
# -Installer / -Uninstaller run the suite against other copies of install.ps1 / uninstall.ps1
# (they need statusline-command.sh next to them); CI uses them to check that broken
# scripts fail.
# Keep this file ASCII (see install.ps1).

param([string]$Installer, [string]$Uninstaller)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Installer) { $Installer = Join-Path $Repo 'install.ps1' }
$Installer = (Resolve-Path -LiteralPath $Installer).Path
if (-not $Uninstaller) { $Uninstaller = Join-Path $Repo 'uninstall.ps1' }
$Uninstaller = (Resolve-Path -LiteralPath $Uninstaller).Path
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
# The PowerShell host itself writes under USERPROFILE (caches, profile data); the top-level
# entries it creates in an empty home are measured once below and left out of the checks.
$script:HostEntries = @()
function Owned-Items([string]$Dir) {
    @(Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $script:HostEntries -notcontains $_.Name })
}
# Path of every directory, plus SHA-256 and mtime of every file, under a directory.
function Snapshot([string]$Dir) {
    $items = @(Owned-Items $Dir | ForEach-Object { $_; if ($_.PSIsContainer) { Get-ChildItem -LiteralPath $_.FullName -Recurse -Force } })
    ($items | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($Dir.Length)
        if ($_.PSIsContainer) { "$rel/" } else {
            $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($_.FullName)))
            "$rel $sha $($_.LastWriteTimeUtc.Ticks)"
        }
    }) -join "`n"
}
function Same-Bytes([string]$A, [string]$B) {
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($A)) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($B))
}
function Has-Bom([string]$File) {
    $b = [IO.File]::ReadAllBytes($File); $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
}
function Is-Empty([string]$Dir) {
    $left = Owned-Items $Dir
    if ($left.Count) { Write-Host "       (found: $(($left | ForEach-Object { $_.Name }) -join ', '))" }
    $left.Count -eq 0
}
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
# The console runs in code page 437, as a stock US/Western Windows console does, so output
# decoded in the console code page instead of UTF-8 shows up.
$ChildBody = @'
try { [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437) } catch { }
Write-Output "CSL-CODEPAGE $([Console]::OutputEncoding.CodePage)"
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
Write-Host "uninstaller: $Uninstaller"
Write-Host "jq: $Jq"

Write-Host '0. what the bare PowerShell host writes under USERPROFILE (ignored below)'
$noop = Join-Path $Work 'noop.ps1'; [IO.File]::WriteAllText($noop, "exit 0`n")
$ctrl = New-Home control
Install-Into $ctrl @{ CSL_INSTALLER = $noop }; Install-Into $ctrl @{ CSL_INSTALLER = $noop }
$script:HostEntries = @(Get-ChildItem -LiteralPath $ctrl -Force | ForEach-Object { $_.Name })
Write-Host "       host entries: $(if ($HostEntries.Count) { $HostEntries -join ', ' } else { '(none)' })"
Check 'the host never creates .claude (precondition)' { $HostEntries -notcontains '.claude' }
Check 'child console runs in code page 437 (precondition)' { $out.Contains('CSL-CODEPAGE 437') }

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
$log7 = Join-Path $Work 'net7.log'; $null = New-Item -ItemType File -Path $log7
Install-Into $H @{ CSL_SERVE = $RepoScript; CSL_NET_LOG = $log7 } -Piped
Check 'installer exits 0' { $rc -eq 0 }
Check 'downloaded from main on raw.githubusercontent.com' { @(Get-Content -LiteralPath $log7) -ccontains "Invoke-WebRequest $RawScriptUrl" }
Check 'installed script byte-identical to repo script' { Same-Bytes "$H\.claude\statusline-command.sh" $RepoScript }
Check 'settings.json statusLine equals contract value' { (JqCanon '.statusLine' "$H\.claude\settings.json") -ceq $ExpectedSL }

Write-Host '8. piped install failure throws instead of closing the PowerShell session'
$H = New-Home 8
$log8 = Join-Path $Work 'net8.log'; $null = New-Item -ItemType File -Path $log8
Install-Into $H @{ PATH = $noJq; CSL_NET_LOG = $log8 } -Piped
Check 'fails non-zero' { $rc -ne 0 }
Check 'session still alive after the failure (no exit)' { $out.Contains('CSL-HOST-ALIVE') }
Check 'message names winget install jqlang.jq' { $out.Contains('winget install jqlang.jq') }
Check 'nothing created' { Is-Empty $H }
Check 'no download attempted' { -not (Get-Content -LiteralPath $log8) }

Write-Host '9. install.ps1 source'
Check 'ASCII only (5.1 reads BOM-less scripts in the ANSI code page)' { -not ([IO.File]::ReadAllBytes($Installer) | Where-Object { $_ -gt 127 }) }
Check 'parses without errors' {
    $errs = $null; $null = [Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$null, [ref]$errs); $errs.Count -eq 0
}

# ---- uninstall.ps1 ----
function Uninstall-From([string]$H, [hashtable]$Overrides = @{}, [switch]$Piped) {
    $o = $Overrides.Clone(); $o.CSL_INSTALLER = $Uninstaller
    Install-Into $H $o -Piped:$Piped
}
# Name, SHA-256 and mtime of every backup in $H\.claude.
function Backup-Snapshot([string]$H) {
    (@(Get-ChildItem -LiteralPath "$H\.claude" -Filter '*.bak.*' -Force | Sort-Object Name) | ForEach-Object {
        $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($_.FullName)))
        "$($_.Name) $sha $($_.LastWriteTimeUtc.Ticks)"
    }) -join "`n"
}
function Has-StatusLine([string]$File) { (JqCanon 'keys' $File).Contains('"statusLine"') }
function Seed-Installed([string]$H) {
    Install-Into $H
    if ($rc -ne 0) { Write-Host "       (install failed: $out)" }
}
# What the installers leave in an empty home, written directly (after U1) so that a broken
# installer in the install mutations cannot break the uninstall tests' setup.
$SeedSettings = @'
{
  "theme": "dark",
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
'@
function Seed-Files([string]$H) {
    $null = New-Item -ItemType Directory -Force -Path "$H\.claude"
    Copy-Item -LiteralPath $RepoScript -Destination "$H\.claude\statusline-command.sh"
    [IO.File]::WriteAllText("$H\.claude\settings.json", $SeedSettings.Replace("`r`n", "`n") + "`n", $Utf8)
}

Write-Host 'U1. install -> uninstall removes exactly what install added'
$H = New-Home u1; $null = New-Item -ItemType Directory -Path "$H\.claude"
[IO.File]::WriteAllText("$H\.claude\settings.json", $fixture.Replace("`r`n", "`n"), $Utf8)
[IO.File]::WriteAllText("$H\.claude\statusline-command.sh", "echo old`n", $Utf8)
Copy-Item -LiteralPath "$H\.claude\settings.json" -Destination "$Work\settings.u1"
Seed-Installed $H
$bakBefore = Backup-Snapshot $H
$bakNames = @(Get-ChildItem -LiteralPath "$H\.claude" -Filter '*.bak.*' | ForEach-Object { $_.Name })
Uninstall-From $H
Check 'U1 uninstaller exits 0' { $rc -eq 0 }
Check 'U1 statusLine removed' { -not (Has-StatusLine "$H\.claude\settings.json") }
Check 'U1 every other key keeps its value (nested, 1-element arrays, unicode, numbers, bool, null)' {
    (JqCanon 'del(.statusLine)' "$H\.claude\settings.json") -ceq (JqCanon 'del(.statusLine)' "$Work\settings.u1")
}
Check 'U1 unicode written as UTF-8 text' { [IO.File]::ReadAllText("$H\.claude\settings.json", $Utf8).Contains("$emoji $viet") }
Check 'U1 settings.json has no BOM' { -not (Has-Bom "$H\.claude\settings.json") }
Check 'U1 settings.json has LF line endings' { -not ([IO.File]::ReadAllBytes("$H\.claude\settings.json") -contains 13) }
Check 'U1 script removed' { -not (Test-Path -LiteralPath "$H\.claude\statusline-command.sh") }
Check 'U1 two backups existed (precondition)' { $bakNames.Count -eq 2 }
Check 'U1 only settings.json and the backups are left' {
    $left = @(Get-ChildItem -LiteralPath "$H\.claude" -Force | ForEach-Object { $_.Name } | Sort-Object)
    ($left -join ',') -ceq ((@('settings.json') + $bakNames | Sort-Object) -join ',')
}
Check 'U1 backups untouched' { (Backup-Snapshot $H) -ceq $bakBefore }
Check 'U1 backup paths printed' { -not @($bakNames | Where-Object { -not $out.Contains(".claude\$_") }).Count }

Write-Host 'U2. a statusLine that is not the installer value is kept'
foreach ($case in @(
        @('foreign', '{"theme":"dark","statusLine":{"type":"command","command":"sh ~/.claude/statusline-command.sh --width 20"}}'),
        @('near-miss', '{"theme":"dark","statusLine":{"type":"command","command":"bash ~/.claude/statusline-command.sh","padding":0}}'))) {
    $H = New-Home "u2$($case[0])"; $null = New-Item -ItemType Directory -Path "$H\.claude"
    [IO.File]::WriteAllText("$H\.claude\settings.json", $case[1], $Utf8)
    $before = Snapshot $H
    Uninstall-From $H
    Check "U2 $($case[0]): uninstaller exits 0" { $rc -eq 0 }
    Check "U2 $($case[0]): settings.json unchanged" { (Snapshot $H) -ceq $before }
    Check "U2 $($case[0]): says it kept statusLine" { $out.Contains('Kept statusLine') }
}

Write-Host 'U3. a modified script is kept'
$H = New-Home u3
Seed-Files $H
[IO.File]::AppendAllText("$H\.claude\statusline-command.sh", "# my tweak`n")
Copy-Item -LiteralPath "$H\.claude\statusline-command.sh" -Destination "$Work\script.u3"
Uninstall-From $H
Check 'U3 uninstaller exits 0' { $rc -eq 0 }
Check 'U3 modified script kept unchanged' { Same-Bytes "$H\.claude\statusline-command.sh" "$Work\script.u3" }
Check 'U3 says it kept the script' { $out -match 'Kept .*statusline-command\.sh' }
Check 'U3 statusLine still removed' { -not (Has-StatusLine "$H\.claude\settings.json") }

Write-Host 'U4. empty home and a second run are no-ops'
$H = New-Home u4
Uninstall-From $H
Check 'U4 empty home: exits 0' { $rc -eq 0 }
Check 'U4 empty home: nothing created' { Is-Empty $H }
$H = New-Home u4b
Seed-Files $H; Uninstall-From $H
$before = Snapshot $H
Uninstall-From $H
Check 'U4 second run: exits 0' { $rc -eq 0 }
Check 'U4 second run: nothing changed (content and mtimes)' { (Snapshot $H) -ceq $before }

Write-Host 'U5. settings.json not a JSON object -> refuse, nothing touched'
foreach ($case in @(@('broken', '{"theme": "dark",'), @('array', '["not", "an", "object"]'))) {
    $H = New-Home "u5$($case[0])"
    Seed-Files $H
    [IO.File]::WriteAllText("$H\.claude\settings.json", $case[1], $Utf8)
    $before = Snapshot $H
    Uninstall-From $H
    Check "U5 $($case[0]): fails non-zero" { $rc -ne 0 }
    Check "U5 $($case[0]): message names settings.json" { $out -match 'not a valid JSON object' }
    Check "U5 $($case[0]): nothing changed (script kept too)" { (Snapshot $H) -ceq $before }
}

Write-Host 'U6. jq missing -> install hint, nothing touched'
$H = New-Home u6
Seed-Files $H
$before = Snapshot $H
Uninstall-From $H @{ PATH = $noJq }
Check 'U6 fails non-zero' { $rc -ne 0 }
Check 'U6 message names winget install jqlang.jq' { $out.Contains('winget install jqlang.jq') }
Check 'U6 nothing changed' { (Snapshot $H) -ceq $before }

Write-Host 'U7. Git Bash is not needed to uninstall'
$H = New-Home u7
Seed-Files $H
Uninstall-From $H $noGit
Check 'U7 uninstaller exits 0 without Git Bash' { $rc -eq 0 }
Check 'U7 script removed' { -not (Test-Path -LiteralPath "$H\.claude\statusline-command.sh") }
Check 'U7 statusLine removed' { -not (Has-StatusLine "$H\.claude\settings.json") }

Write-Host 'U8. piped uninstall (irm | iex) compares against the script downloaded from main'
$H = New-Home u8
Seed-Files $H
$logU8 = Join-Path $Work 'net-u8.log'; $null = New-Item -ItemType File -Path $logU8
Uninstall-From $H @{ CSL_SERVE = $RepoScript; CSL_NET_LOG = $logU8 } -Piped
Check 'U8 uninstaller exits 0' { $rc -eq 0 }
Check 'U8 downloaded from main on raw.githubusercontent.com' { @(Get-Content -LiteralPath $logU8) -ccontains "Invoke-WebRequest $RawScriptUrl" }
Check 'U8 script removed' { -not (Test-Path -LiteralPath "$H\.claude\statusline-command.sh") }
Check 'U8 statusLine removed' { -not (Has-StatusLine "$H\.claude\settings.json") }
# main serves a newer script than the one installed: the installed copy no longer matches.
$H = New-Home u8b
Seed-Files $H
[IO.File]::WriteAllText("$Work\newer.sh", [IO.File]::ReadAllText($RepoScript) + "# newer`n", $Utf8)
Copy-Item -LiteralPath "$H\.claude\statusline-command.sh" -Destination "$Work\script.u8b"
$logU8b = Join-Path $Work 'net-u8b.log'; $null = New-Item -ItemType File -Path $logU8b
Uninstall-From $H @{ CSL_SERVE = "$Work\newer.sh"; CSL_NET_LOG = $logU8b } -Piped
Check 'U8b script that differs from the one on main is kept' { $rc -eq 0 -and (Same-Bytes "$H\.claude\statusline-command.sh" "$Work\script.u8b") }

Write-Host 'U9. piped uninstall failure throws instead of closing the PowerShell session'
$H = New-Home u9
Seed-Files $H
$before = Snapshot $H
$logU9 = Join-Path $Work 'net-u9.log'; $null = New-Item -ItemType File -Path $logU9
Uninstall-From $H @{ PATH = $noJq; CSL_NET_LOG = $logU9 } -Piped
Check 'U9 fails non-zero' { $rc -ne 0 }
Check 'U9 session still alive after the failure (no exit)' { $out.Contains('CSL-HOST-ALIVE') }
Check 'U9 message names winget install jqlang.jq' { $out.Contains('winget install jqlang.jq') }
Check 'U9 nothing changed' { (Snapshot $H) -ceq $before }
Check 'U9 no download attempted' { -not (Get-Content -LiteralPath $logU9) }

Write-Host 'U10. uninstall.ps1 source'
Check 'U10 ASCII only' { -not ([IO.File]::ReadAllBytes($Uninstaller) | Where-Object { $_ -gt 127 }) }
Check 'U10 parses without errors' {
    $errs = $null; $null = [Management.Automation.Language.Parser]::ParseFile($Uninstaller, [ref]$null, [ref]$errs); $errs.Count -eq 0
}

Write-Host 'guard: no network calls outside tests 7, 8, U8 and U9'
Check 'Invoke-WebRequest/Invoke-RestMethod stubs never called' { -not (Get-Content -LiteralPath $NetLog) }

Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "$pass passed, $fail failed"
if ($fail -ne 0) { exit 1 }
exit 0
