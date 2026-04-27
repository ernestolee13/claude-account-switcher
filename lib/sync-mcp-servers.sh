#!/bin/bash
# sync-mcp-servers.sh — Mirror mcpServers across all account .claude.json files.
#
# .claude.json mixes account-specific data (userID, oauthAccount, billing/
# feature-flag caches) with user preferences (mcpServers, etc.). Only
# mcpServers is mirrored — the rest stays per-account.
#
# Triggers:
#   - install.sh: one-time after copying scripts
#   - on-ratelimit.sh: before launching claude on the target account, so any
#     newly added MCP servers in the source account propagate
#
# Strategy:
#   1. Read mcpServers from each account's .claude.json, compute union.
#   2. If all accounts ended up empty but a known-good backup exists, restore.
#   3. Write the union back to each account (idempotent — only overwrite on diff).
#   4. Save the union as the new known-good backup.

set -e

LIB="${LIB:-$(dirname "$0")/accounts.sh}"
[ -f "$LIB" ] || LIB="$HOME/.claude/scripts/lib/accounts.sh"
[ -f "$LIB" ] || { echo "sync-mcp-servers: accounts.sh not found" >&2; exit 1; }
source "$LIB"

command -v jq >/dev/null 2>&1 || { echo "sync-mcp-servers: jq not found" >&2; exit 1; }

BACKUP="$HOME/.claude-accounts-mcp-backup.json"

# Collect all account dirs
ACCT_DIRS=()
while read -r id; do
  d=$(account_dir "$id")
  [ -n "$d" ] && ACCT_DIRS+=("$d")
done < <(account_ids)

[ ${#ACCT_DIRS[@]} -eq 0 ] && { echo "sync-mcp-servers: no accounts" >&2; exit 0; }

# Compute union of mcpServers across all .claude.json files
UNION_TMP=$(mktemp)
echo '{}' > "$UNION_TMP"
for d in "${ACCT_DIRS[@]}"; do
  f="$d/.claude.json"
  [ -f "$f" ] || continue
  if jq -s '.[0] * (.[1].mcpServers // {})' "$UNION_TMP" "$f" > "$UNION_TMP.new" 2>/dev/null; then
    mv "$UNION_TMP.new" "$UNION_TMP"
  else
    rm -f "$UNION_TMP.new"
    echo "sync-mcp-servers: failed to parse $f, skipping" >&2
  fi
done

UNION=$(cat "$UNION_TMP")
COUNT=$(echo "$UNION" | jq 'length' 2>/dev/null || echo 0)

# If all accounts ended up empty but backup has servers, restore from backup
if [ "$COUNT" = "0" ] && [ -f "$BACKUP" ]; then
  BACKUP_COUNT=$(jq 'length' "$BACKUP" 2>/dev/null || echo 0)
  if [ "$BACKUP_COUNT" -gt 0 ]; then
    UNION=$(cat "$BACKUP")
    COUNT="$BACKUP_COUNT"
    echo "sync-mcp-servers: all accounts empty, restoring from $BACKUP ($BACKUP_COUNT entries)"
  fi
fi

KEYS=$(echo "$UNION" | jq -r 'keys | join(", ")' 2>/dev/null || echo "")
echo "sync-mcp-servers: union = ${KEYS:-(empty)}"

# Apply union back to each .claude.json (idempotent, atomic per file)
for d in "${ACCT_DIRS[@]}"; do
  f="$d/.claude.json"
  [ -f "$f" ] || continue
  TMP2=$(mktemp)
  if jq --argjson m "$UNION" '.mcpServers = $m' "$f" > "$TMP2" 2>/dev/null; then
    if ! cmp -s "$TMP2" "$f"; then
      mv "$TMP2" "$f"
      echo "  synced: $f"
    else
      rm -f "$TMP2"
    fi
  else
    rm -f "$TMP2"
    echo "  skip (parse fail): $f" >&2
  fi
done

# Save backup if non-empty (so future resets can be recovered)
if [ "$COUNT" -gt 0 ]; then
  echo "$UNION" > "$BACKUP"
fi

rm -f "$UNION_TMP"
