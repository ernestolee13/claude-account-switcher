#!/bin/bash
# Claude Account Switcher — Installer
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SCRIPTS="$HOME/.claude/scripts"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CONFIG_DIR_2="$HOME/.claude-account2"

echo "=== Claude Account Switcher — Install ==="
echo ""

# 1. Check prerequisites
echo "[1/5] Checking prerequisites..."
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude not found. Install Claude Code first."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found. Install with: brew install jq"; exit 1; }
echo "  claude: $(claude --version 2>/dev/null | head -1)"
echo "  jq: $(jq --version 2>/dev/null)"

# 2. Copy scripts
echo ""
echo "[2/5] Installing scripts..."
mkdir -p "$CLAUDE_SCRIPTS"
cp "$SCRIPT_DIR/on-ratelimit.sh" "$CLAUDE_SCRIPTS/on-ratelimit.sh"
cp "$SCRIPT_DIR/on-stop-ratelimit.sh" "$CLAUDE_SCRIPTS/on-stop-ratelimit.sh"
cp "$SCRIPT_DIR/claude-usage.sh" "$CLAUDE_SCRIPTS/claude-usage.sh"
chmod +x "$CLAUDE_SCRIPTS/on-ratelimit.sh" "$CLAUDE_SCRIPTS/on-stop-ratelimit.sh" "$CLAUDE_SCRIPTS/claude-usage.sh"
echo "  Installed to $CLAUDE_SCRIPTS/"

# 3. Register hooks in settings.json
echo ""
echo "[3/5] Registering hooks..."
if [ ! -f "$CLAUDE_SETTINGS" ]; then
  echo '{}' > "$CLAUDE_SETTINGS"
fi

TMPFILE=$(mktemp)
CHANGED=false

if ! jq -e '.hooks.StopFailure' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  jq '.hooks.StopFailure = [{"matcher": "rate_limit", "hooks": [{"type": "command", "command": "bash ~/.claude/scripts/on-ratelimit.sh"}]}]' "$CLAUDE_SETTINGS" > "$TMPFILE"
  mv "$TMPFILE" "$CLAUDE_SETTINGS"
  CHANGED=true
  echo "  StopFailure hook registered"
else
  echo "  StopFailure hook already exists — skipping"
fi

TMPFILE=$(mktemp)
if ! jq -e '.hooks.Stop' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  jq '.hooks.Stop = [{"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/scripts/on-stop-ratelimit.sh"}]}]' "$CLAUDE_SETTINGS" > "$TMPFILE"
  mv "$TMPFILE" "$CLAUDE_SETTINGS"
  CHANGED=true
  echo "  Stop hook registered"
else
  echo "  Stop hook already exists — skipping"
fi

# 4. Setup aliases
echo ""
echo "[4/5] Setting up shell aliases..."
SHELL_RC="$HOME/.zshrc"
[ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.bashrc"

if grep -q "Claude Code multi-account" "$SHELL_RC" 2>/dev/null; then
  echo "  Aliases already exist in $SHELL_RC — skipping"
else
  cat >> "$SHELL_RC" << 'ALIASES'

# Claude Code multi-account (CLAUDE_CONFIG_DIR creates separate Keychain entries automatically)
alias cc="claude"
alias cc2="CLAUDE_CONFIG_DIR=~/.claude-account2 claude"
alias ccr="claude --dangerously-skip-permissions"
alias cc2r="CLAUDE_CONFIG_DIR=~/.claude-account2 claude --dangerously-skip-permissions"
alias claude-usage="bash ~/.claude/scripts/claude-usage.sh"
ALIASES
  echo "  Added cc, cc2, ccr, cc2r, claude-usage aliases to $SHELL_RC"
fi

# 5. Create second config dir + check login status
echo ""
echo "[5/5] Account setup..."
mkdir -p "$CONFIG_DIR_2"

echo ""
echo "  Login each account (one time only):"
echo ""
echo "    Account 1:  claude login"
echo "    Account 2:  CLAUDE_CONFIG_DIR=~/.claude-account2 claude login"
echo ""

echo "=== Installation complete ==="
echo ""
echo "Usage:"
echo "  cc   / ccr    — account 1 (with/without permission prompts)"
echo "  cc2  / cc2r   — account 2"
echo "  claude-usage  — show both accounts' usage"
echo ""
echo "Rate limit handling is automatic — no action needed."
echo ""
echo "Restart your shell to activate: source $SHELL_RC"
