#!/bin/bash
# Stop hook — detect rate limit from assistant response
#
# Why this exists: `StopFailure` hook with matcher="rate_limit" does NOT
# reliably filter to rate-limit events in Claude Code 2.1.x (observed: fires
# on every stop with empty error_type). So we use the plain `Stop` hook and
# scan the transcript.
#
# Detection: find the LAST message with type=="assistant" in the transcript
# (skipping attachment/system/task_reminder/stop_hook_summary). If that
# assistant entry has "error":"rate_limit", trigger the switch.
#
# Dedup: we record the UUID of rate-limit entries we've already acted on in
# /tmp/claude_ratelimit_seen_uuids so we don't re-trigger on every Stop.

unset NODE_OPTIONS 2>/dev/null || true

INPUT=$(cat)

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

[ -z "$TRANSCRIPT" ] && exit 0
[ ! -f "$TRANSCRIPT" ] && exit 0

LOG_FILE="$HOME/.claude/logs/account-switch.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

SEEN_FILE="/tmp/claude_ratelimit_seen_uuids"
touch "$SEEN_FILE" 2>/dev/null || true

# Scan the last ~300 lines; find the most recent assistant entry and read
# its error/uuid/timestamp. Emits: "<uuid>\t<error>\t<timestamp>" or nothing.
LAST_ASSISTANT=$(tail -n 300 "$TRANSCRIPT" 2>/dev/null | python3 -c '
import json, sys
last = None
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("type") != "assistant":
        continue
    last = d
if last is not None:
    uid = last.get("uuid", "")
    err = last.get("error", "")
    ts  = last.get("timestamp", "")
    print(f"{uid}\t{err}\t{ts}")
' 2>/dev/null)

[ -z "$LAST_ASSISTANT" ] && exit 0

IFS=$'\t' read -r RL_UUID RL_ERR RL_TS <<< "$LAST_ASSISTANT"

# Only act on rate_limit
[ "$RL_ERR" != "rate_limit" ] && exit 0

# Dedup: skip if we've already acted on this UUID
if [ -n "$RL_UUID" ] && grep -q "^${RL_UUID}$" "$SEEN_FILE" 2>/dev/null; then
    exit 0
fi

log "Stop hook: rate_limit detected | session=$SESSION_ID uuid=$RL_UUID ts=$RL_TS"
[ -n "$RL_UUID" ] && echo "$RL_UUID" >> "$SEEN_FILE"

# Delegate to on-ratelimit.sh with full context
jq -n --arg et "rate_limit" --arg cwd "$CWD" --arg sid "$SESSION_ID" \
      --arg tp "$TRANSCRIPT" --arg uuid "$RL_UUID" \
    '{error_type:$et, cwd:$cwd, session_id:$sid, transcript_path:$tp, rate_limit_uuid:$uuid, source:"stop_hook"}' \
    | bash ~/.claude/scripts/on-ratelimit.sh

exit 0
