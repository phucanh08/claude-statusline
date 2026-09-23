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

## Tests

```sh
sh test/run.sh
```

Tests cover both install.sh and uninstall.sh. All tests run against a throwaway `HOME` under `$TMPDIR`; `curl` and `security` are
stubbed so nothing touches the network or the Keychain. The reference copy compared
against is your own `~/.claude/statusline-command.sh`, which is only read.

## License

MIT — see [LICENSE](LICENSE).
