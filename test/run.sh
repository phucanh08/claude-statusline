#!/bin/sh
# Test runner for install.sh, uninstall.sh and statusline-command.sh. Every test runs
# against a fake HOME under $TMPDIR; the real ~/.claude is never read or written.
# Runs on macOS, Linux (GNU or busybox) and Git Bash on Windows.
#
#   sh test/run.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO/statusline-command.sh"
GOLD="$REPO/test/golden"
# macOS no-regression reference: the last macOS-only release of the script.
BASE_REV=09f538a89b32b3c61364568fbafe74d4c231e711
EXPECTED_SL='{"type":"command","command":"bash ~/.claude/statusline-command.sh"}'
WORK=$(mktemp -d "${TMPDIR:-/tmp}/csl-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

case "$(uname -s)" in
    Darwin) OS=mac ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *) OS=linux ;;
esac
echo "platform: $OS ($(uname -s))"
REAL_JQ=$(command -v jq)   # before the Git Bash wrapper below shadows the name
# A native jq.exe under Git Bash ends lines with CRLF unless given -b.
if [ "$OS" = windows ]; then
    case "$(jq -n 1)" in *"$(printf '\r')"*) jq() { command jq -b "$@"; } ;; esac
fi

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

echo "1. install from local checkout"
H=$(new_home 1)
install_into "$H"; rc=$?
check "installer exits 0" '[ "$rc" -eq 0 ]'
check "installed script == repo script" 'cmp -s "$H/.claude/statusline-command.sh" "$SCRIPT"'
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
check "script replaced" 'cmp -s "$H/.claude/statusline-command.sh" "$SCRIPT"'
check "settings backup holds original" 'cmp -s "$(ls "$H"/.claude/settings.json.bak.* | head -1)" "$WORK/settings.orig"'
check "script backup holds original" '[ "$(cat "$(ls "$H"/.claude/statusline-command.sh.bak.* | head -1)")" = "echo old" ]'

echo "3. second install is idempotent"
before=$(snapshot "$H")
install_into "$H"; rc=$?
after=$(snapshot "$H")
check "installer exits 0" '[ "$rc" -eq 0 ]'
check "same files, same content, no new backups" '[ "$before" = "$after" ]'

ESC=$(printf '\033')
plain() { sed "s/${ESC}\[[0-9;]*m//g"; }
# Render a golden case: test/golden/NAME.json on stdin, optional NAME.args as flags,
# NAME.cache.json (else an empty one) as a fresh usage cache so no refresh starts.
# Fixed TZ (POSIX form, needs no tzdata) and far-future resets keep it deterministic.
golden() {
    g="$WORK/golden.home"; rm -rf "$g"; mkdir -p "$g/.cache/claude-statusline" "$g/tmp"
    if [ -f "$GOLD/$2.cache.json" ]; then cp "$GOLD/$2.cache.json" "$g/.cache/claude-statusline/usage.json"
    else echo '{"limits":[]}' > "$g/.cache/claude-statusline/usage.json"; fi
    args=""; [ -f "$GOLD/$2.args" ] && args=$(cat "$GOLD/$2.args")
    (cd "$g" && HOME="$g" TMPDIR="$g/tmp" TZ=JST-9 COLUMNS=200 PATH="$BASE_PATH" \
        bash "$1" $args < "$GOLD/$2.json")
}
CASES=$(cd "$GOLD" && ls *.json | grep -v '\.cache\.json$' | sed 's/\.json$//')

echo "4. golden: output matches the recorded macOS output (test/golden/*.out)"
for c in $CASES; do
    golden "$SCRIPT" "$c" > "$WORK/$c.new"
    check "$c: byte-identical to $c.out" 'cmp -s "$WORK/$c.new" "$GOLD/$c.out"'
done

