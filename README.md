# Claude Account Switcher

Automatic account failover for Claude Code Max plan users with multiple subscriptions.

When one account hits the rate limit, automatically switches to another — no manual intervention needed. If both accounts are exhausted, waits for recovery and auto-resumes.

## How it works

```
Session hits rate limit
  → Claude Code fires StopFailure event (API error only, not user Esc/Ctrl+C)
  → Hook matches on error_type: "rate_limit"
  → Switches active account (state file)
  → macOS notification
  → Opens tmux session with the other account

Both accounts exhausted?
  → Calculates which recovers first
  → Waits in background
  → Auto-opens session on recovery + notification
```

**Note:** The `StopFailure` hook only fires on API errors (rate limit, auth failure, server error). It does NOT fire on user abort (Esc, Ctrl+C) or normal exit (`/exit`, Ctrl+D). This means the hook won't interfere with normal usage.

## Prerequisites

- [Claude Code](https://claude.ai/code) with 2 Max plan accounts
- `jq` — `brew install jq`
- `tmux` (optional but recommended) — `brew install tmux`

## Install

```bash
git clone https://github.com/ernestolee13/claude-account-switcher.git
cd claude-account-switcher
bash install.sh
```

The installer:
1. Copies hook script to `~/.claude/scripts/`
2. Registers `StopFailure` hook in `~/.claude/settings.json`
3. Adds `cc` / `cc2` aliases to your shell
4. Checks account login status

## Account setup

After install, log in to each account:

```bash
# Account 1 — uses default ~/.claude (your current login)
# Already logged in if you use Claude Code normally

# Account 2 — uses separate config directory
CLAUDE_CONFIG_DIR=~/.claude-account2 claude login
# → Browser opens, log in with your second account
```

**Important:** Each account must have its own `CLAUDE_CONFIG_DIR`. Do NOT use `claude logout` + `claude login` to switch — this shares the same `~/.claude/statsig/` directory and [may cause rate limits to carry over between accounts](https://github.com/anthropics/claude-code/issues/12786).

## Usage

```bash
cc          # Start Claude with account 1 (default)
cc2         # Start Claude with account 2
```

That's it. Everything else is automatic:

- **Rate limit on one account** → Switches to the other, opens tmux session
- **Both accounts exhausted** → Waits ~30min, auto-resumes with whichever recovers first
- **macOS notification** on every switch and recovery

### Schedule a command for recovery

If both accounts are down and you want something to run automatically when they recover:

```bash
echo 'bash ~/my-batch-script.sh' > /tmp/claude_resume_command
```

The hook will execute this command instead of opening a tmux session.

### Attach to failover session

When the hook switches accounts, it opens a tmux session:

```bash
tmux attach -t claude-failover   # after single-account switch
tmux attach -t claude-resume     # after both-exhausted recovery
```

## How accounts are isolated

Claude Code stores credentials in macOS Keychain, keyed by a hash of the config directory path. Setting `CLAUDE_CONFIG_DIR` creates a fully independent credential store:

```
~/.claude/                → account 1 credentials + statsig
~/.claude-account2/       → account 2 credentials + statsig (independent)
```

This avoids the [rate limit carryover bug (#12786)](https://github.com/anthropics/claude-code/issues/12786) where `logout/login` on the same `~/.claude` directory causes the new account to inherit the old account's rate limit state.

## About the rate limit carryover bug

GitHub issue [#12786](https://github.com/anthropics/claude-code/issues/12786) reports that switching accounts via `claude logout` → `claude login` (same directory) can cause the new account to be immediately rate-limited. The suspected cause is `~/.claude/statsig/` retaining device-level rate limit tracking.

**Current status:** This bug may not affect all users. Some report switching via `/login` within a session works fine. The `CLAUDE_CONFIG_DIR` isolation approach works regardless — it's a safe default that avoids the issue entirely.

If `/login` switching works for you, you may not need this tool. This tool is most useful when:
- You want **automatic** switching (no manual `/login`)
- You run **batch scripts** (`claude -p`) that need unattended failover
- You want **both-exhausted recovery** with auto-resume

## Files

| File | Location | Purpose |
|------|----------|---------|
| `on-ratelimit.sh` | `~/.claude/scripts/` | StopFailure hook — account switch + resume logic |
| `settings.json` | `~/.claude/` | Hook registration (added by installer) |
| Shell aliases | `~/.zshrc` or `~/.bashrc` | `cc`, `cc2` shortcuts |

### Runtime state files (in `/tmp/`, cleared on reboot)

| File | Purpose |
|------|---------|
| `claude_active_account` | Current active account number (1 or 2) |
| `claude_ratelimit_account1` | Timestamp when account 1 hit rate limit |
| `claude_ratelimit_account2` | Timestamp when account 2 hit rate limit |
| `claude_resume_command` | Optional command to run on recovery |
| `claude_resume_pid` | PID of background resume waiter (prevents duplicates) |

## Configuration

Edit the top of `on-ratelimit.sh` to customize:

```bash
ACCOUNT2_DIR="${CLAUDE_ACCOUNT2_DIR:-$HOME/.claude-account2}"  # account 2 config path
COOLDOWN=1800          # seconds to assume rate limit lasts (default: 30 min)
TMUX="${TMUX_BIN:-/opt/homebrew/bin/tmux}"  # tmux binary path
```

Or set environment variables: `CLAUDE_ACCOUNT2_DIR`, `TMUX_BIN`.

## Uninstall

```bash
# Remove hook script
rm ~/.claude/scripts/on-ratelimit.sh

# Remove hook from settings.json (edit manually — remove the "hooks" section)

# Remove aliases from ~/.zshrc (remove the "Claude Code multi-account" lines)

# Remove account 2 config
rm -rf ~/.claude-account2

# Clean up state files
rm -f /tmp/claude_active_account /tmp/claude_ratelimit_account* /tmp/claude_resume_*
```

## License

MIT
