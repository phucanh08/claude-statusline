# claude-statusline

A two-line status line for [Claude Code](https://claude.com/claude-code): context usage,
5-hour and weekly rate limits with per-cell progress bars, session cost, model and effort.

Based on [onury/claude-statusline](https://github.com/onury/claude-statusline) v2.3.2 (MIT),
with local additions described at the top of `statusline-command.sh`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/phucanh08/claude-statusline/main/install.sh | bash
```

Requires `jq` (and `curl` for the one-line install). The installer:

- writes `~/.claude/statusline-command.sh`;
- sets `statusLine` in `~/.claude/settings.json` to
  `{"type": "command", "command": "bash ~/.claude/statusline-command.sh"}`,
  keeping every other key;
- backs up any file it changes as `<file>.bak.<timestamp>`; re-running with nothing to
  change leaves everything untouched.

Restart Claude Code afterwards.

### From a local clone

```sh
git clone https://github.com/phucanh08/claude-statusline.git
cd claude-statusline
bash install.sh
```

Run from a file, the installer copies the `statusline-command.sh` next to it instead of
downloading.

### Windows (PowerShell)

In Windows PowerShell 5.1 or PowerShell 7:

```powershell
irm https://raw.githubusercontent.com/phucanh08/claude-statusline/main/install.ps1 | iex
```

(or `powershell -ExecutionPolicy Bypass -File install.ps1` from a clone). It does what
`install.sh` does, to `%USERPROFILE%\.claude`, and needs:

- **jq** — `winget install jqlang.jq`;
- **Git for Windows** — `winget install Git.Git`. Claude Code runs the status line through
  Git Bash, so the installer stops if it cannot find `<git root>\bin\bash.exe`
  (`install.ps1:27-51`). It looks at `CLAUDE_CODE_GIT_BASH_PATH` if set (Claude Code's own
  override; then only that file counts), else the Git that `git.exe` on `PATH` belongs to,
  else `Git` under Program Files or `%LOCALAPPDATA%\Programs`. A `bash.exe` on `PATH` alone
  does not count (`C:\Windows\System32\bash.exe` is WSL's). A Git installed by Scoop is
  **not** detected (its `git.exe` is a shim); set `CLAUDE_CODE_GIT_BASH_PATH` to its
  `bin\bash.exe`, e.g. `%USERPROFILE%\scoop\apps\git\current\bin\bash.exe`.

After installing jq or Git, open a new PowerShell window so `PATH` is refreshed. Under
`irm | iex` a failure throws an error and leaves your PowerShell window open.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/phucanh08/claude-statusline/main/uninstall.sh | bash
```

(or `bash uninstall.sh` from a clone). It only removes what the installer added:

- `statusLine` is removed from `~/.claude/settings.json` only if it is exactly the value
  above; any other `statusLine` is kept. All other keys are kept.
- `~/.claude/statusline-command.sh` is removed only if it is identical to the released
  script; a locally modified copy is kept.
- `*.bak.*` backups are never restored or deleted — their paths are printed so you can
  restore one by hand.

Running it when nothing is installed does nothing.

On Windows, from PowerShell:

```powershell
irm https://raw.githubusercontent.com/phucanh08/claude-statusline/main/uninstall.ps1 | iex
```

(or `powershell -ExecutionPolicy Bypass -File uninstall.ps1` from a clone). Same rules as
above, applied to `%USERPROFILE%\.claude`; it needs jq but not Git Bash. If
`settings.json` is not a JSON object, both uninstallers stop without changing anything.

## Options

Flags such as `--width`, `--sections`, `--time` and `--layout` are passed in the
`statusLine.command` string in `settings.json`; see the header of
`statusline-command.sh` for the full list.

## Platform support

| Platform | Status line | Install / uninstall | Usage refresh credential |
|---|---|---|---|
| macOS | yes | `curl … \| bash` | Keychain, else `~/.claude/.credentials.json` |
| Linux (glibc or busybox/musl) | yes | `curl … \| bash` (needs `bash`) | `~/.claude/.credentials.json` |
| Windows, WSL | yes (it is Linux) | run inside WSL | the WSL `~/.claude/.credentials.json` |
| Windows, native with Git for Windows | yes, via Git Bash | `irm … \| iex` in PowerShell, or the `curl` one-liner in Git Bash | `%USERPROFILE%\.claude\.credentials.json` |
| Windows, native without Git Bash | no | `install.ps1` stops and prints `winget install Git.Git`; `uninstall.ps1` works | — |

Notes:

- **Windows needs Git Bash.** Claude Code runs status line commands through Git Bash
  when Git for Windows is installed and through PowerShell otherwise; the
  `bash ~/.claude/statusline-command.sh` command the installer sets needs Git Bash.
  `~` is your Windows home, the same `%USERPROFILE%\.claude` Claude Code uses.
- **jq** is required everywhere; on Windows install it with `winget install jqlang.jq`.
  A native `jq.exe` writes CRLF line endings; the script detects that under Git Bash and
  passes it `-b` (`statusline-command.sh:89-91`), which needs jq 1.7 or newer.
- **Dates and file ages** use `date -r`/`stat -f` on macOS and `date -d @`/`stat -c` on
  GNU, busybox and Git Bash (`statusline-command.sh:159-163`, `:314-316`), so reset
  times and the cache age are the same on every platform. On macOS the output is
  byte-identical to earlier releases (checked by the test suite).
- **Locale:** the script sets `LC_ALL=en_US.UTF-8` and falls back to `C.UTF-8` where
  that locale is not installed, so column widths count characters, not bytes
  (`statusline-command.sh:84-87`).
- **`CLAUDE_CONFIG_DIR`:** the install and uninstall scripts always use `~/.claude`. The
  usage refresh honors `CLAUDE_CONFIG_DIR` when looking for the credentials file; on
  macOS it still reads only the default Keychain entry (see below).

## Privacy / network

The status line itself only reads the JSON Claude Code pipes into it — with one exception.
Model-scoped quotas (e.g. a Fable weekly limit) are not in that payload, so the script keeps
a small usage cache and refreshes it in the background:

- **Cache:** `~/.cache/claude-statusline/usage.json` (`statusline-command.sh:156-157`). It
  is refreshed when missing or older than **90 seconds** (`:155`, `:195-197`); the script
  never waits on it — every render uses whatever is cached.
- **Credential — macOS:** the refresh first reads your Claude Code OAuth token from the
  Keychain with `security find-generic-password -s "Claude Code-credentials" -w`
  (`statusline-command.sh:172-177`). Only if that yields no token does it read the
  credentials file below (`:180-181`) — where Claude Code keeps your login when the
  Keychain rejects the write, e.g. when it is locked in an SSH session.
- **Credential — Linux, WSL, Windows (Git Bash):** the refresh reads
  `.claudeAiOauth.accessToken` from `~/.claude/.credentials.json`, or from
  `$CLAUDE_CONFIG_DIR/.credentials.json` when that variable is set
  (`statusline-command.sh:180-181`) — the file Claude Code itself keeps its login in on
  those systems. It never writes to that file.
- **`CLAUDE_CONFIG_DIR` on macOS:** Claude Code keys its Keychain entry to that directory,
  but its docs do not say under what name, so the script still looks up only
  `Claude Code-credentials` (`:175`). With the variable set, a login that lives in the
  Keychain may therefore not be found; a login in `$CLAUDE_CONFIG_DIR/.credentials.json`
  is.
- **Token handling (all platforms):** the token is only held in the background job; it is
  not written to disk (`statusline-command.sh:170-193`). It is passed to `curl` as a
  command-line argument, so it is visible in the process list for the few seconds the
  request runs.
- **Request:** `curl -s -m 5` (5-second timeout) with that token as a Bearer header to
  `https://api.anthropic.com/api/oauth/usage` — the same usage data `/usage` shows
  (`statusline-command.sh:184-185`). The response replaces the cache only if it is valid
  JSON with a `limits` array; on any error the old cache is kept (`:186-190`). At most one
  refresh runs at a time (lock dir `~/.cache/claude-statusline/refresh.lock`, `:166-169`;
  a lock older than 30 seconds is treated as left over and cleared).
- **No token:** if neither source has a token — on macOS no Keychain entry (or no
  `security`) and no usable credentials file, elsewhere no credentials file or no
  `accessToken` in it — no request is made (`statusline-command.sh:182`). The cache
  directory is still created, and the quota fields fall back to what the payload provides.

**Opting out:** the script has no option for this. Leaving `fable` out of `--sections` hides
the bar but does **not** stop the refresh. To avoid the credential read and the request you
would have to edit the script yourself.

## Tests

```sh
sh test/run.sh
```

Tests cover install.sh, uninstall.sh and the status line script. All tests run against a
throwaway `HOME` under `$TMPDIR`; `curl`, `security` (and, for the credential tests,
`uname` and a logging `jq`) are stubbed so nothing touches the network, the Keychain or your real
`~/.claude`. Status line output is compared byte for byte against `test/golden/*.out`,
recorded on macOS from the `09f538a` release; on macOS the suite also renders that
release from git history (so a clone needs full history) and compares live.

The suite runs in GitHub Actions on Ubuntu, macOS and Windows (Git Bash), the latter
once with `core.autocrlf=false` and once with `true` —
`.github/workflows/test.yml`. `.gitattributes` keeps every file LF on checkout, so a
Windows clone with Git's default `core.autocrlf=true` still passes.

`install.ps1` and `uninstall.ps1` have their own suite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test/run.ps1   # or pwsh
```

Each run is a child PowerShell with a throwaway `USERPROFILE` and `Invoke-WebRequest`
stubbed, so it never touches the network or your real `.claude`. It needs jq and Git for
Windows. CI runs it on Windows PowerShell 5.1 and PowerShell 7, plus a mutation job: it
breaks a copy of `install.ps1` or `uninstall.ps1` one way at a time (e.g. removing any
`statusLine`, deleting backups, writing a BOM, `exit` under `irm | iex`) and requires the
tests named for that breakage to fail.

## License

MIT — see [LICENSE](LICENSE).
