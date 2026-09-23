#!/bin/sh
# Claude Code status line  —  based on onury/claude-statusline v2.3.2
# https://github.com/onury/claude-statusline
#
# Local additions on top of upstream (everything else is upstream behavior):
#   - `folder`       section: git repo root name (or cwd basename), label "Folder"
#   - `model_effort` section: model + effort merged in one column ("Opus 5.5 · High")
#   - `fable`        section: model-specific weekly quota bar, shown ONLY when the
#                    payload carries such a bucket in .rate_limits (see ASSUMPTION below)
#   - week reset date as dd/MM, xhigh shown as "XHigh", default width 20
#   - responsive drop order: fable, then branch, then from the right
#   - context total honors CLAUDE_CODE_AUTO_COMPACT_WINDOW / CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
#   Line 1 (dim):  context used/total %  |  5hr % reset  |  week % reset  [ | Branch | Model ]
#   Line 2:        per-cell green->red progress bar under each segment   [ | branch | model name ]
#
# Options (pass in settings.json, e.g.
#   "command": "sh ~/.claude/statusline-command.sh --width 20 --sections context,5hr,week,model"):
#   --width N           cells per bar / width of each line-1 field   (default 16)
#   --glyph CHAR        single-column bar cell character             (default ▘)
#   --sections LIST     comma list / order, any subset of            (default context,5hr,week,branch)
#                         context,5hr,week,cost,branch,model,effort  (`tokens` aliases
#                         `context`,
#                         `credit` aliases `cost`). Sections render in the order given.
#                         `cost` shows this session's estimated $ spend (no bar / %) —
#                         it is the only spend signal Claude Code exposes; there is no
#                         usage-credit balance in the status line payload.
#   --time MODE         what the 5hr/week time field shows           (default reset)
#                         reset      reset point          @23:00   @Jun25
#                         remaining  time left, ticks down -04:30   -6d23h
#                         elapsed    time used, ticks up   +00:30   +1d05h
#                       (@ = at, - = before reset / down, + = since start / up;
#                        week switches to the -HH:MM/+HH:MM clock under 1 day.
#                        Shows an animated ••• once the last-known reset has passed
#                        — data only refreshes on session activity, so an idle
#                        countdown awaits fresh data instead of freezing at -00:00.
#                        The dots advance one step per render at any
#                        refreshInterval; pair with a low one for a faster spin.)
#   --fill F            brightness 0..1 of filled cells              (default 0.80)
#   --track F           brightness 0..1 of the unfilled track        (default 0.22)
#   --responsive true|false  drop sections from the right to fit $COLUMNS (default true)
#   --layout expanded|compact  expanded = two lines w/ bars; compact = single line,
#                       no bars, branch/model show their value             (default expanded)
# In the expanded layout, pipe alignment is preserved for any settings: every non-last
# field is rendered to exactly --width columns (overlong text is clipped); only the last
# field may overflow, which never shifts a pipe.  The compact layout is a single line with
# no bars to align to, so its fields fit their content (one space before each %, no padding).

# ---- defaults ----
WIDTH=16
GLYPH="▮"           # tall, vertically centered (▘ sits at the top of the cell)
SECTIONS="context,5hr,week,fable,cost,model,effort"
TMODE="reset"         # reset | remaining | elapsed
TIMEFMT="%H:%M"       # 5hr reset clock (fixed)
DATEFMT="%d/%m"       # weekly reset date, no space so it fits the column (e.g. 25/09)
FH_LEN=18000          # 5-hour window length, seconds
WK_LEN=604800         # 7-day window length, seconds
FILL="0.80"
TRACK="0.22"
RESPONSIVE="true"
LAYOUT="expanded"     # expanded | compact

# ---- args ----
while [ $# -gt 0 ]; do
    case "$1" in
        --width)      WIDTH="$2";      shift 2 ;;
        --glyph)      GLYPH="$2";      shift 2 ;;
        --sections)   SECTIONS="$2";   shift 2 ;;
        --time)       TMODE="$2";      shift 2 ;;
        --fill)       FILL="$2";       shift 2 ;;
        --track)      TRACK="$2";      shift 2 ;;
        --responsive) RESPONSIVE="$2"; shift 2 ;;
        --layout)     LAYOUT="$2";     shift 2 ;;
        *)            shift ;;         # ignore unknown
    esac
done
case "$WIDTH" in *[!0-9]*|"") WIDTH=20 ;; esac   # guard: positive integer
[ "$WIDTH" -lt 1 ] && WIDTH=1
BARW="$WIDTH"
case "$TMODE" in reset|remaining|elapsed) ;; *) TMODE="reset" ;; esac   # guard
case "$LAYOUT" in expanded|compact) ;; *) LAYOUT="expanded" ;; esac      # guard

