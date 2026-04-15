#!/bin/bash
# Claude Code Account Switcher — StopFailure Hook
# Automatically switches between Claude Code accounts on rate limit.
#
# Install: Copy to ~/.claude/scripts/ and register in ~/.claude/settings.json
# Requires: jq, tmux (optional, for auto-resume sessions)

INPUT=$(cat)
ERROR_TYPE=$(echo "$INPUT" | jq -r '.error_type // empty' 2>/dev/null || true)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

# Only handle rate_limit errors
[ "$ERROR_TYPE" != "rate_limit" ] && exit 0

# --- Config ---
ACCOUNT2_DIR="${CLAUDE_ACCOUNT2_DIR:-$HOME/.claude-account2}"
COOLDOWN="${CLAUDE_SWITCH_COOLDOWN:-1800}"
TMUX_BIN="${TMUX_BIN:-/opt/homebrew/bin/tmux}"
# ---

STATE_FILE="/tmp/claude_active_account"
CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo "1")
OTHER=$([ "$CURRENT" = "1" ] && echo "2" || echo "1")
NOW=$(date +%s)

# Record rate limit timestamp + session info for resume
echo "$NOW" > "/tmp/claude_ratelimit_account${CURRENT}"
[ -n "$SESSION_ID" ] && echo "$SESSION_ID" > "/tmp/claude_last_session"
[ -n "$CWD" ] && echo "$CWD" > "/tmp/claude_last_cwd"

notify() {
  osascript -e "display notification \"$1\" with title \"$2\"" 2>/dev/null || true
}

start_tmux_session() {
  local name="$1" config_dir="$2" resume_flag="$3"
  command -v "$TMUX_BIN" >/dev/null 2>&1 || return 0
  "$TMUX_BIN" kill-session -t "$name" 2>/dev/null || true

  local cmd="claude"
  [ -n "$resume_flag" ] && cmd="claude --resume $resume_flag"

  local work_dir="${CWD:-$HOME}"
  if [ -n "$config_dir" ]; then
    "$TMUX_BIN" new-session -d -s "$name" -c "$work_dir" \
      "CLAUDE_CONFIG_DIR=$config_dir $cmd"
  else
    "$TMUX_BIN" new-session -d -s "$name" -c "$work_dir" "$cmd"
  fi
}

get_config_dir() {
  [ "$1" = "2" ] && echo "$ACCOUNT2_DIR" || echo ""
}

# Check if other account is also rate-limited
OTHER_RL_TIME=$(cat "/tmp/claude_ratelimit_account${OTHER}" 2>/dev/null || echo "0")
SINCE_OTHER=$(( NOW - OTHER_RL_TIME ))

if [ "$SINCE_OTHER" -lt "$COOLDOWN" ]; then
  # --- Both accounts rate-limited ---

  # Kill previous resume waiter if exists
  OLD_PID=$(cat /tmp/claude_resume_pid 2>/dev/null || echo "")
  [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null || true

  # Pick whichever recovers first
  ACCT1_TIME=$(cat /tmp/claude_ratelimit_account1 2>/dev/null || echo "$NOW")
  ACCT2_TIME=$(cat /tmp/claude_ratelimit_account2 2>/dev/null || echo "$NOW")
  if [ "$ACCT1_TIME" -le "$ACCT2_TIME" ]; then
    RECOVER_ACCT="1"; RECOVER_TIME=$ACCT1_TIME
  else
    RECOVER_ACCT="2"; RECOVER_TIME=$ACCT2_TIME
  fi

  RESUME_AT=$(( RECOVER_TIME + COOLDOWN ))
  WAIT_SECS=$(( RESUME_AT - NOW ))
  [ "$WAIT_SECS" -lt 60 ] && WAIT_SECS=60
  WAIT_MINS=$(( WAIT_SECS / 60 ))

  echo "$RECOVER_ACCT" > "$STATE_FILE"
  notify "Both accounts exhausted. Auto-resume in ~${WAIT_MINS}min." "Claude Code"

  # Background waiter — nohup to survive parent exit
  nohup bash -c "
    sleep $WAIT_SECS
    rm -f /tmp/claude_ratelimit_account${RECOVER_ACCT}

    RESUME_CMD=\$(cat /tmp/claude_resume_command 2>/dev/null || echo '')
    if [ -n \"\$RESUME_CMD\" ]; then
      eval \"\$RESUME_CMD\"
      rm -f /tmp/claude_resume_command
    else
      LAST_SESSION=\$(cat /tmp/claude_last_session 2>/dev/null || echo '')
      CONFIG_DIR=\$([ '$RECOVER_ACCT' = '2' ] && echo '$ACCOUNT2_DIR' || echo '')
      WORK_DIR=\$(cat /tmp/claude_last_cwd 2>/dev/null || echo '$HOME')

      $TMUX_BIN kill-session -t claude-resume 2>/dev/null || true
      if [ -n \"\$CONFIG_DIR\" ]; then
        $TMUX_BIN new-session -d -s claude-resume -c \"\$WORK_DIR\" \"CLAUDE_CONFIG_DIR=\$CONFIG_DIR claude\"
      else
        $TMUX_BIN new-session -d -s claude-resume -c \"\$WORK_DIR\" claude
      fi
      osascript -e 'display notification \"Rate limit recovered. tmux attach -t claude-resume\" with title \"Claude Code\"' 2>/dev/null || true
    fi
    rm -f /tmp/claude_resume_pid
  " >/dev/null 2>&1 &
  echo "$!" > /tmp/claude_resume_pid

else
  # --- Other account available — switch ---
  echo "$OTHER" > "$STATE_FILE"
  notify "Switched to account${OTHER}." "Claude Code"
  start_tmux_session "claude-failover" "$(get_config_dir $OTHER)" ""
fi

exit 0