echo "4b. reset time/date render from a fixed epoch in a fixed TZ (JST-9)"
golden "$SCRIPT" full | plain > "$WORK/full.txt"
check "5hr 2100-01-01T00:00Z -> @09:00" 'grep -q "5hr @09:00 " "$WORK/full.txt"'
check "week 2100-01-08T00:00Z -> @08/01" 'grep -q "Week @08/01 " "$WORK/full.txt"'
golden "$SCRIPT" cache | plain > "$WORK/cache.txt"
check "cache 5hr ISO 05:30:00.123+00:00 -> @14:30" 'grep -q "5hr @14:30 " "$WORK/cache.txt"'
check "cache week ISO 2100-01-09T00:00Z -> @09/01" 'grep -q "Week @09/01 " "$WORK/cache.txt"'
check "cache fable ISO -> @10/01" 'grep -q "Fable @10/01 " "$WORK/cache.txt"'

echo "4c. macOS: new script == $BASE_REV script, byte for byte"
if [ "$OS" = mac ]; then
    if git -C "$REPO" show "$BASE_REV:statusline-command.sh" > "$WORK/base.sh" 2>/dev/null; then
        for c in $CASES; do
            golden "$WORK/base.sh" "$c" > "$WORK/$c.base"
            check "$c: identical to base" 'cmp -s "$WORK/$c.new" "$WORK/$c.base"'
        done
        # Live payloads (resets relative to now; +30s keeps the minute from rolling
        # over between the two renders) in every --time mode.
        H=$(new_home 4c); mkdir -p "$H/.cache/claude-statusline" "$H/tmp"
        echo '{"limits":[]}' > "$H/.cache/claude-statusline/usage.json"
        now=$(date +%s)
        cat > "$WORK/live.json" <<EOF
{
  "model": { "display_name": "Opus 5.5" },
  "effort": { "level": "high" },
  "cost": { "total_cost_usd": 1.23 },
  "context_window": { "total_input_tokens": 45000, "total_output_tokens": 5000, "context_window_size": 200000 },
  "rate_limits": {
    "five_hour": { "used_percentage": 42, "resets_at": $((now + 3630)) },
    "seven_day": { "used_percentage": 17, "resets_at": $((now + 259230)) },
    "seven_day_fable": { "used_percentage": 63, "resets_at": $((now + 50430)) }
  }
}
EOF
        for mode in reset remaining elapsed; do
            live() { (cd "$H" && HOME="$H" TMPDIR="$H/tmp" COLUMNS=200 PATH="$BASE_PATH" \
                bash "$1" --time "$mode" < "$WORK/live.json"); }
            live "$SCRIPT" > "$WORK/live.new"; live "$WORK/base.sh" > "$WORK/live.base"
            check "live --time $mode: identical to base" '[ -s "$WORK/live.new" ] && cmp -s "$WORK/live.new" "$WORK/live.base"'
        done
    else
        bad "cannot read $BASE_REV from git history (CI needs fetch-depth: 0)"
    fi
else
    echo "  skip (the base script is macOS-only; 4. covers this OS against its output)"
fi

echo "5. jq missing -> clear error, nothing touched"
# A PATH with no jq. macOS/Linux: symlinks to just the tools the scripts need. Git Bash
# copies instead of linking (the copy can't find its DLLs), so there the PATH is the
# real one minus every directory that holds a jq.
BASH_BIN=$(command -v bash)
if [ "$OS" = windows ]; then
    NOJQ=$(printf '%s\n' "$PATH" | tr ':' '\n' | while read -r d; do
        [ -n "$d" ] && [ ! -e "$d/jq" ] && [ ! -e "$d/jq.exe" ] && printf '%s:' "$d"; done)
    NOJQ=${NOJQ%:}
else
    NOJQ="$WORK/nojq-bin"; mkdir -p "$NOJQ"
    for c in bash sh date mktemp dirname cp cat mkdir cmp rm; do ln -s "$(command -v "$c")" "$NOJQ/$c"; done