input=$(cat)
ESC=$(printf '\033')
export LC_ALL=en_US.UTF-8 2>/dev/null
# Minimal Linux images ship no en_US locale; C.UTF-8 keeps ${#var} counting
# characters (not bytes) there, so the columns still line up.
_u='·'; [ "${#_u}" -eq 1 ] || export LC_ALL=C.UTF-8 2>/dev/null
# A native jq.exe under Git Bash / Cygwin ends lines with CRLF unless given -b.
case "$OSTYPE" in msys*|cygwin*)
    case "$(jq -n 1 2>/dev/null)" in *"$(printf '\r')"*) jq() { command jq -b "$@"; } ;; esac ;;
esac

# ---- context window (tokens) ----
total_input=$(printf '%s' "$input"  | jq -r '.context_window.total_input_tokens // 0')
total_output=$(printf '%s' "$input" | jq -r '.context_window.total_output_tokens // 0')
ctx_size=$(printf '%s' "$input"     | jq -r '.context_window.context_window_size // 0')
case "$total_input"  in *[!0-9]*|"") total_input=0 ;; esac
case "$total_output" in *[!0-9]*|"") total_output=0 ;; esac
case "$ctx_size"     in *[!0-9]*|"") ctx_size=0 ;; esac
total=$((total_input + total_output))
# Show the autocompact limit as the denominator when the user configured one.
case "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" in *[!0-9]*|"") ;; *) ctx_size="$CLAUDE_CODE_AUTO_COMPACT_WINDOW" ;; esac
case "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" in *[!0-9]*|"") ;; *) ctx_size=$(( ctx_size * CLAUDE_AUTOCOMPACT_PCT_OVERRIDE / 100 )) ;; esac

if [ "$ctx_size" -gt 0 ]; then
    tok_pct=$(( (total * 100 + ctx_size / 2) / ctx_size ))
else
    tok_pct=0
fi

# ---- rate limits (absent for API-key sessions / before first response) ----
fh_pct=$(printf '%s' "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
fh_reset=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
wk_pct=$(printf '%s' "$input"   | jq -r '.rate_limits.seven_day.used_percentage // empty')
wk_reset=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
# Drop malformed values: a non-numeric % would print as a fake "0%", a
# non-epoch reset would print an invalid time.
num() { case "$1" in ""|*[!0-9.]*|*.*.*|.) ;; *) printf '%s' "$1" ;; esac; }
fh_pct=$(num "$fh_pct"); wk_pct=$(num "$wk_pct")
case "$fh_reset" in *[!0-9]*) fh_reset="" ;; esac
case "$wk_reset" in *[!0-9]*) wk_reset="" ;; esac

