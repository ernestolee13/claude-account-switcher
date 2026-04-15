#!/bin/bash
# Claude Code Account Switcher — StopFailure Hook
# On rate limit: swap Keychain credentials + open new session to continue
#
# Setup:
#   1. Login to each account and save: bash claude-save-accounts.sh 1 (or 2)
#   2. Register this hook in ~/.claude/settings.json
#
# Requires: jq, security (macOS), tmux

INPUT=$(cat)
ERROR_TYPE=$(echo "$INPUT" | jq -r '.error_type // empty' 2>/dev/null || true)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

[ "$ERROR_TYPE" != "rate_limit" ] && exit 0

# --- Config ---
COOLDOWN="${CLAUDE_SWITCH_COOLDOWN:-1800}"
KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="${USER}"
CRED_DIR="$HOME/.claude"
STATE_FILE="/tmp/claude_active_account"
TMUX_BIN="${TMUX_BIN:-/opt/homebrew/bin/tmux}"
# ---

CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo "1")
OTHER=$([ "$CURRENT" = "1" ] && echo "2" || echo "1")
NOW=$(date +%s)

notify() {
  osascript -e "display notification \"$1\" with title \"$2\"" 2>/dev/null || true
}

save_current_credentials() {
  local cred
  cred=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null || true)
  [ -n "$cred" ] && echo "$cred" > "$CRED_DIR/credentials-account${CURRENT}.json"
}

swap_credentials() {
  local target="$1"
  local cred_file="$CRED_DIR/credentials-account${target}.json"
  [ ! -f "$cred_file" ] && return 1

  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" 2>/dev/null || true
  security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$(cat "$cred_file")" 2>/dev/null

  # Clear statsig cache to prevent rate limit carryover bug (#12786)
  [ -d "$CRED_DIR/statsig" ] && rm -rf "$CRED_DIR/statsig" 2>/dev/null || true
}

start_resume_session() {
  local name="$1"
  command -v "$TMUX_BIN" >/dev/null 2>&1 || return 0
  "$TMUX_BIN" kill-session -t "$name" 2>/dev/null || true
  "$TMUX_BIN" new-session -d -s "$name" -c "${CWD:-$HOME}" \
    "claude -r"
}

# Record rate limit
echo "$NOW" > "/tmp/claude_ratelimit_account${CURRENT}"

# Check other account
OTHER_RL_TIME=$(cat "/tmp/claude_ratelimit_account${OTHER}" 2>/dev/null || echo "0")
SINCE_OTHER=$(( NOW - OTHER_RL_TIME ))

if [ "$SINCE_OTHER" -lt "$COOLDOWN" ]; then
  # --- Both exhausted ---
  OLD_PID=$(cat /tmp/claude_resume_pid 2>/dev/null || echo "")
  [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null || true

  ACCT1_TIME=$(cat /tmp/claude_ratelimit_account1 2>/dev/null || echo "$NOW")
  ACCT2_TIME=$(cat /tmp/claude_ratelimit_account2 2>/dev/null || echo "$NOW")
  if [ "$ACCT1_TIME" -le "$ACCT2_TIME" ]; then
    RECOVER_ACCT="1"; RECOVER_TIME=$ACCT1_TIME
  else
    RECOVER_ACCT="2"; RECOVER_TIME=$ACCT2_TIME
  fi

  WAIT_SECS=$(( RECOVER_TIME + COOLDOWN - NOW ))
  [ "$WAIT_SECS" -lt 60 ] && WAIT_SECS=60
  WAIT_MINS=$(( WAIT_SECS / 60 ))

  echo "$RECOVER_ACCT" > "$STATE_FILE"
  notify "Both accounts exhausted. Auto-resume in ~${WAIT_MINS}min." "Claude Code"

  nohup bash -c "
    sleep $WAIT_SECS
    rm -f /tmp/claude_ratelimit_account${RECOVER_ACCT}

    # Swap to recovered account
    security delete-generic-password -s '$KEYCHAIN_SERVICE' -a '$KEYCHAIN_ACCOUNT' 2>/dev/null || true
    security add-generic-password -s '$KEYCHAIN_SERVICE' -a '$KEYCHAIN_ACCOUNT' -w \"\$(cat '$CRED_DIR/credentials-account${RECOVER_ACCT}.json')\" 2>/dev/null

    # Resume command or tmux session
    RESUME_CMD=\$(cat /tmp/claude_resume_command 2>/dev/null || echo '')
    if [ -n \"\$RESUME_CMD\" ]; then
      eval \"\$RESUME_CMD\"
      rm -f /tmp/claude_resume_command
    else
      $TMUX_BIN kill-session -t claude-resume 2>/dev/null || true
      $TMUX_BIN new-session -d -s claude-resume -c '${CWD:-$HOME}' 'claude -r'
      osascript -e 'display notification \"Recovered. tmux attach -t claude-resume\" with title \"Claude Code\"' 2>/dev/null || true
    fi
    rm -f /tmp/claude_resume_pid
  " >/dev/null 2>&1 &
  echo "$!" > /tmp/claude_resume_pid

else
  # --- Switch to other account ---
  save_current_credentials
  if swap_credentials "$OTHER"; then
    echo "$OTHER" > "$STATE_FILE"
    rm -f "/tmp/claude_ratelimit_account${OTHER}"
    notify "Switched to account${OTHER}. Resuming in tmux..." "Claude Code"
    start_resume_session "claude-failover"
  else
    notify "Account${OTHER} credentials not found. Run: claude-save-accounts.sh ${OTHER}" "Claude Code"
  fi
fi

exit 0
