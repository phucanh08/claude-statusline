#!/bin/sh
# Test runner for install.sh. Every test runs against a fake HOME under $TMPDIR;
# the real ~/.claude is only ever read (as the reference copy), never written.
#
#   sh test/run.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
REAL_SCRIPT="$HOME/.claude/statusline-command.sh"
EXPECTED_SL='{"type":"command","command":"bash ~/.claude/statusline-command.sh"}'
WORK=$(mktemp -d "${TMPDIR:-/tmp}/csl-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Stubs shadow curl/security so no test can reach the network or the Keychain.
# Any call is logged; the log must stay empty unless a test opts into the curl stub.
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
NET_LOG="$WORK/net.log"; : > "$NET_LOG"
for c in curl security; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$c" "$NET_LOG" > "$STUBS/$c"
    chmod +x "$STUBS/$c"
done
BASE_PATH="$STUBS:$PATH"

new_home() { h="$WORK/home.$1"; mkdir -p "$h"; echo "$h"; }
install_into() { HOME="$1" PATH="$BASE_PATH" bash "$REPO/install.sh" >"$WORK/out" 2>&1; }
# Content fingerprint of a directory tree: path + checksum of every file.
snapshot() { (cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }

[ -f "$REAL_SCRIPT" ] || { echo "reference script missing: $REAL_SCRIPT"; exit 1; }

echo "1. install from local checkout"
H=$(new_home 1)
install_into "$H"; rc=$?
check "installer exits 0" '[ "$rc" -eq 0 ]'
check "installed script == ~/.claude/statusline-command.sh" 'diff "$H/.claude/statusline-command.sh" "$REAL_SCRIPT" >/dev/null'
check "repo script == ~/.claude/statusline-command.sh" 'cmp -s "$REPO/statusline-command.sh" "$REAL_SCRIPT"'
check "fresh settings.json has statusLine" 'jq -e --argjson sl "$EXPECTED_SL" ".statusLine == \$sl" "$H/.claude/settings.json" >/dev/null'

echo "2. existing settings + script are preserved and backed up"
H=$(new_home 2); mkdir -p "$H/.claude"
cat > "$H/.claude/settings.json" <<'EOF'
{
  "theme": "dark",
  "model": "opus",
  "permissions": { "allow": ["Bash(ls:*)"], "deny": [] },
  "env": { "FOO": "bar" },
  "statusLine": { "type": "command", "command": "sh ~/old-statusline.sh" }
}
EOF
echo 'echo old' > "$H/.claude/statusline-command.sh"
cp "$H/.claude/settings.json" "$WORK/settings.orig"
install_into "$H"; rc=$?
check "installer exits 0" '[ "$rc" -eq 0 ]'
check "unrelated keys intact" '[ "$(jq -S "del(.statusLine)" "$H/.claude/settings.json")" = "$(jq -S "del(.statusLine)" "$WORK/settings.orig")" ]'
check "statusLine equals contract value" 'jq -e --argjson sl "$EXPECTED_SL" ".statusLine == \$sl" "$H/.claude/settings.json" >/dev/null'
check "script replaced" 'cmp -s "$H/.claude/statusline-command.sh" "$REAL_SCRIPT"'
check "settings backup holds original" 'cmp -s "$(ls "$H"/.claude/settings.json.bak.* | head -1)" "$WORK/settings.orig"'
check "script backup holds original" '[ "$(cat "$(ls "$H"/.claude/statusline-command.sh.bak.* | head -1)")" = "echo old" ]'

echo "3. second install is idempotent"
before=$(snapshot "$H")
install_into "$H"; rc=$?
after=$(snapshot "$H")
check "installer exits 0" '[ "$rc" -eq 0 ]'
check "same files, same content, no new backups" '[ "$before" = "$after" ]'

echo "4. repo script renders byte-identical to ~/.claude script"
H=$(new_home 4); mkdir -p "$H/.cache/claude-statusline" "$H/tmp" "$H/work"
# A fresh (mtime = now) usage cache keeps the script from starting its background refresh.
echo '{"limits":[]}' > "$H/.cache/claude-statusline/usage.json"
now=$(date +%s)
cat > "$WORK/payload.json" <<EOF
{
  "model": { "display_name": "Opus 5.5" },
  "effort": { "level": "high" },
  "workspace": { "current_dir": "$H/work" },
  "cost": { "total_cost_usd": 1.23 },
  "context_window": { "total_input_tokens": 45000, "total_output_tokens": 5000, "context_window_size": 200000 },
  "rate_limits": {
    "five_hour": { "used_percentage": 42, "resets_at": $((now + 3600)) },
    "seven_day": { "used_percentage": 17, "resets_at": $((now + 259200)) }
  }
}
EOF
render() { HOME="$H" TMPDIR="$H/tmp" COLUMNS=200 PATH="$BASE_PATH" bash "$1" < "$WORK/payload.json"; }
render "$REPO/statusline-command.sh" > "$WORK/render.repo"
render "$REAL_SCRIPT" > "$WORK/render.real"
check "output non-empty" '[ -s "$WORK/render.repo" ]'
check "outputs byte-identical" 'cmp -s "$WORK/render.repo" "$WORK/render.real"'

echo "5. jq missing -> clear error, nothing touched"
NOJQ="$WORK/nojq-bin"; mkdir -p "$NOJQ"
for c in bash sh date mktemp dirname cp cat mkdir cmp rm; do ln -s "$(command -v "$c")" "$NOJQ/$c"; done
H=$(new_home 5a)
HOME="$H" PATH="$NOJQ" "$NOJQ/bash" "$REPO/install.sh" >"$WORK/out" 2>&1; rc=$?
check "fails non-zero" '[ "$rc" -ne 0 ]'
check "message names jq" 'grep -q "jq is required" "$WORK/out"'
check "empty HOME: nothing created" '[ -z "$(ls -A "$H")" ]'
H=$(new_home 5b); mkdir -p "$H/.claude"
echo '{"theme":"light"}' > "$H/.claude/settings.json"
echo 'echo mine' > "$H/.claude/statusline-command.sh"
before=$(snapshot "$H")
HOME="$H" PATH="$NOJQ" "$NOJQ/bash" "$REPO/install.sh" >"$WORK/out" 2>&1; rc=$?
check "fails non-zero (seeded HOME)" '[ "$rc" -ne 0 ]'
check "seeded HOME: files unchanged" '[ "$before" = "$(snapshot "$H")" ]'

echo "6. piped install (curl | bash) downloads via curl"
# Only this test swaps in a curl stub that serves the repo file instead of the network.
FETCH="$WORK/fetch-bin"; mkdir -p "$FETCH"
cat > "$FETCH/curl" <<EOF
#!/bin/sh
echo "curl \$*" >> "$WORK/fetch.log"
while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
cp "$REPO/statusline-command.sh" "\$out"
EOF
chmod +x "$FETCH/curl"
H=$(new_home 6)
(cd "$WORK" && HOME="$H" PATH="$FETCH:$BASE_PATH" bash < "$REPO/install.sh" >"$WORK/out" 2>&1); rc=$?
check "installer exits 0" '[ "$rc" -eq 0 ]'
check "fetched from raw.githubusercontent.com" 'grep -q "raw.githubusercontent.com/phucanh08/claude-statusline/main/statusline-command.sh" "$WORK/fetch.log"'
check "installed script == ~/.claude/statusline-command.sh" 'cmp -s "$H/.claude/statusline-command.sh" "$REAL_SCRIPT"'

echo "7. syntax (shellcheck not installed: skipped)"
check "sh -n install.sh" 'sh -n "$REPO/install.sh"'
check "bash -n install.sh" 'bash -n "$REPO/install.sh"'

echo "guard: no network / Keychain calls"
check "curl/security stubs never called" '[ ! -s "$NET_LOG" ]'
[ -s "$NET_LOG" ] && cat "$NET_LOG"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
