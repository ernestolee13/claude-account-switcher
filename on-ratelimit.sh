#!/bin/bash
# Claude Code Account Switcher — StopFailure Hook
# On rate limit: open new session with alternate CLAUDE_CONFIG_DIR
#
# Claude Code automatically isolates credentials per config dir:
#   - macOS: separate Keychain entries ("Claude Code-credentials-<hash>")
#   - Linux: separate ~/.claude[-account2]/.credentials.json files
# so NO manual credential manipulation is needed.
#
# Setup:
#   1. Login once per config dir:
#        claude login
#        CLAUDE_CONFIG_DIR=~/.claude-account2 claude login
#   2. Register this hook in ~/.claude/settings.json
#
# Requires: jq

# Clear cmux NODE_OPTIONS to prevent temp file errors in child processes
unset NODE_OPTIONS 2>/dev/null || true

INPUT=$(cat)
# Claude Code 2.1.x StopFailure payload uses the key `.error` (not `.error_type`)
# — this was the root cause of the auto-switch never firing. Accept both.
ERROR_TYPE=$(echo "$INPUT" | jq -r '.error_type // .error // empty' 2>/dev/null || true)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
HOOK_SOURCE=$(echo "$INPUT" | jq -r '.source // .hook_event_name // "unknown"' 2>/dev/null || true)
RL_UUID=$(echo "$INPUT" | jq -r '.rate_limit_uuid // empty' 2>/dev/null || true)

LOG_FILE="$HOME/.claude/logs/account-switch.log"
DEBUG_FILE="$HOME/.claude/logs/account-switch-payloads.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# Rotate payload log if > 1MB to prevent unbounded growth
if [ -f "$DEBUG_FILE" ] && [ "$(stat -c %s "$DEBUG_FILE" 2>/dev/null || stat -f %z "$DEBUG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$DEBUG_FILE" "${DEBUG_FILE}.old" 2>/dev/null || true
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] source=$HOOK_SOURCE payload=$INPUT" >> "$DEBUG_FILE"

