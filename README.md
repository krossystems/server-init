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

- **Set a password** for emergency console access:
  ```bash
  sudo passwd alice
  ```
- **Open application ports** in your cloud provider's security group / network ACL.
- **Set a hostname**:
  ```bash
  sudo hostnamectl set-hostname my-server
  ```
- **Install a language runtime** (Node.js, Python, Go, etc.)

## Contributing

Pull requests are welcome. Please test on at least one supported distro before submitting.

## License

[MIT](LICENSE)
