#!/bin/bash
# Show usage for both Claude Code accounts via API
# Usage: claude-usage or bash claude-usage.sh

query_usage() {
  local label="$1" service="$2"
  local cred token usage
  cred=$(security find-generic-password -s "$service" -a "${USER}" -w 2>/dev/null || true)
  [ -z "$cred" ] && { echo "  $label: not logged in ($service)"; return; }

  token=$(echo "$cred" | python3 -c "import json,sys; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
  [ -z "$token" ] && { echo "  $label: invalid token"; return; }

  usage=$(curl -s --max-time 5 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

  echo "$usage" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d:
    print(f'  $label: auth error')
else:
    h5=d['five_hour']['utilization']
    d7=d['seven_day']['utilization']
    r5=d['five_hour']['resets_at'][:16].replace('T',' ')
    print(f'  $label: 5h {h5}% | 7d {d7}% (resets {r5})')
" 2>/dev/null || echo "  $label: query failed"
}

# Find all Claude Code Keychain entries
SERVICES=$(security dump-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null \
  | grep -oE '"Claude Code-credentials[^"]*"' \
  | tr -d '"' | sort -u)

echo "Claude Code Account Usage"
echo ""
N=1
while IFS= read -r svc; do
  [ -z "$svc" ] && continue
  query_usage "Account $N" "$svc"
  N=$((N+1))
done <<< "$SERVICES"

[ "$N" -eq 1 ] && echo "  No accounts found in Keychain." && exit 1
exit 0
