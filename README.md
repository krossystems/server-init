# server-init

A single-script bootstrap for fresh Linux servers. Run it once as root and get a secure, ready-to-use server — optionally configured as a **Claude Code parallel development environment** with Mosh + Tmux session management.

## Architecture

```
 ┌─────────────────┐         ┌──────────────────────────────────────────────┐
 │  Mac (Ghostty)  │  Mosh   │  Ubuntu Server                              │
 │                 │ ──UDP──▸│  Tmux session "main"                        │
 │                 │         │  ┌────────┬────────┬────────┬────────┐      │
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
- **Helper commands** (`~/bin/tmuxs`, `~/bin/tmuxw`, `~/bin/claude-cost`) for session/window/cost management

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

This installs Mosh, JetBrains Mono font, and deploys Ghostty config. You manage your own `~/.ssh/config` and keys.

### Connecting

```bash
mosh myhost -- tmux new-session -A -s main
```

Replace `myhost` with any host from your `~/.ssh/config`. This connects via Mosh and attaches to the Tmux "main" session.

From iPhone (Blink Shell / Moshi), same command after Mosh connects:

```bash
tmux new-session -A -s main
```

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
| `mosh myhost -- tmux new-session -A -s main` | Connect via Mosh, attach to Tmux "main" |
| `tmuxs` | Attach/create "main" session |
| `tmuxs alpha` | Attach/create "alpha" session |
| `tmuxs alpha ~/code` | Create "alpha" with working directory ~/code |
| `tmuxs -l` | List all sessions |
| `tmuxs -k alpha` | Kill "alpha" session |
| `tmuxs -K` | Kill all unattached sessions |
| `tmuxw auth` | Create window "auth" (or jump to it if exists) |
| `tmuxw auth ~/pay` | Create window "auth" in ~/pay directory |
| `tmuxw -l` | List windows with status markers (table) |
| `tmuxw -a` | List all windows including parked (table) |
| `tmuxw -x auth` | Close "auth" window |
| `tmuxw -p auth` | Park "auth" to park-{session} |
| `tmuxw -p` | Park current window |
| `tmuxw -u auth` | Unpark "auth" back to current session |
| `clauded` | Run claude with --dangerously-skip-permissions (supports all args) |
| `clauded --resume ID` | Resume a session in dangerous mode |
| `claude-cost` | Session costs for current project directory |
| `claude-cost ~/proj` | Session costs for a specific directory |
| `claude-cost --all` | Session costs for all projects |

### Tmux keybindings

Prefix is `Ctrl+A`. Most navigation works without prefix.

> **Mac users:** `Alt` = `Option` key. Requires `macos-option-as-alt = true` in Ghostty config (`~/.config/ghostty/config`). Restart Ghostty after changing.

| Key | Action |
|-----|--------|
| `Option+1`..`Option+0` | Jump to window 1-10 |
| `Option+[` / `Option+]` | Previous / next window |
| `Option+N` | New window |
| `Option+H/J/K/L` | Navigate panes (vi-style) |
| `Option+arrows` | Navigate panes |
| `Option+F` | Floating popup shell (tmux 3.3+) |
| `Ctrl+A, d` | Detach from session |
| `Ctrl+A, \|` | Split pane horizontally |
| `Ctrl+A, -` | Split pane vertically |
| `Ctrl+A, V` | Join next window as side-by-side pane |
| `Ctrl+A, B` | Break pane into own window |
| `Ctrl+A, R` | Reload tmux config |

## Notification system

Window names show Claude Code's current state at a glance:

| State | Marker | Meaning |
|---|---|---|
| Working | ⏳ ↔ ⌛ | Hourglass flips on each tool use (animated) |
| Stop | 🟢 | Task completed, review when convenient |
| Loop | 🔄 | Loop iteration done, waiting for next run |
| Notification | 🔔 | Needs your input/decision |

```
Status bar example:
 1:⏳auth  2:🟢payment  3:🔔api  4:shell
   ↑          ↑            ↑
 working    completed   needs input
```

When a background window reaches Stop or Notification:

1. **Tmux bell** — the window turns yellow in the status bar
2. **Marker prefix** (🟢 or 🔔) — replaces the hourglass on the window name
3. **OS notification** — sent via OSC passthrough to Ghostty

All markers are automatically cleared when you switch to that window.

Use `tmuxw -a` to list all windows including parked.

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

- `tmuxs` uses `tmux attach -d` which detaches other clients automatically
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
│       ├── claude-status.sh        ← Hourglass animation on PreToolUse/PostToolUse
│       ├── clear-bell.sh           ← Clear markers on window focus
│       └── status-line.sh          ← Claude Code status line (git, tokens, cost, system)
├── scripts/
│   ├── tmuxs                       ← Tmux session manager
│   ├── tmuxw                       ← Tmux window manager
│   └── claude-cost                 ← Query Claude Code session costs by project
├── client/
│   ├── mac-setup.sh                ← Mac client setup (mosh, Ghostty, SSH sockets)
│   ├── ghostty-config              ← Ghostty terminal config
│   └── ssh-config-snippet          ← SSH ControlMaster / keepalive reference
├── README.md
└── LICENSE
```

## Contributing

Pull requests are welcome. Please test on at least one supported distro before submitting.

## License

[MIT](LICENSE)
