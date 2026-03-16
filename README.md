# server-init

A single-script bootstrap for fresh Linux servers. Run it once as root and get a secure, ready-to-use server — optionally configured as a **Claude Code parallel development environment** with Mosh + Tmux session management.

## Architecture

```
 ┌─────────────────┐         ┌──────────────────────────────────────────────┐
 │  Mac (Ghostty)  │  Mosh   │  Ubuntu Server                              │
 │                 │ ──UDP──▸│  Tmux session "main"                        │
 │  ~/bin/dev      │         │  ┌────────┬────────┬────────┬────────┐      │
 │                 │         │  │ 1:auth │ 2:pay  │ 3:api  │ 4:dash │ ... │
 │                 │         │  │ claude │ claude │ claude │ claude │      │
 └─────────────────┘         │  └────────┴────────┴────────┴────────┘      │
                             │   Alt+1    Alt+2    Alt+3    Alt+4          │
 ┌─────────────────┐         │                                              │
 │  iPhone (Blink) │ ──UDP──▸│  (same session — seamless device handoff)   │
 └─────────────────┘         └──────────────────────────────────────────────┘
```

Each Claude Code instance runs in its own Tmux **window**. When an instance finishes or needs input, a bell notification marks the window with 🔔 in the status bar, and an OS notification is sent via OSC passthrough to Ghostty.

## What it does

| Step | Action |
|------|--------|
| 1 | Updates all system packages |
| 2 | Installs essentials: `git`, `curl`, `wget`, `vim`, `htop`, `unzip`, ... |
| 3 | Creates a non-root sudo user (default: `krossys`) |
| 4 | Copies `authorized_keys` from root/cloud user to the new user |
| 5 | Installs **mosh**, **tmux**, and **jq** (opens UDP 60000-61000 in UFW) |
| 6 | *(optional)* Deploys **Claude Code parallel dev environment** |
| 7 | Configures swap automatically sized to available RAM |
| 8 | Hardens SSH: key-only auth, no password login, reduced grace time |
| 9 | Installs and configures **fail2ban** (SSH: 3 retries → 24h ban) |
| 10 | Enables automatic security updates |

### Claude Code environment (step 6, `--claude-code`)

When enabled, this step installs for the specified user:

- **Node.js** (via nvm) and **Claude Code** (`npm install -g @anthropic-ai/claude-code`)
- **Tmux config** (`~/.tmux.conf`) with Terminus Dark theme and optimized keybindings
- **Claude Code hooks** (`~/.claude/hooks/`) for bell + OS notifications
- **Claude Code settings** (`~/.claude/settings.json`) with Stop/Notification hooks
- **Helper commands** (`~/bin/cc`, `~/bin/work`) for session and instance management
- **Cleanup cron** (`~/bin/cleanup-sessions.sh`) to remove stale sessions

## Swap sizing policy

| RAM | Swap |
|-----|------|
| ≤ 2 GB | 2× RAM |
| 3–8 GB | = RAM |
| 9–64 GB | RAM / 2 (min 4 GB) |
| > 64 GB | 4 GB |

Also sets `vm.swappiness=10` and `vm.vfs_cache_pressure=50`. Skipped if swap is already present.

## Quick start

### Server setup

```bash
# Basic server hardening (no Claude Code)
curl -fsSL https://raw.githubusercontent.com/krossystems/server-init/main/init.sh \
  | sudo bash -s -- --username myuser

# With Claude Code parallel dev environment
curl -fsSL https://raw.githubusercontent.com/krossystems/server-init/main/init.sh \
  | sudo bash -s -- --username myuser --claude-code
```

> **Security note:** Piping `curl` to `bash` executes remote code directly. Review the script at the URL above before running it in a sensitive environment.

### Mac client setup

```bash
curl -fsSL https://raw.githubusercontent.com/krossystems/server-init/main/client/mac-setup.sh | bash
```

Or from a local clone: `bash client/mac-setup.sh`

This installs Mosh, JetBrains Mono font, deploys Ghostty config, creates an SSH key, and sets up the `dev` quick-connect command.

### Phone (iOS)

