#!/bin/bash
# Claude Code Account Switcher — StopFailure Hook
# On rate limit: open new session with alternate CLAUDE_CONFIG_DIR
#
# Claude Code automatically creates separate Keychain entries per config dir
# (e.g., "Claude Code-credentials-33351ebb" for ~/.claude-account2)
# so NO manual Keychain manipulation is needed.
#
# Setup:
#   1. Login once with each config dir: cc → /login (account1), cc2 → /login (account2)
#   2. Register this hook in ~/.claude/settings.json
#
# Requires: jq

# Clear cmux NODE_OPTIONS to prevent temp file errors in child processes
unset NODE_OPTIONS 2>/dev/null || true

INPUT=$(cat)
ERROR_TYPE=$(echo "$INPUT" | jq -r '.error_type // empty' 2>/dev/null || true)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

LOG_FILE="$HOME/.claude/logs/account-switch.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

[ "$ERROR_TYPE" != "rate_limit" ] && { log "StopFailure hook: error_type=$ERROR_TYPE (ignored)"; exit 0; }

log "=== Rate limit detected ==="
log "Env: CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-default} | CMUX_WORKSPACE_ID=${CMUX_WORKSPACE_ID:-none} | TMUX=${TMUX:-none}"

# --- Config ---
COOLDOWN="${CLAUDE_SWITCH_COOLDOWN:-1800}"
CONFIG_DIR_1="$HOME/.claude"
CONFIG_DIR_2="$HOME/.claude-account2"
STATE_FILE="/tmp/claude_active_account"
TMUX_BIN="${TMUX_BIN:-/opt/homebrew/bin/tmux}"
# ---

# Detect current account from CLAUDE_CONFIG_DIR
if [ "${CLAUDE_CONFIG_DIR:-}" = "$CONFIG_DIR_2" ]; then
  CURRENT="2"
else
  CURRENT="1"
fi
OTHER=$([ "$CURRENT" = "1" ] && echo "2" || echo "1")
NOW=$(date +%s)

get_config_dir() {
  [ "$1" = "2" ] && echo "$CONFIG_DIR_2" || echo "$CONFIG_DIR_1"
}

notify() {
  osascript -e "display notification \"$1\" with title \"$2\"" 2>/dev/null || true
  local cmux_bin="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
  [ -x "$cmux_bin" ] && "$cmux_bin" display-message "$1" 2>/dev/null || true
}

start_resume_session() {
  local name="$1"
  local target_config=$(get_config_dir "$OTHER")
  local resume_cmd="CLAUDE_CONFIG_DIR=$target_config claude --dangerously-skip-permissions -r $SESSION_ID"

  # Prefer cmux if available and CMUX_WORKSPACE_ID is set
  local cmux_bin="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
  if [ -x "$cmux_bin" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    local new_result
    new_result=$("$cmux_bin" new-surface --workspace "$CMUX_WORKSPACE_ID" 2>&1 || true)
    local new_surface
    new_surface=$(echo "$new_result" | grep -oE "surface:[0-9]+" | head -1)
    if [ -n "$new_surface" ]; then
      "$cmux_bin" send --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "cd \"${CWD:-$HOME}\" && ${resume_cmd}" 2>/dev/null || true
      "$cmux_bin" send-key --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "enter" 2>/dev/null || true
      # After session loads, send continue message
      ( sleep 10 && \
        "$cmux_bin" send --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "Rate limit으로 계정이 전환되었습니다. 이전 작업을 이어서 진행해주세요." 2>/dev/null && \
        "$cmux_bin" send-key --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "enter" 2>/dev/null \
      ) &
      log "cmux tab created: $new_surface with account${OTHER} (config: $target_config)"
      return 0
    fi
  fi

  # Fallback: tmux
  if command -v "$TMUX_BIN" >/dev/null 2>&1; then
    "$TMUX_BIN" kill-session -t "$name" 2>/dev/null || true
    "$TMUX_BIN" new-session -d -s "$name" -c "${CWD:-$HOME}" "$resume_cmd"
  else
    log "No cmux or tmux available. Resume manually: cd \"${CWD:-$HOME}\" && $resume_cmd"
    notify "Rate limit switched. Run manually: $resume_cmd" "Claude Code"
  fi
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

  RECOVER_CONFIG=$(get_config_dir "$RECOVER_ACCT")
  nohup bash -c "
    sleep $WAIT_SECS
    rm -f /tmp/claude_ratelimit_account${RECOVER_ACCT}

    RESUME_CMD=\$(cat /tmp/claude_resume_command 2>/dev/null || echo '')
    if [ -n \"\$RESUME_CMD\" ]; then
      eval \"\$RESUME_CMD\"
      rm -f /tmp/claude_resume_command
    else
      $TMUX_BIN kill-session -t claude-resume 2>/dev/null || true
      $TMUX_BIN new-session -d -s claude-resume -c '${CWD:-$HOME}' 'CLAUDE_CONFIG_DIR=$RECOVER_CONFIG claude --dangerously-skip-permissions -r $SESSION_ID'
      osascript -e 'display notification \"Recovered (account${RECOVER_ACCT}). tmux attach -t claude-resume\" with title \"Claude Code\"' 2>/dev/null || true
    fi
    rm -f /tmp/claude_resume_pid
  " >/dev/null 2>&1 &
  echo "$!" > /tmp/claude_resume_pid

else
  # --- Switch to other account ---
  echo "$OTHER" > "$STATE_FILE"
  rm -f "/tmp/claude_ratelimit_account${OTHER}"
  log "Switched: account${CURRENT} → account${OTHER} | config dir: $(get_config_dir "$OTHER")"
  notify "Rate limit hit. Switching account${CURRENT}→${OTHER}." "Claude Code Account Switcher"
  start_resume_session "claude-failover"
  log "Resume session created for account${OTHER}"
fi

exit 0