fi
check "no jq reachable on the jq-less PATH" '! PATH="$NOJQ" "$BASH_BIN" -c "command -v jq" >/dev/null 2>&1'
H=$(new_home 5a)
HOME="$H" PATH="$NOJQ" "$BASH_BIN" "$REPO/install.sh" >"$WORK/out" 2>&1; rc=$?
check "fails non-zero" '[ "$rc" -ne 0 ]'
check "message names jq" 'grep -q "jq is required" "$WORK/out"'
check "empty HOME: nothing created" '[ -z "$(ls -A "$H")" ]'
H=$(new_home 5b); mkdir -p "$H/.claude"
echo '{"theme":"light"}' > "$H/.claude/settings.json"
echo 'echo mine' > "$H/.claude/statusline-command.sh"
before=$(snapshot "$H")
HOME="$H" PATH="$NOJQ" "$BASH_BIN" "$REPO/install.sh" >"$WORK/out" 2>&1; rc=$?
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
check "installed script == repo script" 'cmp -s "$H/.claude/statusline-command.sh" "$SCRIPT"'

echo "7. syntax (shellcheck not installed: skipped)"
check "sh -n install.sh" 'sh -n "$REPO/install.sh"'
check "bash -n install.sh" 'bash -n "$REPO/install.sh"'
check "sh -n statusline-command.sh" 'sh -n "$SCRIPT"'
check "bash -n statusline-command.sh" 'bash -n "$SCRIPT"'

uninstall_from() { HOME="$1" PATH="$BASE_PATH" bash "$REPO/uninstall.sh" >"$WORK/out" 2>&1; }
seed_settings() {
    mkdir -p "$1/.claude"
    echo '{"theme":"dark","permissions":{"allow":["Bash(ls:*)"]},"env":{"FOO":"bar"}}' > "$1/.claude/settings.json"
}

echo "U7. install -> uninstall removes exactly what install added"
H=$(new_home u7); seed_settings "$H"
cp "$H/.claude/settings.json" "$WORK/settings.orig"
install_into "$H"
uninstall_from "$H"; rc=$?
check "uninstaller exits 0" '[ "$rc" -eq 0 ]'
check "statusLine key gone" '[ "$(jq "has(\"statusLine\")" "$H/.claude/settings.json")" = false ]'
check "other keys intact" '[ "$(jq -S . "$H/.claude/settings.json")" = "$(jq -S . "$WORK/settings.orig")" ]'
check "script removed" '[ ! -e "$H/.claude/statusline-command.sh" ]'
check "backup paths printed, backups kept" 'grep -q "settings.json.bak." "$WORK/out" && ls "$H"/.claude/settings.json.bak.* >/dev/null 2>&1'

echo "U8. user-modified script is kept"
H=$(new_home u8)
install_into "$H"
echo '# my tweak' >> "$H/.claude/statusline-command.sh"
cp "$H/.claude/statusline-command.sh" "$WORK/script.mod"
uninstall_from "$H"; rc=$?
check "uninstaller exits 0" '[ "$rc" -eq 0 ]'
check "script kept unchanged" 'cmp -s "$H/.claude/statusline-command.sh" "$WORK/script.mod"'
check "says it kept the script" 'grep -q "Kept .*statusline-command.sh" "$WORK/out"'

echo "U9. a different statusLine command is kept"
H=$(new_home u9); mkdir -p "$H/.claude"
echo '{"theme":"dark","statusLine":{"type":"command","command":"sh ~/.claude/statusline-command.sh --width 20"}}' > "$H/.claude/settings.json"
cp "$H/.claude/settings.json" "$WORK/settings.orig"
uninstall_from "$H"; rc=$?
check "uninstaller exits 0" '[ "$rc" -eq 0 ]'
check "settings.json unchanged" 'cmp -s "$H/.claude/settings.json" "$WORK/settings.orig"'
check "says it kept statusLine" 'grep -q "Kept statusLine" "$WORK/out"'

echo "U10. clean HOME and second run are no-ops"
H=$(new_home u10)
uninstall_from "$H"; rc=$?
check "clean HOME: exits 0" '[ "$rc" -eq 0 ]'
check "clean HOME: nothing created" '[ -z "$(ls -A "$H")" ]'
H=$(new_home u10b); seed_settings "$H"
install_into "$H"; uninstall_from "$H"
before=$(snapshot "$H")
uninstall_from "$H"; rc=$?
check "second run: exits 0" '[ "$rc" -eq 0 ]'
check "second run: nothing changed" '[ "$before" = "$(snapshot "$H")" ]'

