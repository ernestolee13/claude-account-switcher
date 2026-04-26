#!/bin/bash
# Claude Account Switcher — Installer (macOS + Linux)
# Usage: bash install.sh
#
# Default: 2 accounts (~/.claude and ~/.claude-account2)
#
# Customize via env vars (before running):
#   NUM_ACCOUNTS=3 bash install.sh                    # N accounts
#   ACCOUNT2_DIR=~/.claude-work bash install.sh       # custom path
#   ACCOUNT2_DIR=~/.claude-work ACCOUNT3_DIR=~/.claude-personal NUM_ACCOUNTS=3 bash install.sh
#
# Env vars:
#   NUM_ACCOUNTS         — number of accounts (default: 2)
#   ACCOUNT<N>_DIR       — config dir for account N (default: ~/.claude for 1, ~/.claude-account<N> for 2+)
#   ACCOUNT<N>_LABEL     — label for account N (default: "" / "default" / "secondary" / "tertiary" / ...)
#   ALIAS_AUTO           — auto-pick command name (default: cc)
#   USAGE_ALIAS          — usage viewer alias (default: claude-usage)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SCRIPTS="$HOME/.claude/scripts"
CLAUDE_LIB="$CLAUDE_SCRIPTS/lib"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
ACCOUNT_MANIFEST="$HOME/.claude-accounts.json"

NUM_ACCOUNTS="${NUM_ACCOUNTS:-2}"
ALIAS_AUTO="${ALIAS_AUTO:-cc}"
ALIAS_AUTO_R="${ALIAS_AUTO}r"
USAGE_ALIAS="${USAGE_ALIAS:-claude-usage}"

# Resolve account N's config dir (env override or default pattern)
account_dir_for() {
  local n="$1"
  local var="ACCOUNT${n}_DIR"
  local val="${!var:-}"
  if [ -z "$val" ]; then
    if [ "$n" = "1" ]; then
      val="$HOME/.claude"
    else
      val="$HOME/.claude-account${n}"
    fi
  fi
  # Expand tilde
  echo "${val/#\~/$HOME}"
}

account_label_for() {
  local n="$1"
  local var="ACCOUNT${n}_LABEL"
  echo "${!var:-}"
}

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
echo "  Accounts:      $NUM_ACCOUNTS"
for i in $(seq 1 "$NUM_ACCOUNTS"); do
  d=$(account_dir_for "$i")
  l=$(account_label_for "$i")
  printf "    cc%-2s         %s%s\n" "$i" "$d" "${l:+ ($l)}"
done
echo ""

# 1. Prerequisites
echo "[1/6] Checking prerequisites..."
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

if [ ! -d "$HOME/.claude" ]; then
  echo ""
  echo "  NOTICE: ~/.claude not found. Run 'claude' once and login before completing setup."
fi

# Detect duplicate emails across configured accounts (bash 3.2 compatible — no associative arrays)
SEEN_EMAILS_LIST=""
for i in $(seq 1 "$NUM_ACCOUNTS"); do
  d=$(account_dir_for "$i")
  if [ -f "$d/.claude.json" ]; then
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$d/.claude.json" 2>/dev/null)
    if [ -n "$email" ]; then
      prev_id=$(echo "$SEEN_EMAILS_LIST" | awk -v e="$email" -F'\t' '$1==e{print $2; exit}')
      if [ -n "$prev_id" ]; then
        echo ""
        echo "  WARNING: account$i and account${prev_id} both have email=$email"
        echo "           Failover requires DIFFERENT accounts. Re-login one with another account:"
        echo "             CLAUDE_CONFIG_DIR=$d claude logout && CLAUDE_CONFIG_DIR=$d claude login"
      else
        SEEN_EMAILS_LIST="${SEEN_EMAILS_LIST}${email}	${i}
"
      fi
    fi
  fi
done

# 2. Generate manifest
echo ""
echo "[2/6] Writing account manifest: $ACCOUNT_MANIFEST"
{
  echo "{"
  echo '  "accounts": ['
  for i in $(seq 1 "$NUM_ACCOUNTS"); do
    d=$(account_dir_for "$i")
    l=$(account_label_for "$i")
    [ -z "$l" ] && {
      case "$i" in
        1) l="default" ;;
        2) l="secondary" ;;
        3) l="tertiary" ;;
        *) l="account${i}" ;;
      esac
    }
    sep=","
    [ "$i" = "$NUM_ACCOUNTS" ] && sep=""
    printf '    {"id": %d, "config_dir": "%s", "label": "%s"}%s\n' "$i" "$d" "$l" "$sep"
  done
  echo "  ]"
  echo "}"
} > "$ACCOUNT_MANIFEST"
echo "  Wrote $NUM_ACCOUNTS accounts"

