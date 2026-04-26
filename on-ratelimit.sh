#!/bin/bash
# Claude Code Account Switcher — Rate Limit Hook
# On rate limit: open new session with alternate CLAUDE_CONFIG_DIR.
#
# Supports N accounts via manifest at ~/.claude-accounts.json
# (falls back to default 2-account setup if manifest absent).
#
# Each CLAUDE_CONFIG_DIR has fully isolated credentials:
#   - macOS: separate Keychain entries ("Claude Code-credentials-<hash>")
#   - Linux: separate ~/.claude*/.credentials.json files
#
# Setup:
#   1. Login once per config dir:
#        claude login
#        CLAUDE_CONFIG_DIR=~/.claude-account2 claude login
#   2. Register hook in ~/.claude/settings.json
#
# Requires: jq, python3

unset NODE_OPTIONS 2>/dev/null || true

# Source account manifest helper
LIB="$HOME/.claude/scripts/lib/accounts.sh"
[ -f "$LIB" ] && source "$LIB" || {
  # Inline fallback for backward-compat 2-account setup
  accounts_list() {
    printf "1\t%s\tdefault\n" "$HOME/.claude"
    printf "2\t%s\tsecondary\n" "${CLAUDE_CONFIG_DIR_2:-$HOME/.claude-account2}"
  }
  account_dir() {
    while IFS=$'\t' read -r id dir label; do
      [ "$id" = "$1" ] && { echo "$dir"; return; }
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
}

INPUT=$(cat)
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

# Rotate payload log if > 1MB
if [ -f "$DEBUG_FILE" ] && [ "$(stat -c %s "$DEBUG_FILE" 2>/dev/null || stat -f %z "$DEBUG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$DEBUG_FILE" "${DEBUG_FILE}.old" 2>/dev/null || true
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] source=$HOOK_SOURCE payload=$INPUT" >> "$DEBUG_FILE"

# Recover error_type and uuid from transcript if missing
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

# Dedup
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
STATE_FILE="/tmp/claude_active_account"
TMUX_BIN="${TMUX_BIN:-$(command -v tmux 2>/dev/null || echo '')}"
RESUME_MESSAGE="${CLAUDE_RESUME_MESSAGE:-Rate limit으로 계정이 전환되었습니다. 이전 작업을 이어서 진행해주세요.}"

CURRENT_ID=$(account_current_id)
NOW=$(date +%s)

# Cross-platform notification
notify() {
  local msg="$1" title="$2"
  command -v osascript >/dev/null 2>&1 && osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null || true
  command -v notify-send >/dev/null 2>&1 && notify-send "$title" "$msg" 2>/dev/null || true
  local cmux_bin="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
  [ -x "$cmux_bin" ] && "$cmux_bin" display-message "$msg" 2>/dev/null || true
}

# Pick next available account from manifest, excluding current and rate-limited.
# Echoes the chosen account id, or empty if all are exhausted.
pick_next_account() {
  local exclude="$1"
  local picker="$HOME/.claude/scripts/pick-account.sh"
  if [ -x "$picker" ]; then
    local choice
    choice=$(bash "$picker" --no-cache 2>/dev/null)
    [ -n "$choice" ] && [ "$choice" != "$exclude" ] && { echo "$choice"; return; }
  fi
  # Fallback: first non-excluded, non-rate-limited account from manifest
  while read -r id; do
    [ "$id" = "$exclude" ] && continue
    local rl_file="/tmp/claude_ratelimit_account${id}"
    if [ -f "$rl_file" ]; then
      local rl_ts=$(cat "$rl_file" 2>/dev/null || echo 0)
      [ $((NOW - rl_ts)) -lt "$COOLDOWN" ] && continue
    fi
    echo "$id"; return
  done < <(account_ids)
}

start_resume_session() {
  local name="$1"
  local target_id="$2"
  local target_config=$(account_dir "$target_id")
  local source_config=$(account_dir "$CURRENT_ID")

  [ -z "$target_config" ] && { log "ABORT: cannot resolve config dir for account $target_id"; return 1; }

  # Copy session's history.jsonl entries to target before launching `claude -r`
  # (target without history fallbacks to onboarding and wipes .claude.json)
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

  # Safety gate: refuse to launch if target .claude.json is missing/tiny
  local target_profile="$target_config/.claude.json"
  local profile_size=0
  [ -f "$target_profile" ] && profile_size=$(stat -c %s "$target_profile" 2>/dev/null || stat -f %z "$target_profile" 2>/dev/null || echo 0)
  if [ "$profile_size" -lt 2048 ]; then
    log "ABORT: target .claude.json missing or too small (size=$profile_size). Refusing to launch."
    notify "Account switch aborted — $target_config/.claude.json missing. Run claude there manually once to recover." "Claude Code Account Switcher"
    return 1
  fi

  local script="/tmp/claude-resume-$$.sh"
  cat > "$script" << RESUME_EOF
#!/bin/bash
cd "${CWD:-$HOME}"
CLAUDE_CONFIG_DIR=$target_config claude --dangerously-skip-permissions -r $SESSION_ID
RESUME_EOF
  chmod +x "$script"

  # Prefer cmux
  local cmux_bin="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
  if [ -x "$cmux_bin" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    local new_result new_surface
    new_result=$("$cmux_bin" new-surface --workspace "$CMUX_WORKSPACE_ID" 2>&1 || true)
    new_surface=$(echo "$new_result" | grep -oE "surface:[0-9]+" | head -1)
    if [ -n "$new_surface" ]; then
      sleep 2
      "$cmux_bin" send-key --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "enter" 2>/dev/null || true
      sleep 1
      "$cmux_bin" send --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "bash $script" 2>/dev/null || true
      "$cmux_bin" send-key --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "enter" 2>/dev/null || true
      ( sleep 15 && \
        "$cmux_bin" send --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "$RESUME_MESSAGE" 2>/dev/null && \
        "$cmux_bin" send-key --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "enter" 2>/dev/null \
      ) &
      log "cmux tab created: $new_surface with account${target_id} via $script"
      return 0
    fi
  fi

  # tmux: split current pane > new window > detached session
  if [ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ]; then
    local source_pane="${TMUX_PANE:-}"
    if [ -n "$source_pane" ]; then
      local new_pane
      new_pane=$("$TMUX_BIN" split-window -h -t "$source_pane" -c "${CWD:-$HOME}" -P -F '#{pane_id}' "bash $script" 2>/dev/null || true)
      if [ -n "$new_pane" ]; then
        ( sleep 15 && \
          "$TMUX_BIN" send-keys -t "$new_pane" "$RESUME_MESSAGE" Enter 2>/dev/null \
        ) &
        log "tmux pane '$new_pane' split for account${target_id} via $script"
        return 0
      fi
    fi

    local target_session=""
    [ -n "${TMUX:-}" ] && target_session=$("$TMUX_BIN" display-message -p '#S' 2>/dev/null || true)
    if [ -n "$target_session" ]; then
      local wname="failover-acct${target_id}"
      "$TMUX_BIN" new-window -t "$target_session" -n "$wname" -c "${CWD:-$HOME}" "bash $script"
      ( sleep 15 && \
        "$TMUX_BIN" send-keys -t "${target_session}:${wname}" "$RESUME_MESSAGE" Enter 2>/dev/null \
      ) &
      log "tmux window '$wname' added for account${target_id} via $script"
      return 0
    fi

    "$TMUX_BIN" kill-session -t "$name" 2>/dev/null || true
    "$TMUX_BIN" new-session -d -s "$name" -c "${CWD:-$HOME}" "bash $script"
    ( sleep 15 && \
      "$TMUX_BIN" send-keys -t "$name" "$RESUME_MESSAGE" Enter 2>/dev/null \
    ) &
    log "tmux detached session '$name' created with account${target_id} via $script"
    return 0
  fi

  log "No cmux or tmux available. Resume manually: bash $script"
  notify "Rate limit switched to account${target_id}. Run manually: bash $script" "Claude Code"
}

# Mark current account as rate-limited
echo "$NOW" > "/tmp/claude_ratelimit_account${CURRENT_ID}"

# Find next available account (excluding current)
NEXT_ID=$(pick_next_account "$CURRENT_ID")

if [ -n "$NEXT_ID" ]; then
  # --- Switch to next account ---
  echo "$NEXT_ID" > "$STATE_FILE"
  rm -f "/tmp/claude_ratelimit_account${NEXT_ID}"
  log "Switched: account${CURRENT_ID} → account${NEXT_ID} | config dir: $(account_dir "$NEXT_ID")"
  notify "Rate limit hit. Switching account${CURRENT_ID}→${NEXT_ID}." "Claude Code Account Switcher"
  start_resume_session "claude-failover" "$NEXT_ID"
  log "Resume session created for account${NEXT_ID}"
else
  # --- All accounts exhausted ---
  OLD_PID=$(cat /tmp/claude_resume_pid 2>/dev/null || echo "")
  [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null || true

  # Find earliest-rate-limited account (will recover first)
  RECOVER_ID=""
  RECOVER_TIME=$NOW
  while read -r id; do
    rl_file="/tmp/claude_ratelimit_account${id}"
    [ ! -f "$rl_file" ] && continue
    ts=$(cat "$rl_file" 2>/dev/null || echo "$NOW")
    if [ -z "$RECOVER_ID" ] || [ "$ts" -lt "$RECOVER_TIME" ]; then
      RECOVER_ID="$id"; RECOVER_TIME="$ts"
    fi
  done < <(account_ids)

  RECOVER_ID="${RECOVER_ID:-1}"
  WAIT_SECS=$(( RECOVER_TIME + COOLDOWN - NOW ))
  [ "$WAIT_SECS" -lt 60 ] && WAIT_SECS=60
  WAIT_MINS=$(( WAIT_SECS / 60 ))

  echo "$RECOVER_ID" > "$STATE_FILE"
  notify "All ${HOOK_SOURCE:-} accounts exhausted. Auto-resume in ~${WAIT_MINS}min." "Claude Code"

  RECOVER_CONFIG=$(account_dir "$RECOVER_ID")
  nohup bash -c "
    sleep $WAIT_SECS
    rm -f /tmp/claude_ratelimit_account${RECOVER_ID}

    RESUME_CMD=\$(cat /tmp/claude_resume_command 2>/dev/null || echo '')
    if [ -n \"\$RESUME_CMD\" ]; then
      eval \"\$RESUME_CMD\"
      rm -f /tmp/claude_resume_command
    elif [ -n '$TMUX_BIN' ] && [ -x '$TMUX_BIN' ]; then
      '$TMUX_BIN' kill-session -t claude-resume 2>/dev/null || true
      '$TMUX_BIN' new-session -d -s claude-resume -c '${CWD:-$HOME}' 'CLAUDE_CONFIG_DIR=$RECOVER_CONFIG claude --dangerously-skip-permissions -r $SESSION_ID'
    fi
    if command -v osascript >/dev/null 2>&1; then
      osascript -e 'display notification \"Recovered (account${RECOVER_ID}). tmux attach -t claude-resume\" with title \"Claude Code\"' 2>/dev/null || true
    fi
    if command -v notify-send >/dev/null 2>&1; then
      notify-send 'Claude Code' 'Recovered (account${RECOVER_ID}). tmux attach -t claude-resume' 2>/dev/null || true
    fi
    rm -f /tmp/claude_resume_pid
  " >/dev/null 2>&1 &
  echo "$!" > /tmp/claude_resume_pid
  log "All accounts exhausted. Will resume account${RECOVER_ID} in ${WAIT_SECS}s."
fi

exit 0
