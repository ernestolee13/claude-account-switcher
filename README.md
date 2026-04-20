# Claude Account Switcher

Automatic account failover for Claude Code with multiple Max plan subscriptions.

When one account hits the rate limit, the hook detects it, opens a new session with the other account, and resumes your work automatically. If both are exhausted, it waits for the first to recover and auto-resumes.

## How it works

```
Session hits rate limit
  → StopFailure hook fires (also detected via Stop hook + transcript check)
  → Opens a new cmux tab (or tmux session) with the alternate CLAUDE_CONFIG_DIR
  → Resumes the exact same conversation (-r <session_id>)
  → After 15s, auto-sends "이전 작업을 이어서 진행해주세요" to continue the work
  → macOS notification + cmux display-message

Both accounts exhausted?
  → Picks whichever recovers first
  → Background waiter sleeps until recovery
  → Auto-resumes in tmux + notification
```

Each `CLAUDE_CONFIG_DIR` automatically gets its own Keychain entry (e.g., `Claude Code-credentials-<hash>`), so no manual credential swapping is needed.

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
# Login account 1 (default config dir: ~/.claude)
claude login

# Login account 2 (separate config dir: ~/.claude-account2)
CLAUDE_CONFIG_DIR=~/.claude-account2 claude login
```

Each config dir stores its own Keychain entry. No token files to manage.

## Usage

```bash
cc          # Start with account 1
cc2         # Start with account 2
ccr         # Account 1, skip permission prompts
cc2r        # Account 2, skip permission prompts
claude-usage  # Show 5h and 7d usage for both accounts
```

When rate limit hits, the hook automatically:
1. Opens a new tab (cmux) or tmux session with the alternate account
2. Resumes the exact same conversation via `-r <session_id>`
3. Sends a continue message so the work picks up where it left off

### Schedule a command for recovery

If both accounts are down and you want something to run when they recover:

```bash
echo 'bash ~/my-batch-script.sh' > /tmp/claude_resume_command
```

## Sharing state between accounts (optional)

For seamless work continuation, symlink shared resources so both accounts see the same sessions, plugins, and settings:

```bash
cd ~/.claude-account2
rm -rf sessions projects plugins CLAUDE.md settings.json scripts
ln -s ~/.claude/sessions sessions        # session history (for -r resume)
ln -s ~/.claude/projects projects        # project transcripts
ln -s ~/.claude/plugins plugins          # installed plugins
ln -s ~/.claude/CLAUDE.md CLAUDE.md      # global instructions
ln -s ~/.claude/settings.json settings.json  # hooks, env, status line
ln -s ~/.claude/scripts scripts          # hook scripts
```

This lets the switcher resume the same session on either account, since transcripts and settings are shared. Account-specific data (`.claude.json`, Keychain, `statsig/`) stays separate.

## How config dir isolation works

Claude Code uses `CLAUDE_CONFIG_DIR` to determine where to store settings, cache, and — crucially — which Keychain entry to use. A hash of the config dir path is appended to the Keychain service name:

```
~/.claude               → Keychain: "Claude Code-credentials"
~/.claude-account2      → Keychain: "Claude Code-credentials-<hash>"
```

This means each config dir has fully independent authentication. No token files, no manual Keychain manipulation, no race conditions.

## Files

| File | Purpose |
|------|---------|
| `on-ratelimit.sh` | StopFailure hook — detect rate limit, switch config dir, resume session, auto-continue |
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
| `claude-resume-<pid>.sh` | Temp script for resume command (avoids cmux send garbling) |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_SWITCH_COOLDOWN` | `1800` | Seconds before assuming rate limit expires (30 min) |
| `TMUX_BIN` | `/opt/homebrew/bin/tmux` | Path to tmux binary |

## Limitations

- **macOS only** — relies on Keychain. Linux would need a different credential backend.
- **New session required** — the hook can't switch accounts mid-session. It opens a new session that resumes the conversation via `-r <session_id>`.
- **Cooldown is estimated** — the 30-minute default is approximate. Actual rate limit reset varies.
- **Status bar (OMC HUD) may show stale data** — the OMC HUD reads from the default Keychain only, so sessions running under a non-default `CLAUDE_CONFIG_DIR` may see incorrect usage in the status bar. Actual API calls and billing are unaffected. Use `claude-usage` for the real numbers.

## License

MIT
