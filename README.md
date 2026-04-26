# Claude Account Switcher

Automatic account failover for Claude Code with multiple Max plan subscriptions.

When one account hits the rate limit, the hook detects it, opens a new session with the other account, and resumes your work automatically. If both are exhausted, it waits for the first to recover and auto-resumes.

## How it works

```
Session hits rate limit
  → StopFailure hook fires (also detected via Stop hook + transcript check)
  → Opens a new cmux tab or tmux session with the alternate CLAUDE_CONFIG_DIR
  → Resumes the exact same conversation (-r <session_id>)
  → After 15s, auto-sends continue message so work picks up where it left off
  → Desktop notification (macOS osascript / Linux notify-send)

Both accounts exhausted?
  → Picks whichever recovers first
  → Background waiter sleeps until recovery
  → Auto-resumes in tmux + notification
```

Each `CLAUDE_CONFIG_DIR` automatically gets its own credential storage (separate macOS Keychain entry or separate `.credentials.json` on Linux), so no manual credential manipulation is needed.

## Prerequisites

- macOS or Linux
- [Claude Code](https://claude.ai/code) v2.1.78+ with 2 Max plan accounts
- `jq`
- `python3`
- `tmux` (recommended; auto-resume falls back to logging only if absent)
- Optional: [cmux](https://cmux.dev) on macOS for tab-based UX

## Install

```bash
git clone https://github.com/ernestolee13/claude-account-switcher.git
cd claude-account-switcher
bash install.sh
```

The installer detects OS, registers both hooks, and adds aliases to `.zshrc` or `.bashrc`.

### Customizing paths and alias names

Set env vars before running `install.sh`:

```bash
# Custom config dir for account 2
ACCOUNT2_DIR=~/.claude-work bash install.sh

# Custom alias names
ALIAS_1=cpersonal ALIAS_2=cwork bash install.sh

# Combine
ACCOUNT2_DIR=~/.claude-work ALIAS_1=home ALIAS_2=work bash install.sh
```

| Env var | Default | Purpose |
|---------|---------|---------|
| `ACCOUNT2_DIR` | `~/.claude-account2` | Path for second config dir |
| `ALIAS_AUTO` | `cc` | Auto-pick command (auto-derives `ccr`) |
| `ALIAS_1` | `cc1` | Explicit account 1 (auto-derives `cc1r`) |
| `ALIAS_2` | `cc2` | Explicit account 2 (auto-derives `cc2r`) |
| `USAGE_ALIAS` | `claude-usage` | Alias for the usage viewer |

The installer patches the installed hook script so that `ACCOUNT2_DIR` is baked in — you don't need to export it in every shell.

## Account setup

### Local machine (macOS or Linux desktop)

```bash
# Account 1 (default config dir: ~/.claude)
claude login

# Account 2 (separate config dir: ~/.claude-account2)
CLAUDE_CONFIG_DIR=~/.claude-account2 claude login
```

### Headless Linux server

OAuth login requires a browser. Two options:

**Option A — Copy credentials from a local login:**
```bash
# On your local machine (after claude login there):
scp ~/.claude/.credentials.json server:~/.claude/.credentials.json
scp ~/.claude-account2/.credentials.json server:~/.claude-account2/.credentials.json
```

**Option B — SSH port forwarding for the OAuth flow:**
```bash
ssh -L 54545:localhost:54545 server
# then on server:
claude login
```

Each config dir stores its own credentials. No manual token management needed after initial login.

## Usage

Commands are tmux-aware: each invocation opens a window named `acct1` or `acct2` in a session matching your project (basename of cwd, override with `CLAUDE_TMUX_SESSION`). Inside an existing tmux session it adds a window; outside it creates and attaches.

```bash
cc          # Auto-pick less-used account (default)
ccr         # Auto-pick + skip permission prompts
cc1         # Explicit account 1
cc1r        # Explicit account 1 + skip permission prompts
cc2         # Explicit account 2
cc2r        # Explicit account 2 + skip permission prompts

claude-usage  # Show 5h/7d usage for both accounts
ccls          # List tmux sessions
cca           # Attach last tmux session
```

`cc` / `ccr` query the OAuth usage API (5h utilization, then 7d as tiebreaker), prefer accounts under 100%, and pick the lower one. The decision is cached for 60s in `/tmp/claude_pick_account_cache` (override with `PICK_CACHE_TTL`, force refresh with `bash ~/.claude/scripts/pick-account.sh --no-cache`).

When rate limit hits, the hook automatically:
1. Opens a new cmux tab (or tmux session) with the alternate account
2. Resumes the exact same conversation via `-r <session_id>`
3. Sends a continue message after 15s so the work picks up where it left off

### Schedule a command for recovery

If both accounts are down and you want something to run when they recover:

```bash
echo 'bash ~/my-batch-script.sh' > /tmp/claude_resume_command
```

## Shared state between accounts

The installer automatically symlinks these from `~/.claude` into the second config dir so both accounts share them:

| Symlink | Purpose |
|---------|---------|
| `sessions/` | **Required** — session history for cross-account `-r <session_id>` |
| `projects/` | **Required** — conversation transcripts |
| `settings.json` | Shared hooks (so rate-limit hook fires for both) |
| `scripts/` | Hook scripts — the actual switcher code |
| `plugins/` | Shared plugins (OMC, etc.) |
| `CLAUDE.md` | Global instructions |

Account-specific data stays **separate** automatically:
- `.claude.json` (cached account metadata)
- Credentials (Keychain entry on macOS / `.credentials.json` on Linux)
- `statsig/` (device tracking)

If an existing file/dir exists at the symlink target, the installer leaves it alone — rerun-safe.

## How config dir isolation works

Claude Code uses `CLAUDE_CONFIG_DIR` to determine where to store settings, cache, and credentials:

| Platform | Default config | Account 2 config |
|----------|---------------|------------------|
| **macOS** | Keychain: `Claude Code-credentials` | Keychain: `Claude Code-credentials-<hash>` |
| **Linux** | `~/.claude/.credentials.json` | `~/.claude-account2/.credentials.json` |

This means each config dir has fully independent authentication — no token files to juggle, no manual Keychain manipulation, no race conditions.

## Files

| File | Purpose |
|------|---------|
| `on-ratelimit.sh` | StopFailure hook — detect rate limit, switch config dir, resume session, auto-continue |
| `on-stop-ratelimit.sh` | Stop hook — scan transcript's last assistant entry for rate_limit (primary detection on Claude Code 2.1.x) |
| `claude-usage.sh` | Show usage for both accounts via API (cross-platform: Keychain on macOS, file on Linux) |
| `pick-account.sh` | Pick less-used account by querying usage API (used by `cc`/`ccr` auto-pick; cached 60s) |
| `install.sh` | One-command setup (detects OS, registers hooks, adds shell functions) |

### Runtime state (in `/tmp/`, cleared on reboot)

| File | Purpose |
|------|---------|
| `claude_active_account` | Current active account (1 or 2) |
| `claude_ratelimit_account{1,2}` | Timestamp when each account hit rate limit |
| `claude_ratelimit_seen_uuids` | Dedup — UUIDs of rate-limit events already processed |
| `claude_resume_command` | Optional command to run on recovery |
| `claude_resume_pid` | Background waiter PID |
| `claude-resume-<pid>.sh` | Temp script for resume command |

### Debug logs (in `~/.claude/logs/`)

| File | Purpose |
|------|---------|
| `account-switch.log` | Hook decisions + state changes |
| `account-switch-payloads.log` | Raw hook inputs (rotated at 1MB) |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_SWITCH_COOLDOWN` | `1800` | Seconds before assuming rate limit expires (30 min) |
| `CLAUDE_CONFIG_DIR_2` | `~/.claude-account2` | Path to second config dir |
| `CLAUDE_RESUME_MESSAGE` | `Rate limit으로 계정이 전환되었습니다...` | Auto-continue message sent after resume |
| `TMUX_BIN` | auto-detected via `command -v tmux` | Path to tmux binary |

## Limitations

- **New session required** — the hook can't switch accounts mid-session. It opens a new session that resumes the conversation via `-r <session_id>`.
- **Cooldown is estimated** — the 30-minute default is approximate. Actual rate limit reset varies.
- **OMC HUD stale data** — if you use [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode), its status line reads from the default credential only, so sessions under a non-default `CLAUDE_CONFIG_DIR` may see incorrect usage in the HUD. Actual API calls and billing are unaffected. Use `claude-usage` for ground-truth numbers.

## License

MIT
