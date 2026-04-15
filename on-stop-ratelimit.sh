#!/bin/bash
# Stop hook — detect rate limit from assistant response
# Stop fires on every turn end. We check the transcript for rate limit markers.
# If found, delegate to on-ratelimit.sh logic.

INPUT=$(cat)

# Stop hook receives: session_id, transcript_path, cwd, stop_reason, etc.
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

# No transcript path → skip
[ -z "$TRANSCRIPT" ] && exit 0
[ ! -f "$TRANSCRIPT" ] && exit 0

# Check last few lines of transcript for rate_limit error
LAST_LINES=$(tail -5 "$TRANSCRIPT" 2>/dev/null)
if echo "$LAST_LINES" | grep -q '"error".*"rate_limit"' 2>/dev/null; then
  # Rate limit detected — pass to main handler
  echo "{\"error_type\":\"rate_limit\",\"cwd\":\"${CWD}\",\"session_id\":\"${SESSION_ID}\"}" | bash ~/.claude/scripts/on-ratelimit.sh
fi

exit 0
