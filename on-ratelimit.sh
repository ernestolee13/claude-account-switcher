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

# Source account manifest helper (auto-creates default manifest if missing)
LIB="$HOME/.claude/scripts/lib/accounts.sh"
if [ ! -f "$LIB" ]; then
  echo "ERROR: $LIB not found. Run install.sh first." >&2
  exit 1
fi
source "$LIB"

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

NOW=$(date +%s)

# Dedup A: by UUID. Claude Code 2.1.x sometimes fires StopFailure with no
# UUID at all — synthesize one from session_id + minute bucket so empty-UUID
# duplicates still get filtered.
if [ -z "$RL_UUID" ] && [ -n "$SESSION_ID" ]; then
  RL_UUID="nouuid-${SESSION_ID}-$(date -u +%Y%m%dT%H%M)"
  log "$HOOK_SOURCE: no UUID in payload; synthesized dedup key: $RL_UUID"
fi
SEEN_FILE="/tmp/claude_ratelimit_seen_uuids"
touch "$SEEN_FILE" 2>/dev/null || true
if [ -n "$RL_UUID" ] && grep -q "^${RL_UUID}$" "$SEEN_FILE" 2>/dev/null; then
  log "$HOOK_SOURCE: rate_limit uuid=$RL_UUID already processed (skip)"
  exit 0
fi
[ -n "$RL_UUID" ] && echo "$RL_UUID" >> "$SEEN_FILE"

# Dedup B: per-session 60s switch cooldown. When the same Stop event fires
# twice (e.g., once with synthetic UUID, once with the real UUID) the
# UUID-only dedup can't catch both — this ensures we never open more than
# one failover surface per session-minute.
if [ -n "$SESSION_ID" ]; then
  LAST_SWITCH_FILE="/tmp/claude_last_switch_${SESSION_ID}"
  if [ -f "$LAST_SWITCH_FILE" ]; then
    LAST_TS=$(cat "$LAST_SWITCH_FILE" 2>/dev/null || echo 0)
    SINCE_LAST=$((NOW - LAST_TS))
    if [ "$SINCE_LAST" -lt 60 ]; then
      log "$HOOK_SOURCE: session=$SESSION_ID switched ${SINCE_LAST}s ago (<60s) — skip"
      exit 0
    fi
  fi
fi

log "=== Rate limit detected (via $HOOK_SOURCE, uuid=$RL_UUID) ==="
log "Env: CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-default} | CMUX_WORKSPACE_ID=${CMUX_WORKSPACE_ID:-none} | TMUX=${TMUX:-none}"

# --- Config ---
# Default 18000s (5h, matches Claude's 5-hour usage window). Used as fallback;
# the primary recovery signal is the live `resets_at` from /api/oauth/usage.
COOLDOWN="${CLAUDE_SWITCH_COOLDOWN:-18000}"
STATE_FILE="/tmp/claude_active_account"
TMUX_BIN="${TMUX_BIN:-$(command -v tmux 2>/dev/null || echo '')}"
RESUME_MESSAGE="${CLAUDE_RESUME_MESSAGE:-Rate limit으로 계정이 전환되었습니다. 이전 작업을 이어서 진행해주세요.}"

