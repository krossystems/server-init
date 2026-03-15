# server-init

A single-script bootstrap for fresh Linux servers. Run it once as root and get a secure, ready-to-use server with a non-root sudo user, SSH hardening, swap, fail2ban, and essential tooling.

## What it does

| Step | Action |
|------|--------|
| 1 | Updates all system packages |
| 2 | Installs essentials: `git`, `curl`, `wget`, `vim`, `htop`, `unzip`, ... |
| 3 | Creates a non-root sudo user (default: `krossys`) |
| 4 | Copies `authorized_keys` from root/cloud user to the new user |
| 5 | Installs **[zellij](https://zellij.dev)** (terminal multiplexer) |
| 6 | Configures swap automatically sized to available RAM |
| 7 | Hardens SSH: key-only auth, no password login, reduced grace time |
| 8 | Installs and configures **fail2ban** (SSH: 3 retries → 24h ban) |
| 9 | Enables automatic security updates |

## Swap sizing policy

| RAM | Swap |
|-----|------|
| ≤ 2 GB | 2× RAM |
| 3–8 GB | = RAM |
| 9–64 GB | RAM / 2 (min 4 GB) |
| > 64 GB | 4 GB |

Also sets `vm.swappiness=10` and `vm.vfs_cache_pressure=50` — suitable defaults for server workloads. Skipped automatically if swap is already present.

## Quick start

Connect as `root` (or your cloud provider's default user) and run:

```bash
curl -fsSL https://raw.githubusercontent.com/krossystems/server-init/main/init.sh | bash
```

With a custom username:

```bash
curl -fsSL https://raw.githubusercontent.com/krossystems/server-init/main/init.sh | bash -s -- --username alice
```

> **Security note:** Piping `curl` to `bash` executes remote code directly. Review the script at the URL above before running it in a sensitive environment.

## Options

```
-u, --username <name>     New sudo username (default: krossys)
    --no-zellij           Skip zellij installation
-h, --help                Show help
```

You can also use environment variables:

```bash
NEW_USER=alice bash init.sh
```

## Supported distributions

| Distribution | Package manager |
|---|---|
| Ubuntu 20.04 / 22.04 / 24.04 | apt |
| Debian 11 / 12 | apt |
| CentOS Stream 8/9 / Rocky Linux / AlmaLinux | dnf |
| Fedora 38+ | dnf |
| Arch Linux | pacman (no automatic updates configured) |

## After running

1. **Before closing your current session**, open a new terminal and verify:

   ```bash
   ssh alice@<server-ip>
   sudo whoami   # should print: root
   ```

2. Once confirmed, the original session can be closed.

## Manual steps you may still want

- **Set a password** for emergency VPS-console access (SSH password login is disabled, but a password lets you log in via your provider's web console if you lose your key):
  ```bash
  sudo passwd alice
  ```
- **Open application ports** in your cloud provider's security group / network ACL.
- **Set a hostname**:
  ```bash
  sudo hostnamectl set-hostname my-server
  ```
- **Install a language runtime** (Node.js, Python, Go, etc.)

## status.sh — Server health report

After logging in as the new user, run `status.sh` to get a full picture of the server.

```bash
# Pull and run (recommended — full output)
curl -fsSL https://raw.githubusercontent.com/krossystems/server-init/main/status.sh \
  | sudo bash

# Or if already cloned
sudo bash status.sh
```

### What it checks

| Section | Checks |
|---------|--------|
| **System** | Hostname, OS, kernel, uptime, timezone, NTP sync, virt type |
| **Hardware** | CPU model/cores, RAM usage, swap usage |
| **Storage** | Disk usage per filesystem, inode usage, swap devices |
| **Network** | Public IP, interfaces, gateway, DNS resolution, listening ports |
| **Security** | SSH effective config, authorized keys + fingerprints, fail2ban status/bans, failed auth attempts (24h), top attacking IPs, last logins |
| **Services** | sshd, fail2ban, auto-update daemon, Docker containers, any failed systemd units |
| **Performance** | Load average vs CPU count, top 5 by CPU/RAM, OOM events, I/O wait |
| **Updates** | Pending security updates, total pending, reboot-required flag |
| **Kernel tuning** | swappiness, vfs_cache_pressure, tcp_syncookies, ip_forward, open fd count, recent dmesg errors |
| **Scheduled tasks** | User/root crontab, /etc/cron.d, upcoming systemd timers |

### Health summary

Every check contributes a `[PASS]`, `[WARN]`, or `[FAIL]` result. The script ends with a consolidated summary:

```
╔══════════════════════════════════════════════════════╗
║              SERVER HEALTH SUMMARY                  ║
╚══════════════════════════════════════════════════════╝

  [FAIL]  2 pending security updates
  [WARN]  SSH: 143 failed auth attempts in 24h
  [WARN]  Disk /dev/sda1 is 83% full
  [PASS]  NTP synchronized
  [PASS]  SSH: key-only auth
  [PASS]  fail2ban active
  [PASS]  No failed systemd units
  ...

  Checks:  8 PASS  /  2 WARN  /  1 FAIL  (11 total)
```

Exit codes: `0` = all clear, `1` = warnings only, `2` = at least one failure. Usable in CI or monitoring scripts.

> **Note:** Running with `sudo` unlocks all checks (process names on ports, auth logs, fail2ban details, kernel errors). Without sudo, output is still useful but some sections are limited.

---

## Contributing

Pull requests are welcome. Please test on at least one supported distro before submitting.

## License

[MIT](LICENSE)
