#!/bin/bash
# Claude Account Switcher — Installer (macOS + Linux)
# Usage: bash install.sh
#
# Customize via env vars (before running):
#   ACCOUNT2_DIR=~/.claude-work  bash install.sh
#   ALIAS_1=cpersonal ALIAS_2=cwork  bash install.sh
#
# Env vars:
#   ACCOUNT2_DIR  — path for second config dir (default: ~/.claude-account2)
#   ALIAS_1       — alias name for account 1 (default: cc)
#   ALIAS_2       — alias name for account 2 (default: cc2)
#   USAGE_ALIAS   — alias name for usage viewer (default: claude-usage)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SCRIPTS="$HOME/.claude/scripts"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# Customizable
ACCOUNT2_DIR="${ACCOUNT2_DIR:-$HOME/.claude-account2}"
ALIAS_1="${ALIAS_1:-cc}"
ALIAS_2="${ALIAS_2:-cc2}"
USAGE_ALIAS="${USAGE_ALIAS:-claude-usage}"
ALIAS_1R="${ALIAS_1}r"
ALIAS_2R="${ALIAS_2}r"

# Detect OS
OS="unknown"
case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
esac

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
echo "  OS:            $OS"
echo "  Account 2 dir: $ACCOUNT2_DIR"
echo "  Aliases:       $ALIAS_1 / $ALIAS_1R / $ALIAS_2 / $ALIAS_2R / $USAGE_ALIAS"
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

echo "  claude:  $(claude --version 2>/dev/null | head -1)"
echo "  jq:      $(jq --version 2>/dev/null)"
echo "  python3: $(python3 --version 2>/dev/null)"
command -v tmux >/dev/null 2>&1 && echo "  tmux:    $(tmux -V 2>/dev/null)"

# 2. Copy scripts and patch ACCOUNT2_DIR if customized
echo ""
echo "[2/5] Installing scripts to $CLAUDE_SCRIPTS..."
mkdir -p "$CLAUDE_SCRIPTS"
cp "$SCRIPT_DIR/on-ratelimit.sh" "$CLAUDE_SCRIPTS/on-ratelimit.sh"
cp "$SCRIPT_DIR/on-stop-ratelimit.sh" "$CLAUDE_SCRIPTS/on-stop-ratelimit.sh"
cp "$SCRIPT_DIR/claude-usage.sh" "$CLAUDE_SCRIPTS/claude-usage.sh"

