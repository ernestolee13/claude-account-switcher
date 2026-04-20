#!/bin/bash
# Show usage for both Claude Code accounts via API
# Usage: claude-usage or bash claude-usage.sh

query_account() {
  local label="$1" service="$2" config_dir="$3"
  local cred token email usage

  # Get email from config dir's .claude.json
  email=$(cat "$config_dir/.claude.json" 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('oauthAccount',{}).get('emailAddress','?'))
except: print('?')
" 2>/dev/null)

  cred=$(security find-generic-password -s "$service" -a "${USER}" -w 2>/dev/null || true)
  if [ -z "$cred" ]; then
    printf "  %-20s %-30s not logged in\n" "$label" "$email"
    return
  fi

  token=$(echo "$cred" | python3 -c "import json,sys; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
  [ -z "$token" ] && { printf "  %-20s %-30s invalid token\n" "$label" "$email"; return; }

  usage=$(curl -s --max-time 5 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

  echo "$usage" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d:
    err_type=d['error'].get('type','unknown')
    if 'auth' in err_type:
        print(f\"  {'$label':<20} {'$email':<30} 재로그인 필요 ({err_type})\")
    elif 'rate_limit' in err_type:
        print(f\"  {'$label':<20} {'$email':<30} API rate limit — 잠시 후 재시도\")
    else:
        print(f\"  {'$label':<20} {'$email':<30} 에러: {err_type}\")
else:
    h5=d['five_hour']['utilization']
    d7=d['seven_day']['utilization']
    r5=d['five_hour']['resets_at'][:16].replace('T',' ')
    print(f\"  {'$label':<20} {'$email':<30} 5h {h5:>4.0f}% | 7d {d7:>4.0f}% (resets {r5})\")
" 2>/dev/null || printf "  %-20s %-30s query failed\n" "$label" "$email"
}

echo "Claude Code Account Usage"
echo ""
echo "  Alias                Email                          Usage"
echo "  -------------------- ------------------------------ ---------------------------------"
query_account "cc (~/.claude-account2)" "Claude Code-credentials-33351ebb" "$HOME/.claude-account2"
query_account "cc2 (default)" "Claude Code-credentials" "$HOME/.claude"
