#!/bin/bash
# Pick the least-utilized Claude Code account by querying OAuth usage.
# Prints the chosen account id on stdout. Falls back to "1" on any failure.
#
# Decision rule (across all accounts in manifest):
#   - Filter out accounts currently rate-limited (recorded in /tmp by hook)
#   - Prefer accounts under 100% 5h utilization
#   - Among candidates, pick LOWER 5h utilization
#   - Tiebreak on lower 7d utilization
#   - If only one queryable, use it
#   - If none queryable, return "1"
#
# Cache result for $PICK_CACHE_TTL seconds (default 60) in
# /tmp/claude_pick_account_cache. Force refresh with `--no-cache`.

set -u

LIB="$(dirname "$0")/lib/accounts.sh"
[ -f "$LIB" ] || LIB="$HOME/.claude/scripts/lib/accounts.sh"
if [ -f "$LIB" ]; then
  source "$LIB"
else
  # Minimal fallback if helper missing
  accounts_list() {
    printf "1\t%s\tdefault\n" "$HOME/.claude"
    printf "2\t%s\tsecondary\n" "${CLAUDE_CONFIG_DIR_2:-$HOME/.claude-account2}"
  }
fi

CACHE_FILE="/tmp/claude_pick_account_cache"
CACHE_TTL="${PICK_CACHE_TTL:-60}"
COOLDOWN="${CLAUDE_SWITCH_COOLDOWN:-1800}"

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
" 2>/dev/null && return 0
  fi
  if command -v security >/dev/null 2>&1; then
    local service="Claude Code-credentials"
    if [ "$config_dir" != "$HOME/.claude" ]; then
      local match
      match=$(security dump-keychain 2>/dev/null | grep -oE '"Claude Code-credentials-[a-f0-9]+"' | tr -d '"' | head -1)
      [ -n "$match" ] && service="$match"
    fi
    security find-generic-password -s "$service" -a "$USER" -w 2>/dev/null | python3 -c "
import json, sys
try: print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])
except: pass
" 2>/dev/null
  fi
}

query_utilization() {
  # Echoes "<h5>\t<d7>" or empty on failure
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
    if 'error' in d: sys.exit(1)
    h5 = int(d['five_hour']['utilization'])
    d7 = int(d['seven_day']['utilization'])
    print(f'{h5}\t{d7}')
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# Collect <id>:<h5>:<d7> for queryable accounts not currently rate-limited
NOW=$(date +%s)
CANDIDATES=()
DEBUG_INFO=""

while IFS=$'\t' read -r id dir label; do
  [ -z "$id" ] && continue
  RL_TS_FILE="/tmp/claude_ratelimit_account${id}"
  if [ -f "$RL_TS_FILE" ]; then
    RL_TS=$(cat "$RL_TS_FILE" 2>/dev/null || echo 0)
    if [ $((NOW - RL_TS)) -lt "$COOLDOWN" ]; then
      DEBUG_INFO="$DEBUG_INFO acct${id}=rate_limited"
      continue
    fi
  fi
  UTIL=$(query_utilization "$dir")
  if [ -z "$UTIL" ]; then
    DEBUG_INFO="$DEBUG_INFO acct${id}=unavailable"
    continue
  fi
  IFS=$'\t' read -r h5 d7 <<< "$UTIL"
  CANDIDATES+=("${id}:${h5}:${d7}")
  DEBUG_INFO="$DEBUG_INFO acct${id}=${h5}%/${d7}%"
done < <(accounts_list)

CHOICE=""
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  CHOICE="1"
elif [ "${#CANDIDATES[@]}" -eq 1 ]; then
  CHOICE="${CANDIDATES[0]%%:*}"
else
  UNDER_CAP=()
  for c in "${CANDIDATES[@]}"; do
    h5=$(echo "$c" | cut -d: -f2)
    [ "$h5" -lt 100 ] && UNDER_CAP+=("$c")
  done
  POOL=("${CANDIDATES[@]}")
  [ "${#UNDER_CAP[@]}" -gt 0 ] && POOL=("${UNDER_CAP[@]}")

  BEST_ID=""; BEST_H5=999; BEST_D7=999
  for c in "${POOL[@]}"; do
    id=$(echo "$c" | cut -d: -f1)
    h5=$(echo "$c" | cut -d: -f2)
    d7=$(echo "$c" | cut -d: -f3)
    if [ "$h5" -lt "$BEST_H5" ] || { [ "$h5" -eq "$BEST_H5" ] && [ "$d7" -lt "$BEST_D7" ]; }; then
      BEST_ID="$id"; BEST_H5="$h5"; BEST_D7="$d7"
    fi
  done
  CHOICE="${BEST_ID:-1}"
fi

echo "$CHOICE" > "$CACHE_FILE" 2>/dev/null

LOG_FILE="$HOME/.claude/logs/account-switch.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
echo "[$(date '+%Y-%m-%d %H:%M:%S')] pick-account:${DEBUG_INFO} → choice=$CHOICE" >> "$LOG_FILE"

echo "$CHOICE"