# ---- model-specific weekly quota (e.g. Fable) ----
# ASSUMPTION: the documented payload only has five_hour / seven_day (+ spend_limit).
# A model-specific bucket is taken to be any other .rate_limits entry carrying
# used_percentage; a key containing "fable" wins and is labeled "Fable", otherwise
# the key is title-cased. No such entry -> the section is hidden entirely.
fb_key=$(printf '%s' "$input" | jq -r '
    [(.rate_limits // {}) | to_entries[]
     | select(.key != "five_hour" and .key != "seven_day" and .key != "spend_limit")
     | select((.value | type) == "object" and (.value.used_percentage | type) == "number")
     | .key] | (map(select(test("fable"; "i"))) + .) | .[0] // empty' 2>/dev/null)
fb_pct=""; fb_reset=""; fb_label=""
if [ -n "$fb_key" ]; then
    fb_pct=$(printf '%s' "$input"   | jq -r --arg k "$fb_key" '.rate_limits[$k].used_percentage // empty')
    fb_reset=$(printf '%s' "$input" | jq -r --arg k "$fb_key" '.rate_limits[$k].resets_at // empty')
    case "$fb_reset" in *[!0-9]*) fb_reset="" ;; esac
    case "$fb_key" in
        *[Ff][Aa][Bb][Ll][Ee]*) fb_label="Fable" ;;
        *) fb_label=$(printf '%s' "$fb_key" | awk -F'[_-]' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1') ;;
    esac
fi

# ---- model-scoped weekly quota from the usage API (cached) ----
# Claude Code does not put model-scoped limits (e.g. the Fable weekly quota) in the
# status-line payload; they only exist in the OAuth usage endpoint that /usage reads
# (.limits[] with kind "weekly_scoped" and scope.model.display_name). So:
#   - render ONLY from a local cache file (never blocks on the network);
#   - when the cache is older than USAGE_TTL, refresh it in a detached background
#     job (5s timeout, one refresher at a time via a lock dir);
#   - on any error the old cache is kept. The OAuth token is read only inside that
#     job and is never written anywhere: from the Keychain on macOS, elsewhere from
#     the credentials file Claude Code keeps in its config dir (no file, no request).
USAGE_TTL=90
USAGE_DIR="$HOME/.cache/claude-statusline"
USAGE_CACHE="$USAGE_DIR/usage.json"
# File mtime as epoch seconds: GNU/busybox/Git Bash `stat -c`, else BSD `stat -f`; 0 if unknown.
mtime() {
    _m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)
    case "$_m" in ""|*[!0-9]*) _m=0 ;; esac
    printf '%s' "$_m"
}
usage_refresh() {
    mkdir -p "$USAGE_DIR" 2>/dev/null || return
    lock="$USAGE_DIR/refresh.lock"
    # Clear a lock left behind by a killed job (older than 30s).
    [ -d "$lock" ] && [ $(( $(date +%s) - $(mtime "$lock") )) -gt 30 ] && rmdir "$lock" 2>/dev/null
    mkdir "$lock" 2>/dev/null || return
    (
        if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
            tok=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
                  | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        else
            # Linux, WSL, Git Bash: ~/.claude/.credentials.json, or under $CLAUDE_CONFIG_DIR.
            tok=$(jq -r '.claudeAiOauth.accessToken // empty' \
                  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
        fi
        if [ -n "$tok" ]; then
            tmp="$USAGE_CACHE.$$"
            if curl -s -m 5 -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
                   https://api.anthropic.com/api/oauth/usage -o "$tmp" \
               && jq -e '.limits | type == "array"' "$tmp" >/dev/null 2>&1; then
                mv -f "$tmp" "$USAGE_CACHE"
            else
                rm -f "$tmp"
            fi
        fi
        rmdir "$lock" 2>/dev/null
    ) >/dev/null 2>&1 &
}
cache_age=999999
[ -f "$USAGE_CACHE" ] && cache_age=$(( $(date +%s) - $(mtime "$USAGE_CACHE") ))
[ "$cache_age" -gt "$USAGE_TTL" ] && usage_refresh
# Payload bucket (above) wins; otherwise use the cached model-scoped weekly limit.
# A "Fable" scope is preferred; any other model scope is shown under its own name.
if [ -z "$fb_pct" ] && [ -f "$USAGE_CACHE" ]; then
    fb_line=$(jq -r '
        [.limits[]? | select(.kind == "weekly_scoped" and (.scope.model.display_name // "") != ""
                             and (.percent | type) == "number")]
        | (map(select(.scope.model.display_name | test("fable"; "i"))) + .) | .[0] // empty
        | [.scope.model.display_name, .percent,
           ((.resets_at // "") | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (fromdateiso8601? // ""))]
        | @tsv' "$USAGE_CACHE" 2>/dev/null)
    if [ -n "$fb_line" ]; then
        fb_label=$(printf '%s' "$fb_line" | cut -f1)
        fb_pct=$(printf '%s' "$fb_line" | cut -f2)
        fb_reset=$(printf '%s' "$fb_line" | cut -f3)
        case "$fb_reset" in *[!0-9]*) fb_reset="" ;; esac
        case "$fb_label" in *[Ff][Aa][Bb][Ll][Ee]*) fb_label="Fable" ;; esac
    fi
fi

# 5hr / week fall back to the same cache when the payload has no rate limits yet
# (a fresh session, before its first API response) or its last-known reset has
# already passed (an idle session whose payload went stale).
if [ -f "$USAGE_CACHE" ]; then
    now_s=$(date +%s)
    # cache_limit KIND -> "percent<TAB>resets_at_epoch" for that .limits[] entry
    cache_limit() {
        jq -r --arg k "$1" '
            [.limits[]? | select(.kind == $k and .scope == null and (.percent | type) == "number")] | .[0] // empty
            | [.percent, ((.resets_at // "") | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (fromdateiso8601? // ""))]
            | @tsv' "$USAGE_CACHE" 2>/dev/null
    }
    if [ -z "$fh_pct" ] || { [ -n "$fh_reset" ] && [ "$fh_reset" -le "$now_s" ]; }; then
        l=$(cache_limit session)
        if [ -n "$l" ]; then
            fh_pct=$(num "$(printf '%s' "$l" | cut -f1)")
            fh_reset=$(printf '%s' "$l" | cut -f2); case "$fh_reset" in *[!0-9]*) fh_reset="" ;; esac
        fi
    fi
    if [ -z "$wk_pct" ] || { [ -n "$wk_reset" ] && [ "$wk_reset" -le "$now_s" ]; }; then
        l=$(cache_limit weekly_all)
        if [ -n "$l" ]; then
            wk_pct=$(num "$(printf '%s' "$l" | cut -f1)")
            wk_reset=$(printf '%s' "$l" | cut -f2); case "$wk_reset" in *[!0-9]*) wk_reset="" ;; esac
        fi
    fi
fi

# ---- subscription plan (internal only, not rendered; e.g. "Max 5x") ----
detected_plan=$(jq -r '.oauthAccount.organizationRateLimitTier // empty' "$HOME/.claude.json" 2>/dev/null \
    | sed -n -e 's/^default_claude_max_\([0-9]*x\)$/Max \1/p' -e 's/^default_claude_pro$/Pro/p')

# ---- model ----
model_name=$(printf '%s' "$input" | jq -r '.model.display_name // empty')

# ---- session cost (USD) — the running spend estimate, the only $ signal Claude Code
# exposes to the status line (there is no usage-credit balance in the payload) ----
cost_usd=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty')

# ---- effort (reasoning depth: low | medium | high | xhigh | max) ----
# Claude Code sends it on every render, and it appears nowhere else in the TUI —
# it changes both how hard the model thinks and what the turn costs.
effort_level=$(printf '%s' "$input" | jq -r '.effort.level // empty')

# ---- git branch (of the active workspace dir; empty when not a repo) ----
work_dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
[ -z "$work_dir" ] && work_dir="."
git_branch=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
# Detached HEAD reports "HEAD" — fall back to the short commit hash.
[ "$git_branch" = "HEAD" ] && git_branch=$(git -C "$work_dir" rev-parse --short HEAD 2>/dev/null)
# Folder: the git repo root name, else the working dir's own name (never a full path).
git_root=$(git -C "$work_dir" rev-parse --show-toplevel 2>/dev/null)
folder_name=$(basename "${git_root:-$(cd "$work_dir" 2>/dev/null && pwd)}" 2>/dev/null)
[ "$folder_name" = "/" ] && folder_name=""

DIM="${ESC}[2m"
RST="${ESC}[0m"
SEP="${DIM} | ${RST}"
BRIGHT="${ESC}[22m"   # normal intensity — makes the % stand out against the dim line
REDIM="${ESC}[2m"     # back to faint
MID="${ESC}[22m${ESC}[38;2;200;200;200m"   # medium: brighter than dim, dimmer than %
MIDOFF="${ESC}[39m${REDIM}"                 # restore default color + faint
MC_NAME="${ESC}[22m${ESC}[38;2;190;105;77m"   # model family — Claude orange, normal intensity (resists the dim line)
MC_VER="${ESC}[38;2;205;205;205m"   # version — dimmed white
MC_CTX="${ESC}[38;2;135;135;135m"   # (context) — dimmed gray
MC_BRANCH="${ESC}[22m${ESC}[38;2;97;160;235m"   # git branch — blue, normal intensity (resists the dim line)
MC_COST="${ESC}[22m${ESC}[38;2;205;165;95m"     # session cost — amber/gold, normal intensity (resists the dim line)
MC_FOLDER="${ESC}[22m${ESC}[38;2;205;205;205m"  # folder — dimmed white, normal intensity
# Effort — the ramp runs cool to hot as the model is told to think harder, so the
# level reads at a glance without being read.  All five are normal-intensity so they
# resist the dim line; only `low` is held back a little, since it is the quiet one.
EC_LOW="${ESC}[22m${ESC}[38;2;198;190;140m"     # low    — white-ish yellow, slightly held back
EC_MED="${ESC}[22m${ESC}[38;2;230;170;80m"      # medium — yellow-ish orange
EC_HIGH="${ESC}[22m${ESC}[38;2;217;119;87m"     # high   — Claude orange
EC_EXTRA="${ESC}[22m${ESC}[38;2;203;71;49m"     # extra  — reddish orange, midway between the two below/above
EC_MAX="${ESC}[22m${ESC}[38;2;190;23;12m"       # max    — red (#BE170C): the ceiling
EC_AUTO="${ESC}[22m${ESC}[38;2;27;175;84m"      # auto   — green (#1BAF54). Off the ramp on purpose:
                                                # it is not a depth, it is Claude choosing the depth.
# `/effort ultracode` is NOT a level. It sets the effort to `xhigh` and adds dynamic
# workflow orchestration on top, and the status-line payload carries no trace of it:
# with ultracode active the payload still reads {"level": "xhigh"} and every other
# field is unchanged. So the section shows Extra — which is the truth — and the mode
# itself is simply not visible from here. Verified against a live payload, 2026-07-14.

# Abbreviate token counts to "k" (rounded)
fmtk() {
    n=$1
    echo "$(( (n + 500) / 1000 ))k"   # always in k, so an empty context reads "0k", not "0"
}
# Abbreviate a context-window size to a 1M / 200K style label
fmtctx() {
    n=$1
    if   [ "$n" -ge 1000000 ]; then echo "$(( n / 1000000 ))M"
    elif [ "$n" -ge 1000 ];    then echo "$(( n / 1000 ))K"
    else echo "$n"; fi
}
# An epoch in local time as $2 (a date format): BSD `date -r`, else GNU/busybox `date -d @`.
fmt_epoch() {
    date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2" 2>/dev/null
}
# A signed "HH:MM" clock for a duration in seconds.  $1=seconds (clamped >=0) $2=sign
clock_hm() {
    s=$1; [ "$s" -lt 0 ] && s=0
    printf -- '%s%02d:%02d' "$2" "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
}
# A signed "NdHHh" duration, both parts floored.  $1=seconds $2=sign  ->  "-2d01h" / "+6d23h"
# Six columns, like the "-HH:MM" clock it hands over to under a day.
day_hm() {
    printf -- '%s%dd%02dh' "$2" "$(( $1 / 86400 ))" "$(( ($1 % 86400) / 3600 ))"
}
# Awaiting-reset indicator: a dot sliding across three slots.  Advances by the
# per-render counter SPIN (not the wall clock), so it never aliases — it steps
# once every render regardless of refreshInterval (no value can freeze it).
awaiting() {
    case "$(( SPIN % 3 ))" in
        0) printf ' \342\200\242\302\267\302\267' ;;   # •··
        1) printf ' \302\267\342\200\242\302\267' ;;   # ·•·
        *) printf ' \302\267\302\267\342\200\242' ;;   # ··•
    esac
}
# 5hr time field for the active --time mode (leading space included).  $1=resets_at $2=now
# Once the last-known reset has passed (stale data while idle), show the indicator.
fh_field() {
    rem=$(( $1 - $2 ))
    [ "$rem" -le 0 ] && { awaiting; return; }
    case "$TMODE" in
        reset)     printf ' @%s' "$(fmt_epoch "$1" "$TIMEFMT")" ;;
        remaining) printf ' %s'  "$(clock_hm "$rem" '-')" ;;
        elapsed)   printf ' %s'  "$(clock_hm "$(( FH_LEN - rem ))" '+')" ;;
    esac
}
# Weekly time field: days and hours while >=1 day away, else the signed clock.  $1=resets_at $2=now
wk_field() {
    rem=$(( $1 - $2 ))
    [ "$rem" -le 0 ] && { awaiting; return; }
    case "$TMODE" in
        reset)     printf ' @%s' "$(fmt_epoch "$1" "$DATEFMT")" ;;
        remaining) if [ "$rem" -ge 86400 ]; then printf ' %s' "$(day_hm "$rem" '-')"
                   else printf ' %s' "$(clock_hm "$rem" '-')"; fi ;;
        elapsed)   el=$(( WK_LEN - rem )); [ "$el" -lt 0 ] && el=0
                   if [ "$el" -ge 86400 ]; then printf ' %s' "$(day_hm "$el" '+')"
                   else printf ' %s' "$(clock_hm "$el" '+')"; fi ;;
    esac
}
# Left-align text to exactly N columns (pad with spaces, or clip if too long)
fit() {
    if [ "${#1}" -gt "$2" ]; then printf '%.*s' "$2" "$1"; else printf '%-*s' "$2" "$1"; fi
}
# Color a model string "Name Ver": orange family, dim-white version.
style_model() {
    rest="$1"
    nm="${rest%% *}"; vr=""
    case "$rest" in *" "*) vr=" ${rest#* }" ;; esac
    printf '%s%s%s%s%s' "$MC_NAME" "$nm" "$MC_VER" "$vr" "$RST"
}

