#!/bin/bash
# Claude Account Switcher — Installer
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SCRIPTS="$HOME/.claude/scripts"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo "=== Claude Account Switcher — Install ==="
echo ""

# 1. Check prerequisites
echo "[1/5] Checking prerequisites..."
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude not found. Install Claude Code first."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found. Install with: brew install jq"; exit 1; }

TMUX_BIN=""
if command -v /opt/homebrew/bin/tmux >/dev/null 2>&1; then
  TMUX_BIN="/opt/homebrew/bin/tmux"
elif command -v tmux >/dev/null 2>&1; then
  TMUX_BIN="$(which tmux)"
else
  echo "WARNING: tmux not found. Auto-resume sessions will be disabled."
  echo "         Install with: brew install tmux"
fi
echo "  claude: $(claude --version 2>/dev/null | head -1)"
echo "  jq: $(jq --version 2>/dev/null)"
[ -n "$TMUX_BIN" ] && echo "  tmux: $($TMUX_BIN -V 2>/dev/null)"

# 2. Copy hook script
echo ""
echo "[2/5] Installing hook script..."
mkdir -p "$CLAUDE_SCRIPTS"
cp "$SCRIPT_DIR/on-ratelimit.sh" "$CLAUDE_SCRIPTS/on-ratelimit.sh"
chmod +x "$CLAUDE_SCRIPTS/on-ratelimit.sh"
echo "  Copied to $CLAUDE_SCRIPTS/on-ratelimit.sh"

# 3. Register hook in settings.json
echo ""
echo "[3/5] Registering StopFailure hook..."
if [ ! -f "$CLAUDE_SETTINGS" ]; then
  echo '{}' > "$CLAUDE_SETTINGS"
fi

# Check if hook already registered
if jq -e '.hooks.StopFailure' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  echo "  StopFailure hook already exists — skipping (check manually if needed)"
else
  # Add hook using jq
  TMPFILE=$(mktemp)
  jq '.hooks.StopFailure = [{"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/scripts/on-ratelimit.sh"}]}]' "$CLAUDE_SETTINGS" > "$TMPFILE"
  mv "$TMPFILE" "$CLAUDE_SETTINGS"
  echo "  Hook registered in $CLAUDE_SETTINGS"
fi

# 4. Setup aliases
echo ""
echo "[4/5] Setting up shell aliases..."
SHELL_RC="$HOME/.zshrc"
[ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.bashrc"

if grep -q "cc2.*CLAUDE_CONFIG_DIR" "$SHELL_RC" 2>/dev/null; then
  echo "  Aliases already exist in $SHELL_RC — skipping"
else
  cat >> "$SHELL_RC" << 'ALIASES'

# Claude Code multi-account
alias cc="claude"
alias cc2="CLAUDE_CONFIG_DIR=~/.claude-account2 claude"
ALIASES
  echo "  Added cc, cc2 aliases to $SHELL_RC"
fi

# 5. Account setup guide
echo ""
echo "[5/5] Account setup"
echo ""

ACCT1_STATUS=$(claude auth status 2>&1 | jq -r '.email // "not logged in"' 2>/dev/null || echo "not logged in")
ACCT2_STATUS=$(CLAUDE_CONFIG_DIR=~/.claude-account2 claude auth status 2>&1 | jq -r '.email // "not logged in"' 2>/dev/null || echo "not logged in")

echo "  Account 1 (~/.claude):           $ACCT1_STATUS"
echo "  Account 2 (~/.claude-account2):  $ACCT2_STATUS"
echo ""

if [ "$ACCT2_STATUS" = "not logged in" ]; then
  echo "  ⚠ Account 2 not logged in. Run:"
  echo ""
  echo "    CLAUDE_CONFIG_DIR=~/.claude-account2 claude login"
  echo ""
  echo "  Then log in with your second account in the browser."
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Usage:"
echo "  cc         — start Claude with account 1"
echo "  cc2        — start Claude with account 2"
echo ""
echo "On rate limit:"
echo "  → Automatically switches to the other account"
echo "  → If both exhausted, waits and auto-resumes (~30min)"
echo "  → macOS notification on every switch"
echo "  → tmux session opened for easy continuation"
echo ""
echo "Optional — schedule a command to run on recovery:"
echo "  echo 'bash my-script.sh' > /tmp/claude_resume_command"
echo ""
echo "Restart your shell to activate aliases: source $SHELL_RC"