# If custom ACCOUNT2_DIR, patch scripts so hook doesn't rely on shell env
if [ "$ACCOUNT2_DIR" != "$HOME/.claude-account2" ]; then
  # Escape for sed
  ESC_DIR=$(printf '%s\n' "$ACCOUNT2_DIR" | sed 's/[\/&]/\\&/g')
  sed -i.bak "s|\$HOME/.claude-account2|$ESC_DIR|g" "$CLAUDE_SCRIPTS/on-ratelimit.sh" "$CLAUDE_SCRIPTS/claude-usage.sh"
  rm -f "$CLAUDE_SCRIPTS"/*.bak
  echo "  Patched scripts with ACCOUNT2_DIR=$ACCOUNT2_DIR"
fi

chmod +x "$CLAUDE_SCRIPTS/on-ratelimit.sh" "$CLAUDE_SCRIPTS/on-stop-ratelimit.sh" "$CLAUDE_SCRIPTS/claude-usage.sh"
echo "  Done"

# 3. Register hooks in settings.json
echo ""
echo "[3/5] Registering hooks..."
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"

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

# 4. Setup shell aliases
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

MARKER="# Claude Account Switcher"
if grep -q "$MARKER" "$SHELL_RC" 2>/dev/null; then
  echo "  Aliases marker already present in $SHELL_RC — skipping"
  echo "  (Remove existing block manually to regenerate)"
else
  # Use double-quoted heredoc so env var customizations expand
  cat >> "$SHELL_RC" << ALIASES

$MARKER — CLAUDE_CONFIG_DIR creates separate credential storage
alias $ALIAS_1="claude"
alias $ALIAS_2="CLAUDE_CONFIG_DIR=$ACCOUNT2_DIR claude"
alias $ALIAS_1R="claude --dangerously-skip-permissions"
alias $ALIAS_2R="CLAUDE_CONFIG_DIR=$ACCOUNT2_DIR claude --dangerously-skip-permissions"
alias $USAGE_ALIAS="CLAUDE_CONFIG_DIR_2=$ACCOUNT2_DIR bash ~/.claude/scripts/claude-usage.sh"
ALIASES
  echo "  Added aliases to $SHELL_RC:"
  echo "    $ALIAS_1, $ALIAS_2, $ALIAS_1R, $ALIAS_2R, $USAGE_ALIAS"
fi

# 5. Create second config dir + symlink shared resources
echo ""
echo "[5/5] Setting up second config dir: $ACCOUNT2_DIR"

if [ ! -d "$HOME/.claude" ]; then
  echo "  WARNING: ~/.claude not found. Run 'claude' at least once before logging in to account 2."
fi

mkdir -p "$ACCOUNT2_DIR"

# Symlink shared resources so both accounts see the same session history,
# hook config, plugins, and global instructions. Required for seamless
# cross-account session resume (-r <session_id>).
# Only creates symlink if target doesn't exist yet (preserves existing setup).
link_shared() {
  local name="$1"
  local src="$HOME/.claude/$name"
  local dst="$ACCOUNT2_DIR/$name"

  # Source must exist
  [ ! -e "$src" ] && { echo "  skip $name (source not found)"; return; }

  # If destination exists as real dir/file (not symlink), leave it alone
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "  skip $name (exists in $ACCOUNT2_DIR, not overwriting)"
    return
  fi

  # If already a symlink to the right target, skip
  if [ -L "$dst" ]; then
    local current=$(readlink "$dst")
    [ "$current" = "$src" ] && { echo "  skip $name (already linked)"; return; }
    rm -f "$dst"
  fi

  ln -s "$src" "$dst"
  echo "  linked $name"
}

echo "  Creating symlinks for shared state..."
link_shared "sessions"      # REQUIRED: -r <session_id> lookup
link_shared "projects"      # REQUIRED: transcripts
link_shared "plugins"       # shared plugins (OMC, etc.)
link_shared "settings.json" # shared hooks and config
link_shared "scripts"       # hook scripts
link_shared "CLAUDE.md"     # global instructions (optional)

echo ""
echo "=== Installation complete ==="
echo ""
echo "NEXT: Login each account (one time per config dir)"
echo ""
if [ "$OS" = "linux" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -z "${DISPLAY:-}" ]; then
  echo "  Headless server detected."
  echo ""
  echo "  Option A — Copy credentials from local machine:"
  echo "    # on local machine (after claude login):"
  echo "    scp ~/.claude/.credentials.json server:~/.claude/.credentials.json"
  echo "    scp ~/.claude-account2/.credentials.json server:$ACCOUNT2_DIR/.credentials.json"
  echo ""
  echo "  Option B — SSH port forwarding for browser OAuth:"
  echo "    ssh -L 54545:localhost:54545 server"
  echo "    # then on server: claude login"
  echo ""
else
  echo "  Account 1:  claude login"
  echo "  Account 2:  CLAUDE_CONFIG_DIR=$ACCOUNT2_DIR claude login"
  echo ""
fi

echo "Usage:"
echo "  $ALIAS_1 / $ALIAS_1R   — account 1 (with/without permission prompts)"
echo "  $ALIAS_2 / $ALIAS_2R   — account 2"
echo "  $USAGE_ALIAS           — show both accounts' usage"
echo ""
echo "Rate limit handling is automatic."
echo ""
echo "Restart your shell: source $SHELL_RC"