# Render a BARW-cell bar; each cell owns a green(0%)->red(100%) gradient color.
# Filled cells are bright; the unfilled track keeps the same hue but dim.
bar() {
    awk -v p="$1" -v w="$BARW" -v esc="$ESC" -v glyph="$GLYPH" -v fill="$FILL" -v track="$TRACK" 'BEGIN {
        filled = int(p / 100 * w + 0.5);
        out = "";
        for (i = 0; i < w; i++) {
            f = (w > 1) ? i / (w - 1) : 0;
            if (f <= 0.5) { r = f * 2 * 255; g = 255 }
            else          { r = 255; g = (1 - f) * 2 * 255 }
            br = (i < filled) ? fill : track;
            out = out esc sprintf("[38;2;%d;%d;0m", int(r * br + 0.5), int(g * br + 0.5)) glyph;
        }
        printf "%s%s[0m", out, esc;
    }'
}

# Truecolor escape for the % label: the bar's leading-edge gradient color at p%,
# dimmed a touch below the filled-bar brightness so it reads as a value, not a cell.
pct_color() {
    awk -v p="$1" -v w="$BARW" -v esc="$ESC" -v fill="$FILL" 'BEGIN {
        br = fill * 0.78;                       # a dimmed version of the bar color
        filled = int(p / 100 * w + 0.5);
        front = filled - 1;                     # the leading (last filled) cell
        if (front < 0) front = 0; if (front > w - 1) front = w - 1;
        f = (w > 1) ? front / (w - 1) : 0;
        if (f <= 0.5) { r = f * 2 * 255; g = 255 }
        else          { r = 255; g = (1 - f) * 2 * 255 }
        printf "%s[22m%s[38;2;%d;%d;0m", esc, esc, int(r * br + 0.5), int(g * br + 0.5);
    }'
}

