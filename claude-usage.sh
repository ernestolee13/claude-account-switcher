#!/bin/bash
# Show usage for both Claude Code accounts via API
# Usage: claude-usage or bash claude-usage.sh
#
# Reads OAuth tokens from:
#   - macOS: Keychain ("Claude Code-credentials[-<hash>]")
#   - Linux: <CONFIG_DIR>/.credentials.json

CONFIG_DIR_2="${CLAUDE_CONFIG_DIR_2:-$HOME/.claude-account2}"

# Compute Keychain suffix for a config dir (macOS only)
# Claude Code uses a hash of the config dir path as suffix
keychain_suffix() {
  local dir="$1"
  # Default dir has no suffix
  [ "$dir" = "$HOME/.claude" ] && { echo ""; return; }
  # Try common hash algorithms to find matching Keychain entry
  local candidates
  candidates=$(security dump-keychain 2>/dev/null | grep -oE '"Claude Code-credentials-[a-f0-9]+"' | tr -d '"' | sort -u)
  # Return the first non-default entry (single alternate assumption)
  echo "$candidates" | head -1 | sed 's/^Claude Code-credentials-//'
}

# Read OAuth token for a given config dir, cross-platform
read_token() {
  local config_dir="$1"
  local token=""

  # Linux: read from .credentials.json in config dir
  if [ -f "$config_dir/.credentials.json" ]; then
    token=$(python3 -c "
import json
try:
    d = json.load(open('$config_dir/.credentials.json'))
    print(d.get('claudeAiOauth', {}).get('accessToken', ''))
except: pass
" 2>/dev/null)
    [ -n "$token" ] && { echo "$token"; return; }
  fi

  # macOS: read from Keychain
  if command -v security >/dev/null 2>&1; then
    local service="Claude Code-credentials"
    if [ "$config_dir" != "$HOME/.claude" ]; then
      local suffix
      suffix=$(keychain_suffix "$config_dir")
      [ -n "$suffix" ] && service="Claude Code-credentials-${suffix}"
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
  local label="$1" config_dir="$2"
  local email token usage

  email=$(cat "$config_dir/.claude.json" 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('oauthAccount',{}).get('emailAddress','?'))
except: print('?')
" 2>/dev/null)

  token=$(read_token "$config_dir")
  if [ -z "$token" ]; then
    printf "  %-30s %-30s not logged in\n" "$label" "$email"
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
        print(f\"  {'$label':<30} {'$email':<30} 재로그인 필요 ({t})\")
    elif 'rate_limit' in t:
        print(f\"  {'$label':<30} {'$email':<30} API rate limit — 잠시 후 재시도\")
    else:
        print(f\"  {'$label':<30} {'$email':<30} 에러: {t}\")
else:
    h5=d['five_hour']['utilization']
    d7=d['seven_day']['utilization']
    r5=d['five_hour']['resets_at'][:16].replace('T',' ')
    print(f\"  {'$label':<30} {'$email':<30} 5h {h5:>4.0f}% | 7d {d7:>4.0f}% (resets {r5})\")
" 2>/dev/null || printf "  %-30s %-30s query failed\n" "$label" "$email"
}

echo "Claude Code Account Usage"
echo ""
echo "  Alias                          Email                          Usage"
echo "  ------------------------------ ------------------------------ ---------------------------------"
query_account "cc (default)" "$HOME/.claude"
query_account "cc2 (~/.claude-account2)" "$CONFIG_DIR_2"
