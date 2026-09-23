#!/usr/bin/env bash
# Install the Claude Code status line into ~/.claude and point settings.json at it.
#
#   curl -fsSL https://raw.githubusercontent.com/phucanh08/claude-statusline/main/install.sh | bash
#
# Run from a local clone (`bash install.sh`) it copies the script sitting next to it
# instead of downloading. Existing files are backed up as <file>.bak.<timestamp>
# before being changed; unchanged files are left alone, so re-running is a no-op.

# Everything lives in main() so a truncated `curl | bash` download never runs half a script.
main() {
    set -eu

    RAW_URL="https://raw.githubusercontent.com/phucanh08/claude-statusline/main"
    CLAUDE_DIR="$HOME/.claude"
    SCRIPT="$CLAUDE_DIR/statusline-command.sh"
    SETTINGS="$CLAUDE_DIR/settings.json"
    STATUS_LINE='{"type":"command","command":"bash ~/.claude/statusline-command.sh"}'
    STAMP=$(date +%Y%m%d%H%M%S)

    if ! command -v jq >/dev/null 2>&1; then
        echo "claude-statusline: jq is required but was not found in PATH." >&2
        echo "Install it first (e.g. 'brew install jq' or 'sudo apt install jq'), then re-run." >&2
        exit 1
    fi

    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline.XXXXXX")
    trap 'rm -rf "$tmp_dir"' EXIT

    # ---- fetch the script: local clone if we were run from a file, else download ----
    src_dir=""
    case "${BASH_SOURCE[0]:-}" in
        */install.sh|install.sh) src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) ;;
    esac
    if [ -n "$src_dir" ] && [ -f "$src_dir/statusline-command.sh" ]; then
        cp "$src_dir/statusline-command.sh" "$tmp_dir/statusline-command.sh"
    else
        if ! command -v curl >/dev/null 2>&1; then
            echo "claude-statusline: curl is required to download the script." >&2
            exit 1
        fi
        curl -fsSL "$RAW_URL/statusline-command.sh" -o "$tmp_dir/statusline-command.sh"
    fi

    # ---- validate settings.json before touching anything ----
    if [ -f "$SETTINGS" ]; then
        if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
            echo "claude-statusline: $SETTINGS is not a valid JSON object; fix it and re-run." >&2
            exit 1
        fi
    fi

    mkdir -p "$CLAUDE_DIR"

    # ---- install the script ----
    if [ -f "$SCRIPT" ] && cmp -s "$tmp_dir/statusline-command.sh" "$SCRIPT"; then
        echo "Script already up to date: $SCRIPT"
    else
        if [ -f "$SCRIPT" ]; then
            cp -p "$SCRIPT" "$SCRIPT.bak.$STAMP"
            echo "Backed up $SCRIPT -> $SCRIPT.bak.$STAMP"
        fi
        cat "$tmp_dir/statusline-command.sh" > "$SCRIPT"
        echo "Installed $SCRIPT"
    fi

    # ---- point settings.json at it, keeping every other key ----
    if [ -f "$SETTINGS" ]; then
        if jq -e --argjson sl "$STATUS_LINE" '.statusLine == $sl' "$SETTINGS" >/dev/null 2>&1; then
            echo "settings.json already configured: $SETTINGS"
        else
            jq --argjson sl "$STATUS_LINE" '.statusLine = $sl' "$SETTINGS" > "$tmp_dir/settings.json"
            cp -p "$SETTINGS" "$SETTINGS.bak.$STAMP"
            echo "Backed up $SETTINGS -> $SETTINGS.bak.$STAMP"
            cat "$tmp_dir/settings.json" > "$SETTINGS"
            echo "Updated statusLine in $SETTINGS"
        fi
    else
        jq -n --argjson sl "$STATUS_LINE" '{statusLine: $sl}' > "$SETTINGS"
        echo "Created $SETTINGS"
    fi

    echo "Done. Restart Claude Code to see the new status line."
}

main