# Decide which requested sections to show, preserving requested order.
# The 5hr/week rate sections always show once requested: with no data yet (new
# session, before the first API response) they render the awaiting indicator.
avail=""
for s in $(printf '%s' "$SECTIONS" | tr ',' ' '); do
    case "$s" in
        context|tokens) [ "$ctx_size" -gt 0 ] && avail="$avail context" ;;   # `tokens` = legacy alias
        5hr)    avail="$avail 5hr" ;;
        week)   avail="$avail week" ;;
        branch) [ -n "$git_branch" ]  && avail="$avail branch" ;;
        model)  [ -n "$model_name" ]  && avail="$avail model" ;;
        effort) [ -n "$effort_level" ] && avail="$avail effort" ;;   # the display text is built later
        cost|credit) [ -n "$cost_usd" ] && avail="$avail cost" ;;   # `credit` = alias for cost
        folder) [ -n "$folder_name" ] && avail="$avail folder" ;;
        model_effort) [ -n "$model_name" ] && avail="$avail model_effort" ;;
        fable)  [ -n "$fb_pct" ] && avail="$avail fable" ;;   # hidden unless the bucket exists
    esac
done
set -- $avail
keep=$#

# Model / cost display text — computed here (before the responsive check) so that
# check can measure their real width.  The bar sections are exactly --width, but
# branch/model/cost are sized to their content and must not be over-counted.
# The model section names the model, and nothing else. It used to append the context
# window — "Opus 4.8 (1M)" — but that size is not part of the model: it is a runtime
# setting of the session, read from `.context_window.context_window_size`, and the
# context section already shows it as the denominator ("708k/1M"). Printing it twice
# invited the reading that the window is a property of the model, which it is not.
# Any parenthetical the display name itself carries is dropped for the same reason.
model_text=""
[ -n "$model_name" ] && model_text=$(printf '%s' "$model_name" | sed -e 's/ *([^)]*)//g' -e 's/ *$//')