# Extract the rate_limit UUID from the transcript's last assistant entry.
# This is used both to (a) recover the error_type when the hook payload doesn't
# include it and (b) populate RL_UUID for dedup so we don't switch twice on
# the same event when multiple hook paths fire.
if [ -z "$RL_UUID" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  RECOVERED=$(tail -n 300 "$TRANSCRIPT_PATH" 2>/dev/null | python3 -c '
import json, sys
last = None
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except: continue
    if d.get("type") == "assistant": last = d
if last is not None and last.get("error") == "rate_limit":
    uid = last.get("uuid", "")
    print(f"rate_limit\t{uid}")
' 2>/dev/null)
  if [ -n "$RECOVERED" ]; then
    IFS=$'\t' read -r RECOVERED_ERR RECOVERED_UUID <<< "$RECOVERED"
    [ "$ERROR_TYPE" != "rate_limit" ] && ERROR_TYPE="$RECOVERED_ERR" && \
      log "Recovered error_type=$ERROR_TYPE from transcript (source=$HOOK_SOURCE)"
    RL_UUID="$RECOVERED_UUID"
  fi
fi

[ "$ERROR_TYPE" != "rate_limit" ] && { log "$HOOK_SOURCE: error_type=$ERROR_TYPE (ignored)"; exit 0; }

# Dedup: avoid re-triggering on the same rate_limit event
SEEN_FILE="/tmp/claude_ratelimit_seen_uuids"
touch "$SEEN_FILE" 2>/dev/null || true
if [ -n "$RL_UUID" ] && grep -q "^${RL_UUID}$" "$SEEN_FILE" 2>/dev/null; then
  log "$HOOK_SOURCE: rate_limit uuid=$RL_UUID already processed (skip)"
  exit 0
fi
[ -n "$RL_UUID" ] && echo "$RL_UUID" >> "$SEEN_FILE"

log "=== Rate limit detected (via $HOOK_SOURCE, uuid=$RL_UUID) ==="
log "Env: CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-default} | CMUX_WORKSPACE_ID=${CMUX_WORKSPACE_ID:-none} | TMUX=${TMUX:-none}"

# --- Config ---
COOLDOWN="${CLAUDE_SWITCH_COOLDOWN:-1800}"
CONFIG_DIR_1="$HOME/.claude"
CONFIG_DIR_2="${CLAUDE_CONFIG_DIR_2:-$HOME/.claude-account2}"
STATE_FILE="/tmp/claude_active_account"
# Auto-detect tmux binary (macOS homebrew, Linux system path, etc.)
TMUX_BIN="${TMUX_BIN:-$(command -v tmux 2>/dev/null || echo '')}"
# Resume message (override via env)
RESUME_MESSAGE="${CLAUDE_RESUME_MESSAGE:-Rate limit으로 계정이 전환되었습니다. 이전 작업을 이어서 진행해주세요.}"
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

# Cross-platform desktop notification (macOS/Linux). Silent if neither tool exists.
notify() {
  local msg="$1" title="$2"
  # macOS
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null || true
  fi
  # Linux (libnotify)
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$msg" 2>/dev/null || true
  fi
  # cmux (if available)
  local cmux_bin="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
  [ -x "$cmux_bin" ] && "$cmux_bin" display-message "$msg" 2>/dev/null || true
}

start_resume_session() {
  local name="$1"
  local target_config=$(get_config_dir "$OTHER")
  local source_config=$(get_config_dir "$CURRENT")

  # Cross-account session-resume prep:
  #   - transcripts are shared via projects/ symlink, so the .jsonl exists
  #   - BUT history.jsonl is per-config-dir; if target doesn't know the session,
  #     `claude -r` falls back to first-time onboarding and WIPES target's
  #     .claude.json to a stub (observed data-loss bug on 2026-04-23).
  # Mitigation: copy the session's history entries into target's history.jsonl
  # before launching, and bail out (with a clear log) if target has no valid
  # .claude.json to resume into.
  if [ -n "$SESSION_ID" ]; then
    local src_hist="$source_config/history.jsonl"
    local dst_hist="$target_config/history.jsonl"
    if [ -f "$src_hist" ]; then
      local matched
      matched=$(grep -c "\"sessionId\":\"$SESSION_ID\"" "$src_hist" 2>/dev/null || echo 0)
      if [ "$matched" -gt 0 ] && ! grep -q "\"sessionId\":\"$SESSION_ID\"" "$dst_hist" 2>/dev/null; then
        grep "\"sessionId\":\"$SESSION_ID\"" "$src_hist" >> "$dst_hist"
        log "Copied $matched history.jsonl entries for session=$SESSION_ID: $src_hist → $dst_hist"
      fi
    fi
  fi

  # Safety gate: refuse to launch if target .claude.json is missing/tiny.
  # A stub <2KB typically lacks oauthAccount/projects and will trigger the
  # onboarding overwrite loop.
  local target_profile="$target_config/.claude.json"
  local profile_size=0
  [ -f "$target_profile" ] && profile_size=$(stat -c %s "$target_profile" 2>/dev/null || stat -f %z "$target_profile" 2>/dev/null || echo 0)
  if [ "$profile_size" -lt 2048 ]; then
    log "ABORT: target .claude.json missing or too small (size=$profile_size). Refusing to launch to avoid corruption."
    notify "Account switch aborted — ~/.claude${OTHER/1/}/.claude.json missing. Run claude manually once to recover." "Claude Code Account Switcher"
    return 1
  fi

  # Write resume script to avoid command garbling in send-to-tty cases
  local script="/tmp/claude-resume-$$.sh"
  cat > "$script" << RESUME_EOF
#!/bin/bash
cd "${CWD:-$HOME}"
CLAUDE_CONFIG_DIR=$target_config claude --dangerously-skip-permissions -r $SESSION_ID
RESUME_EOF
  chmod +x "$script"

  # Prefer cmux if available and CMUX_WORKSPACE_ID is set
  local cmux_bin="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
  if [ -x "$cmux_bin" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    local new_result
    new_result=$("$cmux_bin" new-surface --workspace "$CMUX_WORKSPACE_ID" 2>&1 || true)
    local new_surface
    new_surface=$(echo "$new_result" | grep -oE "surface:[0-9]+" | head -1)
    if [ -n "$new_surface" ]; then
      # Wait for shell init, dismiss any prompts, then run script
      sleep 2
      "$cmux_bin" send-key --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "enter" 2>/dev/null || true
      sleep 1
      "$cmux_bin" send --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "bash $script" 2>/dev/null || true
      "$cmux_bin" send-key --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "enter" 2>/dev/null || true
      # After session loads, send continue message
      ( sleep 15 && \
        "$cmux_bin" send --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "$RESUME_MESSAGE" 2>/dev/null && \
        "$cmux_bin" send-key --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "enter" 2>/dev/null \
      ) &
      log "cmux tab created: $new_surface with account${OTHER} via $script"
      return 0
    fi
  fi

  # Fallback: tmux
  if [ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ]; then
    # Preferred UX: split the SAME pane where the rate-limited claude is running,
    # so the user visually sees the old (exhausted) session next to the new
    # (account${OTHER}) resume. Focus auto-moves to the new pane.
    local source_pane="${TMUX_PANE:-}"
    if [ -n "$source_pane" ]; then
      local new_pane
      new_pane=$("$TMUX_BIN" split-window -h -t "$source_pane" -c "${CWD:-$HOME}" -P -F '#{pane_id}' "bash $script" 2>/dev/null || true)
      if [ -n "$new_pane" ]; then
        ( sleep 15 && \
          "$TMUX_BIN" send-keys -t "$new_pane" "$RESUME_MESSAGE" Enter 2>/dev/null \
        ) &
        log "tmux pane '$new_pane' split from '$source_pane' for account${OTHER} via $script"
        return 0
      fi
    fi

    # Fallback A: add a window to the existing session (no TMUX_PANE available)
    local target_session=""
    if [ -n "${TMUX:-}" ]; then
      target_session=$("$TMUX_BIN" display-message -p '#S' 2>/dev/null || true)
    fi
    if [ -n "$target_session" ]; then
      local wname="failover-acct${OTHER}"
      "$TMUX_BIN" new-window -t "$target_session" -n "$wname" -c "${CWD:-$HOME}" "bash $script"
      ( sleep 15 && \
        "$TMUX_BIN" send-keys -t "${target_session}:${wname}" "$RESUME_MESSAGE" Enter 2>/dev/null \
      ) &
      log "tmux window '$wname' added to session '$target_session' for account${OTHER} via $script"
      return 0
    fi

    # Fallback B: detached session (user must `tmux attach -t $name`)
    "$TMUX_BIN" kill-session -t "$name" 2>/dev/null || true
    "$TMUX_BIN" new-session -d -s "$name" -c "${CWD:-$HOME}" "bash $script"
    ( sleep 15 && \
      "$TMUX_BIN" send-keys -t "$name" "$RESUME_MESSAGE" Enter 2>/dev/null \
    ) &
    log "tmux detached session '$name' created with account${OTHER} via $script"
    return 0
  fi

  # Last resort: log manual instructions
  log "No cmux or tmux available. Resume manually: bash $script"
  notify "Rate limit switched to account${OTHER}. Run manually: bash $script" "Claude Code"
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
    elif [ -n '$TMUX_BIN' ] && [ -x '$TMUX_BIN' ]; then
      '$TMUX_BIN' kill-session -t claude-resume 2>/dev/null || true
      '$TMUX_BIN' new-session -d -s claude-resume -c '${CWD:-$HOME}' 'CLAUDE_CONFIG_DIR=$RECOVER_CONFIG claude --dangerously-skip-permissions -r $SESSION_ID'
    fi
    # Notify (cross-platform)
    if command -v osascript >/dev/null 2>&1; then
      osascript -e 'display notification \"Recovered (account${RECOVER_ACCT}). tmux attach -t claude-resume\" with title \"Claude Code\"' 2>/dev/null || true
    fi
    if command -v notify-send >/dev/null 2>&1; then
      notify-send 'Claude Code' 'Recovered (account${RECOVER_ACCT}). tmux attach -t claude-resume' 2>/dev/null || true
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
