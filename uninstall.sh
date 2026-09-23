#!/usr/bin/env bash
# Remove what install.sh added, and only that.
#
#   curl -fsSL https://raw.githubusercontent.com/phucanh08/claude-statusline/main/uninstall.sh | bash
#
# - statusLine is removed from ~/.claude/settings.json only if it is exactly the value
#   install.sh writes; every other key is kept.
# - ~/.claude/statusline-command.sh is removed only if it is byte-identical to this
#   repo's script (so local edits are never lost).
# - Backups (*.bak.*) are never restored or deleted; their paths are printed.
# Run from a local clone (`bash uninstall.sh`) it compares against the script next to it.

# Everything lives in main() so a truncated `curl | bash` download never runs half a script.
main() {
    set -eu

    RAW_URL="https://raw.githubusercontent.com/phucanh08/claude-statusline/main"
    CLAUDE_DIR="$HOME/.claude"
    SCRIPT="$CLAUDE_DIR/statusline-command.sh"
    SETTINGS="$CLAUDE_DIR/settings.json"
    STATUS_LINE='{"type":"command","command":"bash ~/.claude/statusline-command.sh"}'

    if ! command -v jq >/dev/null 2>&1; then
        echo "claude-statusline: jq is required but was not found in PATH." >&2
        echo "Install it first (e.g. 'brew install jq', 'sudo apt install jq' or 'winget install jqlang.jq'), then re-run." >&2
        exit 1
    fi

    if [ -f "$SETTINGS" ] && ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
        echo "claude-statusline: $SETTINGS is not a valid JSON object; fix it and re-run." >&2
        exit 1
    fi

    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline.XXXXXX")
    trap 'rm -rf "$tmp_dir"' EXIT

    # ---- script: remove only an unmodified copy ----
    if [ -f "$SCRIPT" ]; then
        # Reference copy: local clone if we were run from a file, else download.
        src_dir=""
        case "${BASH_SOURCE[0]:-}" in
            */uninstall.sh|uninstall.sh) src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) ;;
        esac
        if [ -n "$src_dir" ] && [ -f "$src_dir/statusline-command.sh" ]; then
            cp "$src_dir/statusline-command.sh" "$tmp_dir/statusline-command.sh"
        else
            if ! command -v curl >/dev/null 2>&1; then
                echo "claude-statusline: curl is required to download the reference script." >&2
                exit 1
            fi
            curl -fsSL "$RAW_URL/statusline-command.sh" -o "$tmp_dir/statusline-command.sh"
        fi
    fi

    # ---- settings.json: drop statusLine only if it is ours ----
    if [ -f "$SETTINGS" ] && jq -e 'has("statusLine")' "$SETTINGS" >/dev/null; then
        if jq -e --argjson sl "$STATUS_LINE" '.statusLine == $sl' "$SETTINGS" >/dev/null; then
            jq 'del(.statusLine)' "$SETTINGS" > "$tmp_dir/settings.json"
            cat "$tmp_dir/settings.json" > "$SETTINGS"
            echo "Removed statusLine from $SETTINGS"
        else
            echo "Kept statusLine in $SETTINGS: it is not the one install.sh sets."
        fi
    else
        echo "No statusLine in settings.json; nothing to remove."
    fi

    if [ -f "$SCRIPT" ]; then
        if cmp -s "$tmp_dir/statusline-command.sh" "$SCRIPT"; then
            rm -f "$SCRIPT"
            echo "Removed $SCRIPT"
        else
            echo "Kept $SCRIPT: it differs from the released script (local changes?)."
        fi
    else
        echo "No $SCRIPT; nothing to remove."
    fi

    backups=$(ls -1 "$SCRIPT".bak.* "$SETTINGS".bak.* 2>/dev/null || true)
    if [ -n "$backups" ]; then
        echo "Backups left in place (restore manually if you want them back):"
        printf '%s\n' "$backups" | sed 's/^/  /'
    fi

    echo "Done. Restart Claude Code to apply."
}

main