# Effort display text — "High", "XHigh", "Max".
effort_text=""
case "$effort_level" in
    low)    effort_text="Low";    EC="$EC_LOW" ;;
    medium) effort_text="Medium"; EC="$EC_MED" ;;
    high)   effort_text="High";   EC="$EC_HIGH" ;;
    # Claude's own UI calls this level "Extra"; the API calls it "xhigh". Accept both,
    # and show the name the user sees in the app.
    xhigh|extra) effort_text="XHigh"; EC="$EC_EXTRA" ;;
    max)    effort_text="Max";    EC="$EC_MAX" ;;
    # `auto` is not a rung on the ladder — Claude picks the depth per turn — so it is
    # colored apart from the cool-to-hot ramp rather than at one end of it.
    auto)   effort_text="Auto";   EC="$EC_AUTO" ;;
    "")     : ;;
    # An effort level this version has never heard of still gets shown, uncolored,
    # rather than silently dropped — Anthropic can add one at any time.
    *)      effort_text=$(printf '%s' "$effort_level" | tr '[:lower:]' '[:upper:]' | cut -c1)$(printf '%s' "$effort_level" | cut -c2-)
            EC="$BRIGHT" ;;
esac
cost_text=""
[ -n "$cost_usd" ] && cost_text=$(printf '$%.2f' "$cost_usd" 2>/dev/null)
[ -z "$cost_text" ] && [ -n "$cost_usd" ] && cost_text="\$$cost_usd"   # fallback if not numeric
me_text="$model_text"
[ -n "$me_text" ] && [ -n "$effort_text" ] && me_text="$model_text · $effort_text"

