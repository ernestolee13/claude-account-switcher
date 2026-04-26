#!/bin/bash
# Pick the less-used Claude Code account by querying OAuth usage.
# Prints "1" or "2" on stdout. Falls back to "1" on any failure.
#
# Uses the same usage endpoint as claude-usage.sh. Decision rule:
#   - Prefer the account whose 5-hour window has capacity (<100% utilization)
#   - Among candidates, pick the one with LOWER 5h utilization
#   - If both are at >=100% 5h, pick by lower 7d utilization
#   - If one account can't be queried, use the other
#   - If neither can be queried, return "1"
#
# Cache result for $PICK_CACHE_TTL seconds (default 60) in
# /tmp/claude_pick_account_cache to avoid API calls on every shell function.

set -u

CONFIG_DIR_1="$HOME/.claude"
CONFIG_DIR_2="${CLAUDE_CONFIG_DIR_2:-$HOME/.claude-account2}"
CACHE_FILE="/tmp/claude_pick_account_cache"
CACHE_TTL="${PICK_CACHE_TTL:-60}"

# Honor force-refresh flag
if [ "${1:-}" != "--no-cache" ] && [ -f "$CACHE_FILE" ]; then
    CACHE_AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))
    if [ "$CACHE_AGE" -lt "$CACHE_TTL" ]; then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

read_token() {
    local config_dir="$1"
    if [ -f "$config_dir/.credentials.json" ]; then
        python3 -c "
import json
try:
    d = json.load(open('$config_dir/.credentials.json'))
    print(d.get('claudeAiOauth', {}).get('accessToken', ''))
except: pass
" 2>/dev/null
    fi
}

query_utilization() {
    # Echoes "<h5>\t<d7>" where each is an integer 0..100+, or empty on failure
    local config_dir="$1"
    local token
    token=$(read_token "$config_dir")
    [ -z "$token" ] && return 1

    local resp
    resp=$(curl -s --max-time 5 \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    [ -z "$resp" ] && return 1

    echo "$resp" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if 'error' in d:
        sys.exit(1)
    h5 = int(d['five_hour']['utilization'])
    d7 = int(d['seven_day']['utilization'])
    print(f'{h5}\t{d7}')
except Exception:
    sys.exit(1)
" 2>/dev/null
}

U1=$(query_utilization "$CONFIG_DIR_1")
U2=$(query_utilization "$CONFIG_DIR_2")

# Helper: parse or mark unavailable
parse() {  # echoes "<5h> <7d>" or "unavailable"
    if [ -z "$1" ]; then echo "unavailable"; else echo "$1" | tr '\t' ' '; fi
}

pick() {
    local pick=""
    if [ -z "$U1" ] && [ -z "$U2" ]; then
        echo "1"; return
    fi
    if [ -z "$U1" ]; then echo "2"; return; fi
    if [ -z "$U2" ]; then echo "1"; return; fi

    local h5_1 d7_1 h5_2 d7_2
    IFS=$'\t' read -r h5_1 d7_1 <<< "$U1"
    IFS=$'\t' read -r h5_2 d7_2 <<< "$U2"

    # If one is at cap (>=100) and the other isn't, pick the non-capped one
    if [ "$h5_1" -ge 100 ] && [ "$h5_2" -lt 100 ]; then echo "2"; return; fi
    if [ "$h5_2" -ge 100 ] && [ "$h5_1" -lt 100 ]; then echo "1"; return; fi

    # Both capped: compare 7d
    if [ "$h5_1" -ge 100 ] && [ "$h5_2" -ge 100 ]; then
        [ "$d7_1" -le "$d7_2" ] && echo "1" || echo "2"
        return
    fi

    # Normal case: pick lower 5h util
    [ "$h5_1" -le "$h5_2" ] && echo "1" || echo "2"
}

CHOICE=$(pick)
echo "$CHOICE" > "$CACHE_FILE" 2>/dev/null

# Log decision for debugging
LOG_FILE="$HOME/.claude/logs/account-switch.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
echo "[$(date '+%Y-%m-%d %H:%M:%S')] pick-account: acct1=$(parse "$U1") acct2=$(parse "$U2") → choice=$CHOICE" >> "$LOG_FILE"

echo "$CHOICE"
