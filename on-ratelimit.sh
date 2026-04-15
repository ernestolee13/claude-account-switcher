#!/bin/bash
# Claude Code Account Switcher — StopFailure Hook
# Automatically switches between Claude Code accounts on rate limit.
#
# Install: Copy to ~/.claude/scripts/ and register in ~/.claude/settings.json
# Requires: jq, tmux (optional, for auto-resume sessions)
#
# Files used:
#   /tmp/claude_active_account         — current active account (1 or 2)
#   /tmp/claude_ratelimit_account{1,2} — timestamp when rate limit hit
#   /tmp/claude_resume_command         — (optional) command to run on recovery
#   /tmp/claude_resume_pid             — PID of background resume waiter

set -euo pipefail

INPUT=$(cat)
ERROR_TYPE=$(echo "$INPUT" | jq -r '.error_type // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# Only handle rate_limit errors
[ "$ERROR_TYPE" != "rate_limit" ] && exit 0

# --- Config (edit these) ---
ACCOUNT2_DIR="${CLAUDE_ACCOUNT2_DIR:-$HOME/.claude-account2}"
COOLDOWN=1800          # seconds to assume rate limit lasts (30 min)
TMUX="${TMUX_BIN:-/opt/homebrew/bin/tmux}"
# ---

STATE_FILE="/tmp/claude_active_account"
CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo "1")
OTHER=$( [ "$CURRENT" = "1" ] && echo "2" || echo "1" )
NOW=$(date +%s)

# Record this account's rate limit timestamp
echo "$NOW" > "/tmp/claude_ratelimit_account${CURRENT}"

# Check if other account is also rate-limited (within COOLDOWN window)
OTHER_RL_TIME=$(cat "/tmp/claude_ratelimit_account${OTHER}" 2>/dev/null || echo "0")
SINCE_OTHER=$(( NOW - OTHER_RL_TIME ))

notify() {
  osascript -e "display notification \"$1\" with title \"$2\"" 2>/dev/null || true
}

run_claude_session() {
  local acct="$1" dir="$2" name="$3"
  command -v "$TMUX" >/dev/null 2>&1 || return 0
  "$TMUX" kill-session -t "$name" 2>/dev/null || true
  if [ -n "$dir" ]; then
    "$TMUX" new-session -d -s "$name" -c "${CWD:-$HOME}" \
      "CLAUDE_CONFIG_DIR=$dir claude"
  else
    "$TMUX" new-session -d -s "$name" -c "${CWD:-$HOME}" \
      "claude"
  fi
}

get_config_dir() {
  [ "$1" = "2" ] && echo "$ACCOUNT2_DIR" || echo ""
}

if [ "$SINCE_OTHER" -lt "$COOLDOWN" ]; then
  # --- Both accounts rate-limited ---

  # Kill any existing resume waiter to prevent duplicates
  OLD_PID=$(cat /tmp/claude_resume_pid 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
  fi

  # Pick account that will recover first
  ACCT1_TIME=$(cat /tmp/claude_ratelimit_account1 2>/dev/null || echo "$NOW")
  ACCT2_TIME=$(cat /tmp/claude_ratelimit_account2 2>/dev/null || echo "$NOW")
  if [ "$ACCT1_TIME" -le "$ACCT2_TIME" ]; then
    RECOVER_ACCT="1"
    RECOVER_TIME=$ACCT1_TIME
  else
    RECOVER_ACCT="2"
    RECOVER_TIME=$ACCT2_TIME
  fi

  RESUME_AT=$(( RECOVER_TIME + COOLDOWN ))
  WAIT_SECS=$(( RESUME_AT - NOW ))
  [ "$WAIT_SECS" -lt 60 ] && WAIT_SECS=60
  WAIT_MINS=$(( WAIT_SECS / 60 ))

  echo "$RECOVER_ACCT" > "$STATE_FILE"
  notify "Both accounts exhausted. Auto-resume in ~${WAIT_MINS}min (account${RECOVER_ACCT})." "Claude Code — Rate Limit"

  # Background waiter for auto-resume
  (
    sleep "$WAIT_SECS"

    # Clear rate limit record for recovered account
    rm -f "/tmp/claude_ratelimit_account${RECOVER_ACCT}"

    # Execute resume command if set, otherwise open tmux session
    RESUME_CMD=$(cat /tmp/claude_resume_command 2>/dev/null || echo "")
    if [ -n "$RESUME_CMD" ]; then
      eval "$RESUME_CMD"
      rm -f /tmp/claude_resume_command
    else
      CONFIG_DIR=$([ "$RECOVER_ACCT" = "2" ] && echo "$ACCOUNT2_DIR" || echo "")
      run_claude_session "$RECOVER_ACCT" "$CONFIG_DIR" "claude-resume"
      notify "Rate limit recovered. tmux attach -t claude-resume" "Claude Code"
    fi

    rm -f /tmp/claude_resume_pid
  ) &
  echo "$!" > /tmp/claude_resume_pid
  disown

else
  # --- Other account available — switch ---
  echo "$OTHER" > "$STATE_FILE"
  notify "Switched to account${OTHER}." "Claude Code — Rate Limit"

  # Open tmux session for interactive use
  CONFIG_DIR=$(get_config_dir "$OTHER")
  run_claude_session "$OTHER" "$CONFIG_DIR" "claude-failover"
fi

exit 0