# Display width of one section.  Bar sections (context/5hr/week) occupy exactly
# --width; the branch/model/cost columns fit their content — in compact, branch/model
# show just the value and cost shows "Cost <value>"; in expanded a label/value column
# is the wider of its label and value.  Counting these as a full bar (the old estimate)
# over-stated the line and dropped sections that actually fit.
sec_w() {
    case "$1" in
        branch) if [ "$LAYOUT" = compact ]; then _w=${#git_branch}
                else _w=6; [ "${#git_branch}" -gt "$_w" ] && _w=${#git_branch}; fi ;;   # "Branch"=6
        model)  if [ "$LAYOUT" = compact ]; then _w=${#model_text}
                else _w=5; [ "${#model_text}" -gt "$_w" ] && _w=${#model_text}; fi ;;   # "Model"=5
        cost)   if [ "$LAYOUT" = compact ]; then _w=$(( 7 + ${#cost_text} ))            # "S.Cost <value>"
                else _w=6; [ "${#cost_text}" -gt "$_w" ] && _w=${#cost_text}; fi ;;     # "S.Cost"=6
        folder) if [ "$LAYOUT" = compact ]; then _w=${#folder_name}
                else _w=6; [ "${#folder_name}" -gt "$_w" ] && _w=${#folder_name}; fi ;; # "Folder"=6
        model_effort) if [ "$LAYOUT" = compact ]; then _w=${#me_text}
                else _w=14; [ "${#me_text}" -gt "$_w" ] && _w=${#me_text}; fi ;;   # "Model · Effort"=14
        effort) if [ "$LAYOUT" = compact ]; then _w=${#effort_text}
                else _w=6; [ "${#effort_text}" -gt "$_w" ] && _w=${#effort_text}; fi ;; # "Effort"=6
        *)      _w=$BARW                                                # bar sections; the header may
                if [ "$LAYOUT" != compact ]; then                       # widen them (worst case below)
                    case "$1" in context|week) _m=16 ;; 5hr) _m=15 ;; fable) _m=$(( ${#fb_label} + 12 )) ;; *) _m=0 ;; esac
                    [ "$_m" -gt "$_w" ] && _w=$_m
                fi ;;
    esac
    printf '%s' "$_w"
}

# Responsive: while the real line width exceeds $COLUMNS, drop cost, then fable, then
# branch, then sections from the right. Folder/model/context/5hr/week go last.
case "$COLUMNS" in *[!0-9]*|"") cols=0 ;; *) cols="$COLUMNS" ;; esac
line_w() {
    _sum=$(( 3 * ($# - 1) ))
    for _s in "$@"; do _sum=$(( _sum + $(sec_w "$_s") )); done
    printf '%s' "$_sum"
}
if [ "$RESPONSIVE" = "true" ] && [ "$cols" -gt 0 ]; then
    for victim in cost fable branch; do
        set -- $avail
        [ "$#" -le 1 ] || [ "$(line_w "$@")" -le "$cols" ] && break
        avail=$(printf '%s\n' $avail | grep -vx "$victim" | tr '\n' ' ')
    done
    set -- $avail
    while [ "$#" -gt 1 ] && [ "$(line_w "$@")" -gt "$cols" ]; do
        avail=$(printf '%s\n' $avail | sed '$d' | tr '\n' ' ')
        set -- $avail
    done
fi
set -- $avail
keep=$#

# Precompute per-section content.
NOW=$(date +%s)
# Spin counter for the awaiting animation: advance ONCE per render (so it steps
# regardless of refreshInterval), and only while an indicator is on screen, so
# normal renders touch no files.  An indicator shows for a requested rate section
# that has no data yet OR whose last-known reset has already passed.
spin=0
for s in 5hr week; do
    case ",$SECTIONS," in *",$s,"*) ;; *) continue ;; esac
    if [ "$s" = "5hr" ]; then p="$fh_pct"; r="$fh_reset"; else p="$wk_pct"; r="$wk_reset"; fi
    if [ -z "$p" ]; then spin=1
    elif [ -n "$r" ] && [ "$r" -le "$NOW" ]; then spin=1; fi
done
SPIN=0
if [ "$spin" = 1 ]; then
    sf="${TMPDIR:-/tmp}/.cc-statusline-spin"
    [ -f "$sf" ] && read -r SPIN < "$sf" 2>/dev/null
    case "$SPIN" in *[!0-9]*|"") SPIN=0 ;; esac
    printf '%s' "$(( (SPIN + 1) % 2999997 ))" > "$sf" 2>/dev/null   # wrap stays a multiple of 3
fi
fh_t=""; [ -n "$fh_reset" ] && fh_t=$(fh_field "$fh_reset" "$NOW")
wk_d=""; [ -n "$wk_reset" ] && wk_d=$(wk_field "$wk_reset" "$NOW")
[ -n "$fh_pct" ] && fh_r=$(printf "%.0f" "$fh_pct")
[ -n "$wk_pct" ] && wk_r=$(printf "%.0f" "$wk_pct")
fb_d=""; [ -n "$fb_reset" ] && fb_d=$(wk_field "$fb_reset" "$NOW")
[ -n "$fb_pct" ] && fb_r=$(printf "%.0f" "$fb_pct")
if [ "$ctx_size" -gt 0 ]; then tok_used=$(fmtk "$total"); tok_tot=$(fmtk "$ctx_size"); fi

# Build line 1 (text) and line 2 (bars / model name), one section at a time.
L1=""; L2=""; idx=0
for s in $avail; do
    idx=$((idx + 1))
    [ "$idx" -gt "$keep" ] && break
    last=0; [ "$idx" -eq "$keep" ] && last=1

    if [ "$s" = "model" ] || [ "$s" = "branch" ] || [ "$s" = "cost" ] || [ "$s" = "effort" ] \
       || [ "$s" = "folder" ] || [ "$s" = "model_effort" ]; then
        # Label on line 1; colored value on line 2 (no % / no bar).
        # These columns fit their content: width is the longer of label/value,
        # never padded out to the bar width.  Only the shorter of the two lines
        # gets trailing spaces, so the column's pipes still align vertically.
        if [ "$s" = "model" ]; then
            label="Model"; valtext="$model_text"; styled=$(style_model "$valtext")
        elif [ "$s" = "effort" ]; then
            label="Effort"; valtext="$effort_text"; styled="${EC}${valtext}${RST}"
        elif [ "$s" = "folder" ]; then
            label="Folder"; valtext="$folder_name"; styled="${MC_FOLDER}${valtext}${RST}"
        elif [ "$s" = "model_effort" ]; then
            label="Model · Effort"; valtext="$me_text"; styled=$(style_model "$model_text")
            [ -n "$effort_text" ] && styled="${styled}${DIM} · ${RST}${EC}${effort_text}${RST}"
        elif [ "$s" = "cost" ]; then
            label="S.Cost"; valtext="$cost_text"; styled="${MC_COST}${valtext}${RST}"
        else
            label="Branch"; valtext="$git_branch"; styled="${MC_BRANCH}${valtext}${RST}"
        fi
        if [ "$LAYOUT" = "compact" ]; then
            # Single line: the value itself stands in (no label, no second line) — except
            # cost keeps its "Cost" label, since a bare "$0.41" reads less clearly than a
            # branch/model name.  Re-assert dim after the value's reset so the next
            # separator stays dim.
            if [ "$s" = "cost" ]; then seg="${label} ${styled}${DIM}"; else seg="${styled}${DIM}"; fi
        else
            colw=${#label}; [ "${#valtext}" -gt "$colw" ] && colw=${#valtext}
            seg="${label}$(printf '%*s' "$(( colw - ${#label} ))" '')"   # ${#} counts chars; printf %-*s would count bytes
            barseg="${styled}$(printf '%*s' "$(( colw - ${#valtext} ))" '')"
        fi
    else
        # core = left-pinned label; rt = the time value that can move to the right
        # when the % is hidden (empty for context and while awaiting).  lp/ls = the
        # full left block (core + time) used when the % is shown.
        case "$s" in
            context) core="${tok_used}/${tok_tot}"; cstyled="${MID}${tok_used}${MIDOFF}/${tok_tot}"
                     rt=""; rstyled=""; lp="$core"; ls="$cstyled"; pct="${tok_pct}%"; bp="$tok_pct" ;;
            5hr)    if [ -z "$fh_pct" ]; then core="5hr"; cstyled="5hr"; rt=""; rstyled=""
                        lp="5hr$(awaiting)"; ls="$lp"; pct=""; bp=0
                    else t="${fh_t# }"; core="5hr"; cstyled="5hr"; rt="$t"; rstyled="${MID}${t}${MIDOFF}"
                        lp="5hr $t"; ls="5hr${MID} ${t}${MIDOFF}"; pct="${fh_r}%"; bp="$fh_r"; fi ;;
            week)   if [ -z "$wk_pct" ]; then core="Week"; cstyled="Week"; rt=""; rstyled=""
                        lp="Week$(awaiting)"; ls="$lp"; pct=""; bp=0
                    else t="${wk_d# }"; core="Week"; cstyled="Week"; rt="$t"; rstyled="${MID}${t}${MIDOFF}"
                        lp="Week $t"; ls="Week${MID} ${t}${MIDOFF}"; pct="${wk_r}%"; bp="$wk_r"; fi ;;
            fable)  t="${fb_d# }"; core="$fb_label"; cstyled="$fb_label"; rt="$t"
                    if [ -n "$t" ]; then rstyled="${MID}${t}${MIDOFF}"; lp="$fb_label $t"; ls="$fb_label${MID} ${t}${MIDOFF}"
                    else rstyled=""; lp="$fb_label"; ls="$fb_label"; fi
                    pct="${fb_r}%"; bp="$fb_r" ;;
        esac
        if [ "$LAYOUT" = "compact" ]; then
            # Single line: no bars to align to — one space before the %, none if absent.
            if [ -n "$pct" ]; then seg="${ls} $(pct_color "$bp")${pct}${MIDOFF}"; else seg="${ls}"; fi
        else
            # Expanded.  Hide the % when BARW can't hold the left block + a space + %.
            hid=0
            # (the last section may overflow instead — that never shifts a pipe)
            # (never hidden: a label + % longer than BARW widens the column instead)
            if [ -n "$pct" ]; then
                # % shown: left block on the left, % flush right within BARW.
                pad=$(( BARW - ${#lp} - ${#pct} )); [ "$pad" -lt 1 ] && pad=1
                seg="${ls}$(printf "%*s" "$pad" "")$(pct_color "$bp")${pct}${MIDOFF}"
                extra=$(( ${#lp} + pad + ${#pct} - BARW ))
            elif [ "$hid" -eq 1 ] && [ -n "$rt" ]; then
                # % hidden for room: keep the label left, right-align only the time.
                pad=$(( BARW - ${#core} - ${#rt} ))
                if [ "$pad" -lt 1 ]; then
                    if [ "$last" -eq 1 ]; then pad=1            # overflow ok, keep a gap
                    else
                        clip=$(( BARW - ${#core} )); [ "$clip" -lt 0 ] && clip=0
                        rt=$(printf '%.*s' "$clip" "$rt"); rstyled="$rt"
                        pad=$(( BARW - ${#core} - ${#rt} )); [ "$pad" -lt 0 ] && pad=0
                    fi
                fi
                seg="${cstyled}$(printf "%*s" "$pad" "")${rstyled}${MIDOFF}"
            else
                # Awaiting placeholder, or the context section: left-align the value.
                pad=$(( BARW - ${#lp} ))
                if [ "$last" -ne 1 ] && [ "$pad" -lt 0 ]; then lp=$(printf '%.*s' "$BARW" "$lp"); ls="$lp"; fi
                [ "$pad" -lt 0 ] && pad=0
                seg="${ls}$(printf "%*s" "$pad" "")"
            fi
            barseg="$(bar "$bp")"
            # widened column: pad the bar line so the next pipe stays aligned
            if [ "${extra:-0}" -gt 0 ] && [ "$last" -ne 1 ]; then barseg="${barseg}$(printf '%*s' "$extra" '')"; fi
            extra=0
        fi
    fi

    if [ -z "$L1" ]; then
        L1="$seg"; L2="$barseg"
    else
        L1="$L1 | $seg"; L2="$L2${SEP}${barseg}"
    fi
done

if [ -n "$L1" ]; then
    if [ "$LAYOUT" = "compact" ]; then
        printf "%s%s%s\n" "$DIM" "$L1" "$RST"
    else
        printf "%s%s%s\n%s\n" "$DIM" "$L1" "$RST" "$L2"
    fi
fi
