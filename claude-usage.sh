#!/bin/bash
# Show usage for all configured Claude Code accounts via API.
# Usage: claude-usage or bash claude-usage.sh
#
# Reads accounts from manifest at ~/.claude-accounts.json (falls back to
# default 2-account setup if absent).
#
# Reads OAuth tokens from:
#   - macOS: Keychain ("Claude Code-credentials[-<hash>]")
#   - Linux: <CONFIG_DIR>/.credentials.json

LIB="$HOME/.claude/scripts/lib/accounts.sh"
if [ ! -f "$LIB" ]; then
  echo "ERROR: $LIB not found. Run install.sh first." >&2
  exit 1
fi
source "$LIB"

read_token() {
  local config_dir="$1"
  local token=""

  if [ -f "$config_dir/.credentials.json" ]; then
    token=$(python3 -c "
import json
try: print(json.load(open('$config_dir/.credentials.json')).get('claudeAiOauth',{}).get('accessToken',''))
except: pass
" 2>/dev/null)
    [ -n "$token" ] && { echo "$token"; return; }
  fi

  if command -v security >/dev/null 2>&1; then
    local service="Claude Code-credentials"
    if [ "$config_dir" != "$HOME/.claude" ]; then
      local match
      match=$(security dump-keychain 2>/dev/null | grep -oE '"Claude Code-credentials-[a-f0-9]+"' | tr -d '"' | head -1)
      [ -n "$match" ] && service="$match"
    fi
    token=$(security find-generic-password -s "$service" -a "${USER}" -w 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])
except: pass
" 2>/dev/null)
  fi
  echo "$token"
}

query_account() {
  local id="$1" config_dir="$2" label="$3"
  local email token usage

  local profile_file="$config_dir/.claude.json"
  [ ! -f "$profile_file" ] && [ -f "$HOME/.claude.json" ] && profile_file="$HOME/.claude.json"
  email=$(cat "$profile_file" 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('oauthAccount',{}).get('emailAddress','?'))
except: print('?')
" 2>/dev/null)

  local alias_label="cc${id}"
  [ -n "$label" ] && [ "$label" != "default" ] && [ "$label" != "secondary" ] && alias_label="cc${id} ($label)"

  token=$(read_token "$config_dir")
  if [ -z "$token" ]; then
    printf "  %-30s %-30s not logged in\n" "$alias_label" "$email"
    return
  fi

  usage=$(curl -s --max-time 5 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

  echo "$usage" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d:
    t=d['error'].get('type','unknown')
    if 'auth' in t:
        print(f\"  {'$alias_label':<30} {'$email':<30} 재로그인 필요 ({t})\")
    elif 'rate_limit' in t:
        print(f\"  {'$alias_label':<30} {'$email':<30} API rate limit — 잠시 후 재시도\")
    else:
        print(f\"  {'$alias_label':<30} {'$email':<30} 에러: {t}\")
else:
    h5=d['five_hour']['utilization']
    d7=d['seven_day']['utilization']
    r5=d['five_hour']['resets_at'][:16].replace('T',' ')
    print(f\"  {'$alias_label':<30} {'$email':<30} 5h {h5:>4.0f}% | 7d {d7:>4.0f}% (resets {r5})\")
" 2>/dev/null || printf "  %-30s %-30s query failed\n" "$alias_label" "$email"
}

echo "Claude Code Account Usage"
echo ""
echo "  Alias                          Email                          Usage"
echo "  ------------------------------ ------------------------------ ---------------------------------"
while IFS=$'\t' read -r id dir label; do
  [ -z "$id" ] && continue
  query_account "$id" "$dir" "$label"
done < <(accounts_list)