echo "U11. jq missing -> clear error, nothing touched"
H=$(new_home u11)
install_into "$H"
before=$(snapshot "$H")
HOME="$H" PATH="$NOJQ" "$BASH_BIN" "$REPO/uninstall.sh" >"$WORK/out" 2>&1; rc=$?
check "fails non-zero" '[ "$rc" -ne 0 ]'
check "message names jq" 'grep -q "jq is required" "$WORK/out"'
check "files unchanged" '[ "$before" = "$(snapshot "$H")" ]'

echo "U-piped. piped uninstall (curl | bash) compares against the downloaded script"
H=$(new_home up)
install_into "$H"
: > "$WORK/fetch.log"
(cd "$WORK" && HOME="$H" PATH="$FETCH:$BASE_PATH" bash < "$REPO/uninstall.sh" >"$WORK/out" 2>&1); rc=$?
check "uninstaller exits 0" '[ "$rc" -eq 0 ]'
check "fetched from raw.githubusercontent.com" 'grep -q "raw.githubusercontent.com/phucanh08/claude-statusline/main/statusline-command.sh" "$WORK/fetch.log"'
check "script removed" '[ ! -e "$H/.claude/statusline-command.sh" ]'

echo "U-invalid. settings.json not a JSON object -> refuse, nothing touched"
H=$(new_home uinv)
install_into "$H"
echo '["not", "an", "object"]' > "$H/.claude/settings.json"
before=$(snapshot "$H")
uninstall_from "$H"; rc=$?
check "fails non-zero" '[ "$rc" -ne 0 ]'
check "message names settings.json" 'grep -q "not a valid JSON object" "$WORK/out"'
check "files unchanged (script kept too)" '[ "$before" = "$(snapshot "$H")" ]'

echo "U12. syntax (shellcheck not installed: skipped)"
check "sh -n uninstall.sh" 'sh -n "$REPO/uninstall.sh"'
check "bash -n uninstall.sh" 'bash -n "$REPO/uninstall.sh"'

