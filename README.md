# Claude Account Switcher

Automatic account failover for Claude Code with multiple Max plan subscriptions.

When one account hits the rate limit, the hook detects it, opens a new session with the other account, and resumes your work. If both are exhausted, it waits for the first to recover and auto-resumes.

## How it works

```
Session hits rate limit
  → StopFailure hook fires
  → Opens new session with alternate CLAUDE_CONFIG_DIR
  → Resumes the same conversation (-r <session_id>)
  → macOS notification + cmux/tmux integration

Both accounts exhausted?
  → Picks whichever recovers first
  → Background waiter sleeps until recovery
  → Opens resume session + notification
```

Each `CLAUDE_CONFIG_DIR` gets its own Keychain entry automatically (e.g., `Claude Code-credentials-33351ebb`), so no manual credential swapping is needed.

## Prerequisites

- macOS (uses Keychain)
- [Claude Code](https://claude.ai/code) v2.1.78+ with 2 Max plan accounts
- `jq` — `brew install jq`
- `tmux` — `brew install tmux` (optional if using [cmux](https://cmux.dev))

## Install

```bash
git clone https://github.com/ernestolee13/claude-account-switcher.git
cd claude-account-switcher
bash install.sh
```

## Account setup

```bash
# Login account 1 (default config dir)
claude login

# Login account 2 (separate config dir)
CLAUDE_CONFIG_DIR=~/.claude-account2 claude login
```

That's it. Each config dir stores its own Keychain entry. No token files to manage.

## Usage

```bash
cc          # Start with account 1
cc2         # Start with account 2
ccr         # Account 1, skip permission prompts
cc2r        # Account 2, skip permission prompts
```

When rate limit hits, the hook automatically opens a new tab (cmux) or tmux session with the other account and resumes the conversation.

### Check both accounts' usage

```bash
claude-usage        # Show 5h and 7d usage for both accounts
```

### Schedule a command for recovery

If both accounts are down and you want something to run when they recover:

```bash
echo 'bash ~/my-batch-script.sh' > /tmp/claude_resume_command
```

## Files

| File | Purpose |
|------|---------|
| `on-ratelimit.sh` | StopFailure hook — detect rate limit, switch config dir, resume session |
| `on-stop-ratelimit.sh` | Stop hook — check transcript for rate limit markers |
| `claude-usage.sh` | Show usage for both accounts via API |
| `install.sh` | One-command setup |

### Runtime state (in `/tmp/`, cleared on reboot)

| File | Purpose |
|------|---------|
| `claude_active_account` | Current active account (1 or 2) |
| `claude_ratelimit_account{1,2}` | Timestamp when each account hit rate limit |
| `claude_resume_command` | Optional command to run on recovery |
| `claude_resume_pid` | Background waiter PID |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_SWITCH_COOLDOWN` | `1800` | Seconds before assuming rate limit expires (30 min) |
| `TMUX_BIN` | `/opt/homebrew/bin/tmux` | Path to tmux binary |

## How config dir isolation works

Claude Code uses `CLAUDE_CONFIG_DIR` to determine where to store settings, cache, and — crucially — which Keychain entry to use. A hash of the config dir path is appended to the Keychain service name:

```
~/.claude               → Keychain: "Claude Code-credentials"
~/.claude-account2      → Keychain: "Claude Code-credentials-33351ebb"
```

This means each config dir has fully independent authentication. No token files, no manual Keychain manipulation, no race conditions.

## Limitations

- **macOS only** — relies on Keychain. Linux would need a different credential backend.
- **New session required** — the hook can't switch accounts mid-session. It opens a new session that resumes the conversation.
- **Cooldown is estimated** — the 30-minute default is approximate. Actual rate limit reset varies.

## License

MIT
