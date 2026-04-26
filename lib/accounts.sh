#!/bin/bash
# Account manifest helper - shared by all scripts.
# Source this file: source ~/.claude/scripts/lib/accounts.sh
#
# Manifest format (~/.claude-accounts.json):
# {
#   "accounts": [
#     {"id": 1, "config_dir": "~/.claude", "label": "default"},
#     {"id": 2, "config_dir": "~/.claude-account2", "label": "secondary"}
#   ]
# }
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
  ]
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