Install [Blink Shell](https://blink.sh) or Moshi, configure a Mosh connection to your server, then:

```bash
tmux new-session -A -s main
```

This attaches to the same session your Mac is using — seamless handoff.

## Options

```
-u, --username <name>     New sudo username (default: krossys)
    --no-tmux             Skip mosh + tmux installation
    --no-zellij           (deprecated alias for --no-tmux)
    --claude-code         Deploy Claude Code parallel dev environment
-h, --help                Show help
```

Environment variables: `NEW_USER`, `INSTALL_TMUX`, `INSTALL_CLAUDE_CODE`

```bash
NEW_USER=alice INSTALL_CLAUDE_CODE=true bash init.sh
```

## Daily operations

### Quick reference

| Command | What it does |
|---------|-------------|
| `dev` | Connect from Mac via Mosh, attach to Tmux "main" |
| `work` | Attach/create "main" session |
| `work alpha` | Attach/create "alpha" session |
| `work -l` | List all sessions |
| `work -k alpha` | Kill "alpha" session |
| `work -K` | Kill all unattached sessions |
| `cc auth` | Launch Claude Code in window "auth" |
| `cc payment ~/pay` | Launch in window "payment" with workdir ~/pay |
| `cc -l` | List all windows |
| `cc -a` | List windows with 🔔 alerts |
| `cc -g auth` | Jump to "auth" window |
| `cc -x auth` | Close "auth" window |

### Tmux keybindings

Prefix is `Ctrl+A`. Most navigation works without prefix.

| Key | Action |
|-----|--------|
| `Alt+1`..`Alt+0` | Jump to window 1-10 |
| `Alt+[` / `Alt+]` | Previous / next window |
| `Alt+N` | New window |
| `Alt+H/J/K/L` | Navigate panes (vi-style) |
| `Alt+arrows` | Navigate panes |
| `Alt+F` | Floating popup shell (tmux 3.3+) |
| `Prefix+\|` | Split pane horizontally |
| `Prefix+-` | Split pane vertically |
| `Prefix+V` | Join next window as side-by-side pane |
| `Prefix+B` | Break pane into own window |
| `Prefix+R` | Reload tmux config |

## Notification system

When Claude Code finishes a task (Stop hook) or needs input (Notification hook):

1. **Tmux bell** — the background window turns yellow in the status bar
2. **🔔 prefix** — added to the window name for visibility
3. **OS notification** — sent via OSC 777/9 passthrough to Ghostty

The 🔔 prefix is automatically cleared when you switch to that window (via `pane-focus-in` hook).

Use `cc -a` to list all windows currently needing attention.

## Session cleanup

A cron job runs every 6 hours and removes stale Tmux sessions:

| Session type | Threshold |
|---|---|
| `main` | Never cleaned up |
| `tmp-*` | Killed after 7 days unattached |
| Other | Killed after 30 days unattached |

## Supported distributions

| Distribution | Package manager |
|---|---|
| Ubuntu 20.04 / 22.04 / 24.04 | apt |
| Debian 11 / 12 | apt |
| CentOS Stream 8/9 / Rocky Linux / AlmaLinux | dnf |
| Fedora 38+ | dnf |
| Arch Linux | pacman (no automatic updates configured) |

## status.sh — Server health report

```bash
curl -fsSL https://raw.githubusercontent.com/krossystems/server-init/main/status.sh \
  | sudo bash
```

Checks system, hardware, storage, network, security, services, performance, updates, kernel tuning, and scheduled tasks. Ends with a PASS/WARN/FAIL health summary.

Exit codes: `0` = all clear, `1` = warnings only, `2` = at least one failure.

## After running

1. **Before closing your current session**, open a new terminal and verify:

   ```bash
   ssh alice@<server-ip>
   sudo whoami   # should print: root
   ```

2. Once confirmed, the original session can be closed.

## Troubleshooting

### Mosh connection fails

- Ensure UDP ports 60000-61000 are open in both UFW and your cloud provider's security group
- Mosh requires `mosh-server` on the server and `mosh` on the client
- Check: `ufw status | grep 60000`

### Alt keybindings don't work from Mac

- Ensure Ghostty has `macos-option-as-alt = true` in `~/.config/ghostty/config`
- If using a different terminal, look for an equivalent "Option as Meta/Alt" setting

### Tmux popup doesn't work

- `display-popup` requires Tmux 3.3+. Check: `tmux -V`
- Ubuntu 22.04 ships Tmux 3.2a — you'll get a friendly error message instead
- To upgrade: `sudo apt install -t jammy-backports tmux` or build from source

### Notifications not appearing

- Verify `allow-passthrough on` is in `~/.tmux.conf`
- Ensure hooks are executable: `chmod +x ~/.claude/hooks/*.sh`
- Test manually: `echo -e '\a'` in a background window should trigger bell

### Cross-device session handoff

- `work` uses `tmux attach -d` which detaches other clients automatically
- From phone: `tmux new-session -A -s main` does the same

## Project structure

```
server-init/
├── init.sh                         ← Server bootstrap script
├── status.sh                       ← Server health report
├── configs/
│   ├── tmux.conf                   ← Tmux configuration
│   ├── claude-settings.json        ← Claude Code hook settings
│   └── hooks/
│       ├── claude-notify.sh        ← Bell + OSC notification on Stop/Notification
│       └── clear-bell.sh           ← Clear 🔔 on window focus
├── scripts/
│   ├── cc                          ← Claude Code instance manager
│   ├── work                        ← Tmux session manager
│   └── cleanup-sessions.sh         ← Stale session cleanup (cron)
├── client/
│   ├── mac-setup.sh                ← Mac client one-click setup
│   ├── ghostty-config              ← Ghostty terminal config
│   └── ssh-config-snippet          ← SSH config reference
├── README.md
└── LICENSE
```

## Contributing

Pull requests are welcome. Please test on at least one supported distro before submitting.

## License

[MIT](LICENSE)
