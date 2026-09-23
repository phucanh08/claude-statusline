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

## Options

Flags such as `--width`, `--sections`, `--time` and `--layout` are passed in the
`statusLine.command` string in `settings.json`; see the header of
`statusline-command.sh` for the full list.

## Privacy / network

The status line itself only reads the JSON Claude Code pipes into it — with one exception.
Model-scoped quotas (e.g. a Fable weekly limit) are not in that payload, so the script keeps
a small usage cache and refreshes it in the background:

- **Cache:** `~/.cache/claude-statusline/usage.json`. It is refreshed when missing or older
  than **90 seconds**; the script never waits on it — every render uses whatever is cached.
- **Credential:** the refresh reads your Claude Code OAuth token from the macOS Keychain with
  `security find-generic-password -s "Claude Code-credentials" -w`. The token is only held
  in that background job; it is not written to disk.
- **Request:** `curl -s -m 5` (5-second timeout) with that token as a Bearer header to
  `https://api.anthropic.com/api/oauth/usage` — the same usage data `/usage` shows. The
  response replaces the cache only if it is valid JSON with a `limits` array; on any error
  the old cache is kept. At most one refresh runs at a time (lock dir
  `~/.cache/claude-statusline/refresh.lock`).
- **Non-macOS / no token:** if the `security` command is missing or the Keychain has no
  Claude Code token, no request is made. The cache directory is still created, and the
  quota fields fall back to what the payload provides.

**Opting out:** the script has no option for this. Leaving `fable` out of `--sections` hides
the bar but does **not** stop the refresh. To avoid the Keychain read and the request you
would have to edit the script yourself.

## Tests

```sh
sh test/run.sh
```

Tests cover both install.sh and uninstall.sh. All tests run against a throwaway `HOME` under `$TMPDIR`; `curl` and `security` are
stubbed so nothing touches the network or the Keychain. The reference copy compared
against is your own `~/.claude/statusline-command.sh`, which is only read.

## License

MIT — see [LICENSE](LICENSE).
