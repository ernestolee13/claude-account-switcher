#!/bin/bash
# Account manifest helper - shared by all scripts.
# Source this file: source ~/.claude/scripts/lib/accounts.sh
#
# Manifest format (~/.claude-accounts.json):
# {
#   "accounts": [
#     {"id": 1, "config_dir": "~/.claude", "label": "default"},
#     {"id": 2, "config_dir": "~/.claude-account2", "label": "secondary"}
#   ],
#   "sync_mcp_servers": true
# }
#
# Top-level options:
#   sync_mcp_servers (bool, default true): mirror mcpServers across all
#     account .claude.json files at install + before each rate-limit
#     switch. Set false to keep MCP lists per-account.
#
# If the manifest doesn't exist, this helper auto-creates a default
# 2-account manifest so first-run scripts work without explicit install.

ACCOUNT_MANIFEST="${ACCOUNT_MANIFEST:-$HOME/.claude-accounts.json}"

# Auto-create default manifest if missing (single source of truth, no inline fallback)
if [ ! -f "$ACCOUNT_MANIFEST" ]; then
  cat > "$ACCOUNT_MANIFEST" 2>/dev/null << EOF
{
  "accounts": [
    {"id": 1, "config_dir": "$HOME/.claude", "label": "default"},
    {"id": 2, "config_dir": "${CLAUDE_CONFIG_DIR_2:-$HOME/.claude-account2}", "label": "secondary"}
  ],
  "sync_mcp_servers": true
}
EOF
fi

# Print "<id>\t<config_dir>\t<label>" lines, ordered.
accounts_list() {
  python3 -c "
import json, os, sys
try:
    d = json.load(open('$ACCOUNT_MANIFEST'))
    for a in d.get('accounts', []):
        cd = os.path.expanduser(a.get('config_dir', ''))
        print(f\"{a.get('id','?')}\t{cd}\t{a.get('label','')}\")
except Exception:
    sys.exit(1)
" 2>/dev/null
}

account_dir() {
  local target_id="$1"
  while IFS=$'\t' read -r id dir label; do
    [ "$id" = "$target_id" ] && { echo "$dir"; return; }
  done < <(accounts_list)
}

account_label() {
  local target_id="$1"
  while IFS=$'\t' read -r id dir label; do
    [ "$id" = "$target_id" ] && { echo "$label"; return; }
  done < <(accounts_list)
}

account_current_id() {
  local cur="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  while IFS=$'\t' read -r id dir label; do
    [ "$dir" = "$cur" ] && { echo "$id"; return; }
  done < <(accounts_list)
  echo "1"
}

account_ids() {
  while IFS=$'\t' read -r id dir label; do
    echo "$id"
  done < <(accounts_list)
}

account_count() {
  accounts_list | wc -l | tr -d ' '
}

# Read a top-level boolean option from the manifest.
# Returns 0 (true) if the value is true/1, 1 (false) otherwise.
# Defaults to the second arg ("true" or "false") when key is missing.
accounts_get_bool() {
  local key="$1" default="${2:-true}"
  local val
  val=$(python3 -c "
import json
try:
    d = json.load(open('$ACCOUNT_MANIFEST'))
    v = d.get('$key', None)
    if v is None: print('$default')
    elif isinstance(v, bool): print('true' if v else 'false')
    else: print(str(v).lower())
except Exception:
    print('$default')
" 2>/dev/null)
  case "$val" in
    true|1|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Convenience: should we mirror mcpServers across accounts?
accounts_sync_mcp_enabled() {
  accounts_get_bool sync_mcp_servers true
}
