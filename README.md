# Claude Account Switcher

Automatic account failover for Claude Code Max plan users with multiple subscriptions.

When one account hits the rate limit, automatically swaps credentials and resumes your work in a new session. If both accounts are exhausted, waits for recovery and auto-resumes.

## How it works

```
Session hits rate limit
  → StopFailure hook fires (API errors only, not Esc/Ctrl+C)
  → Saves current account's OAuth token from Keychain
  → Swaps in the other account's token
  → Opens new tmux session with `claude -r` (resume last session)
  → macOS notification

Both accounts exhausted?
  → Picks whichever recovers first
  → Background waiter sleeps until recovery
  → Swaps credentials + opens resume session + notification
```

**Key difference from other tools:** Existing tools ([claude-swap](https://github.com/realiti4/claude-swap), [claudini](https://github.com/kimrgrey/claudini), [cc-account-switcher](https://github.com/ming86/cc-account-switcher)) all require manual switching. This is the first to use Claude Code's `StopFailure` hook for automatic detection + credential swap + session resume.

## Prerequisites

- macOS (uses Keychain for credential storage)
- [Claude Code](https://claude.ai/code) with 2 Max plan accounts
- `jq` — `brew install jq`
- `tmux` — `brew install tmux`

## Install

```bash
git clone https://github.com/ernestolee13/claude-account-switcher.git
cd claude-account-switcher
bash install.sh
```

The installer:
1. Copies hook script + save script to `~/.claude/scripts/`
2. Registers `StopFailure` hook in `~/.claude/settings.json`
3. Adds `cc` / `cc2` aliases to your shell
4. Checks account login status

## Account setup

### Step 1: Save your current account

```bash
# Currently logged in as account 1
bash ~/.claude/scripts/claude-save-accounts.sh 1
```

### Step 2: Log in to second account and save

```bash
# In Claude Code session, switch to second account
/login
# → Browser opens, log in with second account

# Save it
bash ~/.claude/scripts/claude-save-accounts.sh 2
```

### Step 3: Switch back to primary account

```bash
/login
# → Browser opens, log in with primary account
```

That's it. Both accounts' OAuth tokens are now backed up. The hook will swap between them automatically.

## Usage

Just use Claude Code normally. When rate limit hits:

1. Hook fires automatically
2. Credentials swapped in Keychain
3. New tmux session opens with `claude -r` (resumes last session)
4. macOS notification tells you what happened

```bash
# Attach to the failover session
tmux attach -t claude-failover

# Or after both-exhausted recovery
tmux attach -t claude-resume
```

### Schedule a command for recovery

If both accounts are down and you want something to run when they recover:

```bash
echo 'bash ~/my-batch-script.sh' > /tmp/claude_resume_command
```

## How it works (technical)

Claude Code stores OAuth credentials in macOS Keychain under `Claude Code-credentials`. The hook:

1. Reads the current token from Keychain and saves it to `~/.claude/credentials-account{N}.json`
2. Writes the other account's saved token into Keychain
3. Opens `claude -r` in tmux — Claude Code reads the new token from Keychain on startup

This is the same mechanism as `/login` — just automated. Session history stays in `~/.claude/` so `claude -r` can resume.

## Files

| File | Purpose |
|------|---------|
| `on-ratelimit.sh` | StopFailure hook — credential swap + tmux resume |
| `claude-save-accounts.sh` | Backup current Keychain credentials to file |
| `install.sh` | One-command setup |

### Runtime state (in `/tmp/`, cleared on reboot)

| File | Purpose |
|------|---------|
| `claude_active_account` | Current active account (1 or 2) |
| `claude_ratelimit_account{1,2}` | Timestamp when each account hit rate limit |
| `claude_resume_command` | Optional command to run on recovery |
| `claude_resume_pid` | Background waiter PID (prevents duplicates) |

### Credential backups (in `~/.claude/`, gitignored)

| File | Purpose |
|------|---------|
| `credentials-account1.json` | Account 1 OAuth token backup |
| `credentials-account2.json` | Account 2 OAuth token backup |

## Configuration

Environment variables or edit `on-ratelimit.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_SWITCH_COOLDOWN` | `1800` | Seconds to assume rate limit lasts (30 min) |
| `TMUX_BIN` | `/opt/homebrew/bin/tmux` | Path to tmux binary |

## About the rate limit carryover bug

[GitHub #12786](https://github.com/anthropics/claude-code/issues/12786) reports that switching accounts via `logout/login` can cause the new account to inherit the old account's rate limit. This may be caused by device-level tracking in `~/.claude/statsig/`.

**In practice, many users (including the author) have not experienced this bug.** The `/login` approach works fine for most. If you do encounter it, the `CLAUDE_CONFIG_DIR` isolation approach (separate config directories per account) is a known workaround.

## Limitations

- **macOS only** — relies on Keychain. Linux/Windows would need credential file swap instead.
- **StopFailure hook** was added in Claude Code v2.1.78 (March 2026). Older versions won't work.
- **Cooldown estimate** (30 min) is approximate. Actual rate limit reset time varies.
- **New session required** — the hook can't refresh credentials in a running session. It opens a new `claude -r` session in tmux instead.

## Uninstall

```bash
rm ~/.claude/scripts/on-ratelimit.sh
rm ~/.claude/scripts/claude-save-accounts.sh
rm ~/.claude/credentials-account*.json
# Edit ~/.claude/settings.json — remove the "hooks" section
# Edit ~/.zshrc — remove "Claude Code multi-account" lines
rm -f /tmp/claude_active_account /tmp/claude_ratelimit_account* /tmp/claude_resume_*
```

## License

MIT