# 3. Copy scripts
echo ""
echo "[3/6] Installing scripts to $CLAUDE_SCRIPTS..."
mkdir -p "$CLAUDE_SCRIPTS" "$CLAUDE_LIB"
cp "$SCRIPT_DIR/on-ratelimit.sh" "$CLAUDE_SCRIPTS/on-ratelimit.sh"
cp "$SCRIPT_DIR/on-stop-ratelimit.sh" "$CLAUDE_SCRIPTS/on-stop-ratelimit.sh"
cp "$SCRIPT_DIR/claude-usage.sh" "$CLAUDE_SCRIPTS/claude-usage.sh"
cp "$SCRIPT_DIR/pick-account.sh" "$CLAUDE_SCRIPTS/pick-account.sh"
cp "$SCRIPT_DIR/lib/accounts.sh" "$CLAUDE_LIB/accounts.sh"
chmod +x "$CLAUDE_SCRIPTS"/*.sh "$CLAUDE_LIB/accounts.sh"
echo "  Done"

# 4. Register hooks
echo ""
echo "[4/6] Registering hooks..."
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"

TMPFILE=$(mktemp)
if ! jq -e '.hooks.StopFailure' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  jq '.hooks.StopFailure = [{"matcher": "rate_limit", "hooks": [{"type": "command", "command": "bash ~/.claude/scripts/on-ratelimit.sh"}]}]' "$CLAUDE_SETTINGS" > "$TMPFILE"
  mv "$TMPFILE" "$CLAUDE_SETTINGS"
  echo "  StopFailure hook registered"
else
  echo "  StopFailure hook already exists — skipping"
fi

TMPFILE=$(mktemp)
if ! jq -e '.hooks.Stop' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  jq '.hooks.Stop = [{"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/scripts/on-stop-ratelimit.sh"}]}]' "$CLAUDE_SETTINGS" > "$TMPFILE"
  mv "$TMPFILE" "$CLAUDE_SETTINGS"
  echo "  Stop hook registered"
else
  echo "  Stop hook already exists — skipping"
fi

# 5. Setup shell functions/aliases
echo ""
echo "[5/6] Setting up shell functions..."
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
  # Build per-account env-prefix lookup table from manifest
  CASE_BLOCK=""
  for i in $(seq 1 "$NUM_ACCOUNTS"); do
    d=$(account_dir_for "$i")
    if [ "$i" = "1" ] && [ "$d" = "$HOME/.claude" ]; then
      CASE_BLOCK="${CASE_BLOCK}    $i) env_prefix=\"\" ;;\n"
    else
      CASE_BLOCK="${CASE_BLOCK}    $i) env_prefix=\"CLAUDE_CONFIG_DIR=$d \" ;;\n"
    fi
  done

  # Per-account explicit aliases (cc1, cc2, ..., ccN and their r-variants)
  EXPLICIT_FUNCS=""
  for i in $(seq 1 "$NUM_ACCOUNTS"); do
    EXPLICIT_FUNCS="${EXPLICIT_FUNCS}cc${i}()  { _claude_tmux $i \"\$@\"; }\n"
    EXPLICIT_FUNCS="${EXPLICIT_FUNCS}cc${i}r() { _claude_tmux $i --dangerously-skip-permissions \"\$@\"; }\n"
  done

  cat >> "$SHELL_RC" << ALIASES

$MARKER — tmux session per project, windows per account (N-account aware)
_claude_tmux() {
  local acct="\$1"; shift
  if [ "\$acct" = "auto" ]; then
    acct=\$(bash ~/.claude/scripts/pick-account.sh 2>/dev/null || echo "1")
  fi
  local session
  if [ -n "\${TMUX:-}" ]; then
    session=\$(tmux display-message -p '#S' 2>/dev/null)
  fi
  : "\${session:=\${CLAUDE_TMUX_SESSION:-\$(basename "\$PWD" | tr -c '[:alnum:]_-' '_')}}"
  local wname="acct\${acct}"
  local env_prefix=""
  case "\$acct" in
$(printf '%b' "$CASE_BLOCK")    *) env_prefix="" ;;
  esac
  local cmd="\${env_prefix}claude \$*"
  if tmux has-session -t "\$session" 2>/dev/null; then
    tmux new-window -t "\$session" -n "\$wname" -c "\$PWD" "\$cmd"
  else
    tmux new-session -d -s "\$session" -n "\$wname" -c "\$PWD" "\$cmd"
  fi
  if [ -n "\${TMUX:-}" ]; then
    tmux select-window -t "\${session}:\${wname}" 2>/dev/null || tmux switch-client -t "\$session"
  else
    tmux attach -t "\$session"
  fi
}
# Auto-pick (default)
$ALIAS_AUTO()    { _claude_tmux auto "\$@"; }
$ALIAS_AUTO_R()  { _claude_tmux auto --dangerously-skip-permissions "\$@"; }
# Explicit per-account
$(printf '%b' "$EXPLICIT_FUNCS")alias $USAGE_ALIAS="bash ~/.claude/scripts/claude-usage.sh"
alias ccls='tmux ls'
alias cca='tmux attach'
ALIASES
  echo "  Added shell functions to $SHELL_RC:"
  echo "    $ALIAS_AUTO, $ALIAS_AUTO_R   — auto-pick across all $NUM_ACCOUNTS accounts"
  for i in $(seq 1 "$NUM_ACCOUNTS"); do
    echo "    cc${i}, cc${i}r              — explicit account $i"
  done
  echo "    $USAGE_ALIAS, ccls, cca"
fi

# 6. Create config dirs + symlink shared resources for accounts 2+
echo ""
echo "[6/6] Setting up config dirs..."
for i in $(seq 1 "$NUM_ACCOUNTS"); do
  d=$(account_dir_for "$i")
  mkdir -p "$d"
done

link_shared() {
  local target_dir="$1"
  local name="$2"
  local src="$HOME/.claude/$name"
  local dst="$target_dir/$name"
  [ ! -e "$src" ] && { echo "    skip $name (source missing)"; return; }
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "    skip $name (exists, not overwriting)"
    return
  fi
  if [ -L "$dst" ]; then
    [ "$(readlink "$dst")" = "$src" ] && { echo "    skip $name (already linked)"; return; }
    rm -f "$dst"
  fi
  ln -s "$src" "$dst"
  echo "    linked $name"
}

# Symlink shared resources for accounts 2..N (account 1 IS ~/.claude)
for i in $(seq 2 "$NUM_ACCOUNTS"); do
  d=$(account_dir_for "$i")
  echo "  $d:"
  for name in sessions projects plugins settings.json scripts CLAUDE.md; do
    link_shared "$d" "$name"
  done
done

# Final usage display
echo ""
echo "=== Installation complete ==="
echo ""
echo "NEXT: Login each account (one time per config dir)"
echo ""
if [ "$OS" = "linux" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -z "${DISPLAY:-}" ]; then
  echo "  Headless server detected."
  echo ""
  echo "  Option A — Copy credentials from local machine:"
  for i in $(seq 1 "$NUM_ACCOUNTS"); do
    d=$(account_dir_for "$i")
    echo "    scp <local>:$d/.credentials.json server:$d/.credentials.json"
  done
  echo ""
  echo "  Option B — SSH port forwarding for OAuth flow:"
  echo "    ssh -L 54545:localhost:54545 server"
  for i in $(seq 1 "$NUM_ACCOUNTS"); do
    d=$(account_dir_for "$i")
    if [ "$i" = "1" ]; then
      echo "    claude login                                # account 1"
    else
      echo "    CLAUDE_CONFIG_DIR=$d claude login   # account $i"
    fi
  done
else
  for i in $(seq 1 "$NUM_ACCOUNTS"); do
    d=$(account_dir_for "$i")
    if [ "$i" = "1" ]; then
      echo "  Account 1:  claude login"
    else
      echo "  Account $i:  CLAUDE_CONFIG_DIR=$d claude login"
    fi
  done
fi
echo ""
echo "Usage:"
echo "  $ALIAS_AUTO / $ALIAS_AUTO_R   — auto-pick across all accounts"
for i in $(seq 1 "$NUM_ACCOUNTS"); do
  echo "  cc${i} / cc${i}r              — explicit account $i"
done
echo "  $USAGE_ALIAS                  — show usage for all accounts"
echo "  ccls / cca                    — list / attach tmux sessions"
echo ""
echo "Rate limit handling is automatic — switches to next available account."
echo ""
echo "Restart your shell: source $SHELL_RC"