# ---- usage refresh: which credential is read, and when a request is made ----
# Own stubs: `uname` fakes the OS, `security` serves $SEC_TOKEN from a fake Keychain,
# `curl` logs its arguments (outside the fake HOME) and writes $CURL_BODY to -o, `jq`
# logs its arguments to $JQ_LOG (shows whether the credentials file is read) and runs
# the real jq.
CRED="$WORK/cred-bin"; mkdir -p "$CRED"
CRED_LOG="$WORK/cred.log"
JQ_LOG="$WORK/jq.log"
cat > "$CRED/uname" <<'EOF'
#!/bin/sh
echo "$FAKE_UNAME"
EOF
cat > "$CRED/security" <<EOF
#!/bin/sh
echo "security \$*" >> "$CRED_LOG"
[ -n "\$SEC_TOKEN" ] && printf '{"claudeAiOauth":{"accessToken":"%s"}}' "\$SEC_TOKEN"
exit 0
EOF
cat > "$CRED/curl" <<EOF
#!/bin/sh
echo "curl \$*" >> "$CRED_LOG"
while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
printf '%s' "\$CURL_BODY" > "\$out"
EOF
cat > "$CRED/jq" <<EOF
#!/bin/sh
echo "jq \$*" >> "$JQ_LOG"
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$CRED/uname" "$CRED/security" "$CRED/curl" "$CRED/jq"
NEW_BODY='{"limits":[{"kind":"session","percent":7}]}'
# refresh HOME OS [VAR=value ...]: render once with a stale/missing cache, then wait
# for the background refresh to drop its lock.
refresh() {
    _h="$1"; _os="$2"; shift 2
    mkdir -p "$_h/tmp"; : > "$CRED_LOG"; : > "$JQ_LOG"
    echo '{"model":{"display_name":"Opus 5.5"}}' | (cd "$_h" && env HOME="$_h" TMPDIR="$_h/tmp" \
        FAKE_UNAME="$_os" SEC_TOKEN="" CURL_BODY="$NEW_BODY" CLAUDE_CONFIG_DIR= "$@" \
        PATH="$CRED:$BASE_PATH" bash "$SCRIPT") > /dev/null
    _i=0
    while [ -d "$_h/.cache/claude-statusline/refresh.lock" ] && [ "$_i" -lt 100 ]; do sleep 0.1; _i=$((_i + 1)); done
}
creds() { mkdir -p "$1"; printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r"}}' "$2" > "$1/.credentials.json"; }
# Files under HOME (the credentials file itself aside) that contain the token.
leaks() { grep -rl "$2" "$1" 2>/dev/null | grep -v '\.credentials\.json$'; }
CACHE=.cache/claude-statusline/usage.json

echo "C1. macOS: token from the Keychain (security), sent as Bearer, never stored"
H=$(new_home c1); creds "$H/.claude" tok-file-c1
refresh "$H" Darwin SEC_TOKEN=tok-mac-c1
check "security queried for Claude Code-credentials" 'grep -q "^security find-generic-password -s Claude Code-credentials -w" "$CRED_LOG"'
check "curl sent the Keychain token" 'grep -q "Authorization: Bearer tok-mac-c1" "$CRED_LOG"'
check "credentials file token not sent" '! grep -q tok-file-c1 "$CRED_LOG"'
check "credentials file not read" '! grep -q "credentials\.json" "$JQ_LOG"'
check "curl has 5s timeout" 'grep -q "^curl -s -m 5 " "$CRED_LOG"'
check "cache replaced by the response" '[ "$(cat "$H/$CACHE")" = "$NEW_BODY" ]'
check "token in no file under HOME" '[ -z "$(leaks "$H" tok-mac-c1)" ]'

echo "C2. macOS: no Keychain token -> ~/.claude/.credentials.json, never stored"
H=$(new_home c2); creds "$H/.claude" tok-file-c2
refresh "$H" Darwin
check "security queried first" '[ "$(head -1 "$CRED_LOG" | cut -d" " -f1)" = security ]'
check "credentials file read" 'grep -q "$H/.claude/.credentials.json" "$JQ_LOG"'
check "curl sent the file token" 'grep -q "Authorization: Bearer tok-file-c2" "$CRED_LOG"'
check "cache replaced by the response" '[ "$(cat "$H/$CACHE")" = "$NEW_BODY" ]'
check "token in no file under HOME" '[ -z "$(leaks "$H" tok-file-c2)" ]'

echo "C3. Linux: token from ~/.claude/.credentials.json, never stored"
H=$(new_home c3); creds "$H/.claude" tok-linux-c3
refresh "$H" Linux
check "security not called" '! grep -q "^security" "$CRED_LOG"'
check "curl sent the file token" 'grep -q "Authorization: Bearer tok-linux-c3" "$CRED_LOG"'
check "cache replaced by the response" '[ "$(cat "$H/$CACHE")" = "$NEW_BODY" ]'
check "token in no file under HOME" '[ -z "$(leaks "$H" tok-linux-c3)" ]'

echo "C4. Windows (Git Bash uname): same credentials file"
H=$(new_home c4); creds "$H/.claude" tok-win-c4
refresh "$H" MINGW64_NT-10.0-26100
check "curl sent the file token" 'grep -q "Authorization: Bearer tok-win-c4" "$CRED_LOG"'
check "token in no file under HOME" '[ -z "$(leaks "$H" tok-win-c4)" ]'

echo "C5. Linux: CLAUDE_CONFIG_DIR moves the credentials file"
H=$(new_home c5); creds "$H/.claude" tok-home-c5; creds "$H/cfg" tok-cfg-c5
refresh "$H" Linux CLAUDE_CONFIG_DIR="$H/cfg"
check "curl sent the CLAUDE_CONFIG_DIR token" 'grep -q "Authorization: Bearer tok-cfg-c5" "$CRED_LOG"'
check "~/.claude token not used" '! grep -q tok-home-c5 "$CRED_LOG"'

echo "C6. Linux: no credentials file / no token -> no request"
H=$(new_home c6a)
refresh "$H" Linux
check "missing file: curl never called" '[ ! -s "$CRED_LOG" ]'
H=$(new_home c6b); mkdir -p "$H/.claude"; echo '{"claudeAiOauth":{}}' > "$H/.claude/.credentials.json"
refresh "$H" Linux
check "file without accessToken: curl never called" '[ ! -s "$CRED_LOG" ]'
H=$(new_home c6c); mkdir -p "$H/.claude"; echo 'not json' > "$H/.claude/.credentials.json"
refresh "$H" Linux
check "unreadable file: curl never called" '[ ! -s "$CRED_LOG" ]'

echo "C7. cache age: fresh cache -> no refresh; stale cache + bad response -> old cache kept"
H=$(new_home c7); creds "$H/.claude" tok-c7; mkdir -p "$H/.cache/claude-statusline"
echo '{"limits":[]}' > "$H/$CACHE"
refresh "$H" Linux
check "fresh cache: curl never called" '[ ! -s "$CRED_LOG" ]'
touch -t 200001010000 "$H/$CACHE"
refresh "$H" Linux CURL_BODY='<html>error</html>'
check "stale cache: refresh ran" 'grep -q "Authorization: Bearer tok-c7" "$CRED_LOG"'
check "invalid response: old cache kept" '[ "$(cat "$H/$CACHE")" = "{\"limits\":[]}" ]'
check "no temp file left" '[ -z "$(ls "$H/.cache/claude-statusline" | grep -v "^usage.json$")" ]'

echo "C8. lock: a live lock blocks a second refresher; a lock older than 30s is cleared"
H=$(new_home c8); creds "$H/.claude" tok-c8; mkdir -p "$H/.cache/claude-statusline/refresh.lock"
: > "$CRED_LOG"
echo '{"model":{"display_name":"Opus 5.5"}}' | (cd "$H" && HOME="$H" TMPDIR="$H" FAKE_UNAME=Linux \
    CURL_BODY="$NEW_BODY" PATH="$CRED:$BASE_PATH" bash "$SCRIPT") > /dev/null
sleep 1
check "fresh lock: curl never called" '[ ! -s "$CRED_LOG" ]'
touch -t 200001010000 "$H/.cache/claude-statusline/refresh.lock"
refresh "$H" Linux
check "stale lock: cleared and refresh ran" 'grep -q "Authorization: Bearer tok-c8" "$CRED_LOG" && [ ! -d "$H/.cache/claude-statusline/refresh.lock" ]'

echo "C9. macOS: no Keychain token, no credentials file / no token -> no request"
H=$(new_home c9a)
refresh "$H" Darwin
check "security queried" 'grep -q "^security " "$CRED_LOG"'
check "missing file: curl never called" '! grep -q "^curl" "$CRED_LOG"'
check "no cache written" '[ ! -e "$H/$CACHE" ]'
H=$(new_home c9b); mkdir -p "$H/.claude"; echo '{"claudeAiOauth":{}}' > "$H/.claude/.credentials.json"
refresh "$H" Darwin
check "file without accessToken: curl never called" '! grep -q "^curl" "$CRED_LOG"'

echo "C10. macOS: CLAUDE_CONFIG_DIR moves the fallback credentials file"
H=$(new_home c10); creds "$H/.claude" tok-home-c10; creds "$H/cfg" tok-cfg-c10
refresh "$H" Darwin CLAUDE_CONFIG_DIR="$H/cfg"
check "curl sent the CLAUDE_CONFIG_DIR token" 'grep -q "Authorization: Bearer tok-cfg-c10" "$CRED_LOG"'
check "~/.claude token not used" '! grep -q tok-home-c10 "$CRED_LOG"'
check "token in no file under HOME" '[ -z "$(leaks "$H" tok-cfg-c10)" ]'

echo "guard: no network / Keychain calls"
check "curl/security stubs never called" '[ ! -s "$NET_LOG" ]'
[ -s "$NET_LOG" ] && cat "$NET_LOG"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
