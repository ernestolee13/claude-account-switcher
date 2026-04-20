#!/bin/bash
# Claude Account Switcher — Installer (macOS + Linux)
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SCRIPTS="$HOME/.claude/scripts"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CONFIG_DIR_2="$HOME/.claude-account2"

# Detect OS
OS="unknown"
case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
esac

# Distro-appropriate install hint
install_hint() {
  local pkg="$1"
  if [ "$OS" = "macos" ]; then
    echo "brew install $pkg"
  elif command -v apt >/dev/null 2>&1; then
    echo "sudo apt install -y $pkg"
  elif command -v dnf >/dev/null 2>&1; then
    echo "sudo dnf install -y $pkg"
  elif command -v pacman >/dev/null 2>&1; then
    echo "sudo pacman -S $pkg"
  else
    echo "install $pkg via your package manager"
  fi
}

echo "=== Claude Account Switcher — Install ==="
echo "Detected OS: $OS"
echo ""

# 1. Check prerequisites
echo "[1/5] Checking prerequisites..."
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude not found. Install Claude Code first: https://claude.ai/code"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found. Install with: $(install_hint jq)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found. Install with: $(install_hint python3)"; exit 1; }

if ! command -v tmux >/dev/null 2>&1; then
  echo "  WARNING: tmux not found. Auto-resume on rate limit will fall back to logging only."
  echo "           Install with: $(install_hint tmux)"
fi

echo "  claude: $(claude --version 2>/dev/null | head -1)"
echo "  jq: $(jq --version 2>/dev/null)"
echo "  python3: $(python3 --version 2>/dev/null)"
command -v tmux >/dev/null 2>&1 && echo "  tmux: $(tmux -V 2>/dev/null)"

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

if ! jq -e '.hooks.StopFailure' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  jq '.hooks.StopFailure = [{"matcher": "rate_limit", "hooks": [{"type": "command", "command": "bash ~/.claude/scripts/on-ratelimit.sh"}]}]' "$CLAUDE_SETTINGS" > "$TMPFILE"
  mv "$TMPFILE" "$CLAUDE_SETTINGS"
  echo "  StopFailure hook registered"
else
  echo "  StopFailure hook already exists — skipping (verify manually if needed)"
fi

TMPFILE=$(mktemp)
if ! jq -e '.hooks.Stop' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  jq '.hooks.Stop = [{"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/scripts/on-stop-ratelimit.sh"}]}]' "$CLAUDE_SETTINGS" > "$TMPFILE"
  mv "$TMPFILE" "$CLAUDE_SETTINGS"
  echo "  Stop hook registered"
else
  echo "  Stop hook already exists — skipping"
fi

# 4. Setup shell aliases (detect shell from $SHELL or file existence)
echo ""
echo "[4/5] Setting up shell aliases..."
SHELL_RC=""
case "${SHELL:-}" in
  */zsh)  SHELL_RC="$HOME/.zshrc" ;;
  */bash) SHELL_RC="$HOME/.bashrc" ;;
  *)
    [ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"
    [ -z "$SHELL_RC" ] && [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc"
    [ -z "$SHELL_RC" ] && SHELL_RC="$HOME/.zshrc"
    ;;
esac

if grep -q "Claude Code multi-account" "$SHELL_RC" 2>/dev/null; then
  echo "  Aliases already exist in $SHELL_RC — skipping"
else
  cat >> "$SHELL_RC" << 'ALIASES'

# Claude Code multi-account (CLAUDE_CONFIG_DIR creates separate credential storage)
alias cc="claude"
alias cc2="CLAUDE_CONFIG_DIR=~/.claude-account2 claude"
alias ccr="claude --dangerously-skip-permissions"
alias cc2r="CLAUDE_CONFIG_DIR=~/.claude-account2 claude --dangerously-skip-permissions"
alias claude-usage="bash ~/.claude/scripts/claude-usage.sh"
ALIASES
  echo "  Added cc, cc2, ccr, cc2r, claude-usage aliases to $SHELL_RC"
fi

# 5. Create second config dir
echo ""
echo "[5/5] Account setup..."
mkdir -p "$CONFIG_DIR_2"

echo ""
echo "=== Installation complete ==="
echo ""
echo "NEXT: Login each account (one time per config dir)"
echo ""
if [ "$OS" = "linux" ] && [ -z "${DISPLAY:-}" ] && [ -z "${SSH_CONNECTION:-}" ]; then
  echo "  Account 1 (default):"
  echo "    claude login"
  echo ""
  echo "  Account 2 (separate config):"
  echo "    CLAUDE_CONFIG_DIR=~/.claude-account2 claude login"
  echo ""
elif [ "$OS" = "linux" ]; then
  echo "  Headless server?"
  echo "  Option A — Login on local machine, then copy credentials to server:"
  echo "    # on local machine (after claude login):"
  echo "    scp ~/.claude/.credentials.json server:~/.claude/.credentials.json"
  echo "    scp ~/.claude-account2/.credentials.json server:~/.claude-account2/.credentials.json"
  echo ""
  echo "  Option B — Use SSH port forwarding for OAuth browser flow:"
  echo "    ssh -L 54545:localhost:54545 server   # adjust port if needed"
  echo "    # then on server: claude login"
  echo ""
else
  echo "  Account 1:  claude login"
  echo "  Account 2:  CLAUDE_CONFIG_DIR=~/.claude-account2 claude login"
  echo ""
fi

echo "Usage:"
echo "  cc   / ccr    — account 1 (with/without permission prompts)"
echo "  cc2  / cc2r   — account 2"
echo "  claude-usage  — show both accounts' usage"
echo ""
echo "Rate limit handling is automatic — no action needed."
echo ""
echo "Restart your shell to activate: source $SHELL_RC"