CURRENT_ID=$(account_current_id)

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
    # --strict: empty stdout means "no viable candidate" (avoid the
    # default "1" fallback, which would launch claude on a broken /
    # unauthorized account and silently fail to resume).
    choice=$(bash "$picker" --strict --no-cache 2>/dev/null)
    if [ -n "$choice" ] && [ "$choice" != "$exclude" ]; then
      echo "$choice"; return
    fi
    # Trust the strict picker: it actively probed every account and found
    # none viable. Skip the manifest fallback to let the caller hit the
    # all-exhausted branch.
    return
  fi
  # Picker missing — fall back to manifest scan (rate-limit timestamps only)
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

  # Ensure target's history.jsonl has an entry for SESSION_ID so `claude -r`
  # can find it. Three sources, in order:
  #
  #  1. Target already has it → no-op.
  #  2. Source has it → copy.
  #  3. Neither has it → synthesize a minimal entry from hook payload
  #     (SESSION_ID + CWD + TRANSCRIPT_PATH). This handles the race where
  #     morning-routine's session hits rate_limit and exits before history.jsonl
  #     is flushed (`projects/` is symlinked between accounts so the transcript
  #     itself is shared — only the lookup row is missing).
  #
  # Without this, `claude -r <missing-id>` falls through to onboarding which
  # is the "ash 같은 화면" failure mode. With it, the resume actually resumes.
  local has_session=0
  if [ -n "$SESSION_ID" ]; then
    local src_hist="$source_config/history.jsonl"
    local dst_hist="$target_config/history.jsonl"
    [ ! -f "$dst_hist" ] && touch "$dst_hist" 2>/dev/null

    # 1+2: target already / source has → copy if needed
    if [ -f "$src_hist" ] \
        && grep -q "\"sessionId\":\"$SESSION_ID\"" "$src_hist" 2>/dev/null \
        && ! grep -q "\"sessionId\":\"$SESSION_ID\"" "$dst_hist" 2>/dev/null; then
      grep "\"sessionId\":\"$SESSION_ID\"" "$src_hist" >> "$dst_hist"
      log "Copied history.jsonl entry for session=$SESSION_ID: $src_hist → $dst_hist"
    fi

    # 3: still missing → synthesize from payload (SESSION_ID + CWD + TRANSCRIPT_PATH).
    # Read first user message from the transcript for the `display` field;
    # tolerate missing transcript or non-user first lines.
    if ! grep -q "\"sessionId\":\"$SESSION_ID\"" "$dst_hist" 2>/dev/null; then
      local synth
      synth=$(SESSION_ID="$SESSION_ID" CWD="$CWD" TRANSCRIPT_PATH="$TRANSCRIPT_PATH" python3 -c '
import json, os, time, sys
sid = os.environ.get("SESSION_ID","")
proj = os.environ.get("CWD","") or os.path.expanduser("~")
tp = os.environ.get("TRANSCRIPT_PATH","")
display = ""
if tp and os.path.isfile(tp):
    try:
        with open(tp) as f:
            for line in f:
                try: e = json.loads(line)
                except: continue
                if e.get("type") == "user":
                    msg = e.get("message", {}) or {}
                    c = msg.get("content")
                    if isinstance(c, str): display = c
                    elif isinstance(c, list):
                        for blk in c:
                            if isinstance(blk, dict) and blk.get("type") == "text":
                                display = blk.get("text",""); break
                    if display: break
    except Exception: pass
display = (display or "")[:200]
print(json.dumps({
    "display": display,
    "pastedContents": {},
    "timestamp": int(time.time()*1000),
    "project": proj,
    "sessionId": sid,
}, ensure_ascii=False))
' 2>/dev/null)
      if [ -n "$synth" ]; then
        echo "$synth" >> "$dst_hist"
        # Also seed source history so future hooks don't re-synthesize unnecessarily.
        [ -f "$src_hist" ] && ! grep -q "\"sessionId\":\"$SESSION_ID\"" "$src_hist" 2>/dev/null && \
          echo "$synth" >> "$src_hist"
        log "Synthesized history.jsonl entry for session=$SESSION_ID (source race) → $dst_hist"
      else
        log "WARN: failed to synthesize history.jsonl entry for session=$SESSION_ID"
      fi
    fi

    grep -q "\"sessionId\":\"$SESSION_ID\"" "$dst_hist" 2>/dev/null && has_session=1
  fi

  # Resume command: prefer `-r SESSION_ID` (now reliable thanks to the
  # synthesis above); only fall back to fresh `claude` as last resort.
  local resume_cmd
  if [ "$has_session" -eq 1 ]; then
    resume_cmd="claude --dangerously-skip-permissions -r $SESSION_ID"
  else
    resume_cmd="claude --dangerously-skip-permissions"
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

  # Sync mcpServers across all account .claude.json files. Catches any
  # newly added MCP entries on the source side and propagates them to the
  # target before we launch claude there. Falls back to a known-good backup
  # if all accounts came up empty (defensive against external resets).
  # Gated on manifest's "sync_mcp_servers" (default true).
  local sync_script="$HOME/.claude/scripts/lib/sync-mcp-servers.sh"
  if [ -x "$sync_script" ] && accounts_sync_mcp_enabled; then
    bash "$sync_script" 2>&1 | sed 's/^/  mcp-sync: /' | tee -a "$LOG_FILE" >/dev/null || \
      log "WARN: mcp sync failed (non-fatal, continuing)"
  fi

  local cmux_bin="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
  local script="/tmp/claude-resume-$$.sh"
  local msg_file="/tmp/claude-resume-msg-$$.txt"
  printf '%s' "$RESUME_MESSAGE" > "$msg_file"
  # The auto-resume message is scheduled from inside this script (which runs in
  # the new split's process tree) — sending it from the rate-limited claude's
  # hook context fails with EPIPE because cmux closes the socket once the
  # parent claude exits.
  cat > "$script" << RESUME_EOF
#!/bin/bash
cd "${CWD:-$HOME}"
CMUX_BIN="$cmux_bin"
MSG_FILE="$msg_file"
if [ -x "\$CMUX_BIN" ] && [ -n "\${CMUX_SURFACE_ID:-}" ] && [ -n "\${CMUX_WORKSPACE_ID:-}" ] && [ -f "\$MSG_FILE" ]; then
  ( sleep 15 && \\
    "\$CMUX_BIN" send --surface "\$CMUX_SURFACE_ID" --workspace "\$CMUX_WORKSPACE_ID" "\$(cat \$MSG_FILE)" 2>/dev/null && \\
    "\$CMUX_BIN" send-key --surface "\$CMUX_SURFACE_ID" --workspace "\$CMUX_WORKSPACE_ID" enter 2>/dev/null && \\
    rm -f "\$MSG_FILE" \\
  ) &
else
  echo "[\$(date '+%Y-%m-%d %H:%M:%S')] WARN: auto-resume message skipped (CMUX_SURFACE_ID=\${CMUX_SURFACE_ID:-empty}, MSG_FILE=\$MSG_FILE)" >> "$HOME/.claude/logs/account-switch.log"
fi
CLAUDE_CONFIG_DIR=$target_config exec $resume_cmd
RESUME_EOF
  chmod +x "$script"

  # Prefer cmux
  if [ -x "$cmux_bin" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    local new_result new_surface
    local -a split_args=("new-split" "right" "--workspace" "$CMUX_WORKSPACE_ID")
    [ -n "${CMUX_SURFACE_ID:-}" ] && split_args+=("--surface" "$CMUX_SURFACE_ID")
    new_result=$("$cmux_bin" "${split_args[@]}" 2>&1 || true)
    new_surface=$(echo "$new_result" | grep -oE "surface:[0-9]+" | head -1)
    # Fall back to a fresh terminal surface if split fails
    if [ -z "$new_surface" ]; then
      new_result=$("$cmux_bin" new-surface --type terminal --workspace "$CMUX_WORKSPACE_ID" 2>&1 || true)
      new_surface=$(echo "$new_result" | grep -oE "surface:[0-9]+" | head -1)
    fi
    if [ -n "$new_surface" ]; then
      sleep 2
      "$cmux_bin" send --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "bash $script" 2>/dev/null || true
      "$cmux_bin" send-key --surface "$new_surface" --workspace "$CMUX_WORKSPACE_ID" "enter" 2>/dev/null || true
      log "cmux split-right created: $new_surface with account${target_id} via $script"
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
# Mark per-session switch timestamp now that all dedup gates have passed
[ -n "$SESSION_ID" ] && echo "$NOW" > "/tmp/claude_last_switch_${SESSION_ID}"

# Query live OAuth usage for an account → "<reset_iso>\t<reset_epoch>" or empty.
# Used by the all-exhausted branch to wake at the real reset moment instead
# of a fixed COOLDOWN guess.
query_resets_at() {
  local config_dir="$1"
  local token=""
  if [ -f "$config_dir/.credentials.json" ]; then
    token=$(python3 -c "
import json
try:
    d=json.load(open('$config_dir/.credentials.json'))
    print(d.get('claudeAiOauth',{}).get('accessToken',''))
except: pass
" 2>/dev/null)
  fi
  if [ -z "$token" ] && command -v security >/dev/null 2>&1; then
    local service="Claude Code-credentials"
    if [ "$config_dir" != "$HOME/.claude" ]; then
      local match
      match=$(security dump-keychain 2>/dev/null | grep -oE '"Claude Code-credentials-[a-f0-9]+"' | tr -d '"' | head -1)
      [ -n "$match" ] && service="$match"
    fi
    token=$(security find-generic-password -s "$service" -a "$USER" -w 2>/dev/null | python3 -c "
import json, sys
try: print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])
except: pass
" 2>/dev/null)
  fi
  [ -z "$token" ] && return 1
  local resp
  resp=$(curl -s --max-time 5 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
  [ -z "$resp" ] && return 1
  echo "$resp" | python3 -c "
import json, sys, datetime
try:
    d=json.load(sys.stdin)
    if 'error' in d: sys.exit(1)
    r5=d['five_hour']['resets_at']
    ts=datetime.datetime.fromisoformat(r5.replace('Z','+00:00')).timestamp()
    print(f'{r5}\t{int(ts)}')
except Exception:
    sys.exit(1)
" 2>/dev/null
}

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

  # Pick the account that recovers FIRST. Prefer the live `resets_at` from
  # /api/oauth/usage; fall back to (rate-limit marker + COOLDOWN) for any
  # account whose API can't be queried (token broken, network down, etc).
  RECOVER_ID=""
  RECOVER_EP=0
  RECOVER_SOURCE=""
  while read -r id; do
    [ -z "$id" ] && continue
    cfg=$(account_dir "$id")
    [ -z "$cfg" ] && continue
    api_out=$(query_resets_at "$cfg" 2>/dev/null || true)
    if [ -n "$api_out" ]; then
      reset_iso=$(echo "$api_out" | cut -f1)
      reset_ep=$(echo "$api_out" | cut -f2)
      log "API: acct${id} resets_at=${reset_iso}"
    else
      # Fallback: use the rate-limit marker + COOLDOWN as estimated reset
      rl_file="/tmp/claude_ratelimit_account${id}"
      if [ -f "$rl_file" ]; then
        ts=$(cat "$rl_file" 2>/dev/null || echo "$NOW")
        reset_ep=$(( ts + COOLDOWN ))
        log "API unavailable for acct${id}; marker fallback reset_ep=${reset_ep}"
      else
        # No marker, no API → assume just-now + COOLDOWN
        reset_ep=$(( NOW + COOLDOWN ))
        log "No data for acct${id}; assumed reset_ep=${reset_ep}"
      fi
    fi
    if [ -z "$RECOVER_ID" ] || [ "$reset_ep" -lt "$RECOVER_EP" ]; then
      RECOVER_ID="$id"; RECOVER_EP="$reset_ep"
      RECOVER_SOURCE=$([ -n "$api_out" ] && echo "api" || echo "marker")
    fi
  done < <(account_ids)

  RECOVER_ID="${RECOVER_ID:-1}"
  # +30s buffer past the reset moment so the API can serve fresh tokens
  WAIT_SECS=$(( RECOVER_EP - NOW + 30 ))
  [ "$WAIT_SECS" -lt 60 ] && WAIT_SECS=60
  WAIT_MINS=$(( WAIT_SECS / 60 ))
  RECOVER_HUMAN=$(date -d "@${RECOVER_EP}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                 || date -r "${RECOVER_EP}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                 || echo "epoch=$RECOVER_EP")
  log "Recover plan: acct${RECOVER_ID} at ${RECOVER_HUMAN} (in ${WAIT_MINS}min, source=${RECOVER_SOURCE})"

  echo "$RECOVER_ID" > "$STATE_FILE"
  notify "All accounts exhausted. Auto-resume acct${RECOVER_ID} at ${RECOVER_HUMAN} (~${WAIT_MINS}min)." "Claude Code"

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
