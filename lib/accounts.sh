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
# If manifest is missing or unreadable, falls back to a built-in 2-account
# default for backward compatibility.

ACCOUNT_MANIFEST="${ACCOUNT_MANIFEST:-$HOME/.claude-accounts.json}"

# Print one "<id>\t<config_dir>\t<label>" line per account, ordered.
# Path tildes are expanded.
accounts_list() {
  if [ -f "$ACCOUNT_MANIFEST" ]; then
    python3 -c "
import json, os, sys
try:
    d = json.load(open('$ACCOUNT_MANIFEST'))
    for a in d.get('accounts', []):
        cd = os.path.expanduser(a.get('config_dir', ''))
        print(f\"{a.get('id','?')}\t{cd}\t{a.get('label','')}\")
except Exception as e:
    sys.exit(1)
" 2>/dev/null && return 0
  fi
  # Fallback: built-in 2-account default
  printf "1\t%s\tdefault\n" "$HOME/.claude"
  printf "2\t%s\tsecondary\n" "${CLAUDE_CONFIG_DIR_2:-$HOME/.claude-account2}"
}

# Get config dir for a given account id, or empty if not found.
account_dir() {
  local target_id="$1"
  while IFS=$'\t' read -r id dir label; do
    [ "$id" = "$target_id" ] && { echo "$dir"; return; }
  done < <(accounts_list)
}

# Get label for a given account id.
account_label() {
  local target_id="$1"
  while IFS=$'\t' read -r id dir label; do
    [ "$id" = "$target_id" ] && { echo "$label"; return; }
  done < <(accounts_list)
}

# Detect current account id from CLAUDE_CONFIG_DIR. Defaults to "1".
account_current_id() {
  local cur="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  while IFS=$'\t' read -r id dir label; do
    [ "$dir" = "$cur" ] && { echo "$id"; return; }
  done < <(accounts_list)
  echo "1"
}

# Print all account ids (newline separated).
account_ids() {
  while IFS=$'\t' read -r id dir label; do
    echo "$id"
  done < <(accounts_list)
}

# Number of configured accounts.
account_count() {
  accounts_list | wc -l | tr -d ' '
}
