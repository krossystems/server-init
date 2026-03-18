#!/usr/bin/env bash
# ==============================================================================
# server-init — Bootstrap a fresh Linux server with a secure non-root user
# https://github.com/krossystems/server-init
#
# Usage:
#   bash init.sh [OPTIONS]
#
# Quick start (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/krossystems/server-init/main/init.sh \
#     | bash -s -- --username myuser
# ==============================================================================

set -euo pipefail

# Print the failing line/command whenever set -e triggers an exit
trap 'error "Aborted at line $LINENO: $BASH_COMMAND"' ERR

# Non-interactive environment — set globally so all child processes inherit
# (needrestart, debconf, dpkg post-install scripts, etc.)
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export NEEDRESTART_MODE=a       # auto-restart services on Ubuntu 22.04+
export NEEDRESTART_SUSPEND=1    # suppress needrestart prompts entirely

# ── Defaults ──────────────────────────────────────────────────────────────────
NEW_USER="${NEW_USER:-krossys}"
INSTALL_TMUX="${INSTALL_TMUX:-true}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-false}"

# GitHub raw base URL (used when running via curl | bash without a local clone)
GITHUB_RAW="https://raw.githubusercontent.com/krossystems/server-init/main"

# Step outcome tracking (used by print_summary for smart messages)
USER_EXISTED=false
KEYS_EXISTED=false
SSH_HARDENED=false

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; NC=''
fi

log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}── $* ──────────────────────────────────${NC}"; }
die()     { error "$*"; exit 1; }

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}server-init${NC} — Secure server bootstrap script

${BOLD}Usage:${NC}
  bash init.sh [OPTIONS]

${BOLD}Options:${NC}
  -u, --username <name>     Username for the new sudo user (default: krossys)
      --no-tmux             Skip mosh + tmux installation
      --no-zellij           (deprecated alias for --no-tmux)
      --claude-code         Deploy Claude Code parallel dev environment for the user
  -h, --help                Show this help

${BOLD}Environment variables (alternative to flags):${NC}
  NEW_USER, INSTALL_TMUX, INSTALL_CLAUDE_CODE

${BOLD}Examples:${NC}
  bash init.sh --username john
  bash init.sh --username john --claude-code
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--username)  NEW_USER="$2";            shift 2 ;;
    --no-tmux|--no-zellij) INSTALL_TMUX=false; shift  ;;
    --claude-code)  INSTALL_CLAUDE_CODE=true; shift   ;;
    -h|--help)      usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
done

# ── Root check / auto-elevate ─────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  # Running as a file: re-exec under sudo transparently
  if [[ -f "$0" ]] && command -v sudo &>/dev/null; then
    exec sudo bash "$0" "$@"
  fi
  # Running via pipe (curl | bash): can't re-exec, give the correct command
  die "Must run as root. Use: curl -fsSL <url> | sudo bash"
fi

if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  die "Invalid username: '$NEW_USER'. Must start with a letter/underscore and contain only a-z, 0-9, _ or -."
fi

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect OS: /etc/os-release not found."
  fi

  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop)
      PKG_MANAGER="apt"
      ;;
    centos|rhel|rocky|almalinux|fedora|ol)
      PKG_MANAGER=$(command -v dnf &>/dev/null && echo "dnf" || echo "yum")
      ;;
    arch|manjaro)
      PKG_MANAGER="pacman"
      ;;
    *)
      if echo "$OS_ID_LIKE" | grep -qiE "debian|ubuntu"; then
        PKG_MANAGER="apt"
      elif echo "$OS_ID_LIKE" | grep -qiE "rhel|centos|fedora"; then
        PKG_MANAGER="dnf"
      else
        die "Unsupported OS: $OS_ID. Supported: Ubuntu/Debian, CentOS/RHEL/Rocky/Alma, Fedora, Arch."
      fi
      ;;
  esac

  log "Detected OS: ${PRETTY_NAME:-$OS_ID} (package manager: $PKG_MANAGER)"
}

# ── Package management helpers ────────────────────────────────────────────────
# apt wrapper: non-interactive, waits up to 5 min for the dpkg lock,
# resolves config-file conflicts automatically (env vars inherited from top).
_apt() {
  apt-get \
    -y \
    -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "$@"
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      # apt-get update may return non-zero if some repos are unreachable —
      # that is non-fatal; we still proceed with whatever was fetched.
      apt-get -q -o DPkg::Lock::Timeout=300 update \
        || warn "Some package lists failed to fetch (continuing with cached data)"
      _apt upgrade
      ;;
    dnf|yum) $PKG_MANAGER update -y -q ;;
    pacman)  pacman -Syu --noconfirm -q ;;
  esac
}

pkg_install() {
  case "$PKG_MANAGER" in
    apt)     _apt install "$@" ;;
    dnf|yum) $PKG_MANAGER install -y -q "$@" ;;
    pacman)  pacman -S --noconfirm -q "$@" ;;
  esac
}

# ── Step 1: Update packages ───────────────────────────────────────────────────
# On Ubuntu/Debian, unattended-upgrades / apt-daily often hold the dpkg lock
# for 10–30 min after boot.  We must actively kill them — passive waiting
# (DPkg::Lock::Timeout, systemctl stop) can block just as long.
stop_unattended_apt() {
  [[ "$PKG_MANAGER" != "apt" ]] && return

  # 1. Disable timers so nothing re-triggers during setup
  systemctl stop    apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

  # Safety net: re-enable timers on exit (even if script fails mid-way)
  trap 'systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true' EXIT

  # 2. Kill the services (SIGTERM to entire cgroup — immediate, no grace wait)
  systemctl kill apt-daily.service apt-daily-upgrade.service \
                 unattended-upgrades.service 2>/dev/null || true
  sleep 1

  # 3. If lock is still held (orphaned / reparented process), kill it directly
  local pids
  pids=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null) || true
  if [[ -n "$pids" ]]; then
    warn "dpkg lock held by pid $pids — killing..."
    kill $pids 2>/dev/null || true
    sleep 2
    # Force-kill anything that survived SIGTERM
    pids=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null) || true
    if [[ -n "$pids" ]]; then
      kill -9 $pids 2>/dev/null || true
      sleep 1
    fi
  fi

  # 4. Repair any half-configured packages left by a killed dpkg
  dpkg --configure -a 2>/dev/null || true
}

step_update_packages() {
  section "Updating package lists and upgrading system"
  stop_unattended_apt
  pkg_update
  log "System packages updated."
}

# ── Step 2: Install essential tools ──────────────────────────────────────────
step_install_essentials() {
  section "Installing essential packages"

  local pkgs=(git curl wget vim nano htop unzip tar ca-certificates gnupg lsb-release)

  case "$PKG_MANAGER" in
    apt)     pkgs+=(build-essential apt-transport-https software-properties-common) ;;
    dnf|yum) pkgs+=(gcc make epel-release) ;;
    pacman)  pkgs+=(base-devel) ;;
  esac

  pkg_install "${pkgs[@]}"
  log "Essential packages installed."
}

# ── Step 3: Create sudo user ──────────────────────────────────────────────────
step_create_user() {
  section "Creating user: $NEW_USER"

  USER_EXISTED=false
  if id "$NEW_USER" &>/dev/null; then
    warn "User '$NEW_USER' already exists. Skipping creation."
    USER_EXISTED=true
  else
    useradd -m -s /bin/bash "$NEW_USER"
    log "User '$NEW_USER' created."
  fi

  case "$PKG_MANAGER" in
    apt)
      usermod -aG sudo "$NEW_USER"
      log "Added '$NEW_USER' to group: sudo"
      ;;
    dnf|yum|pacman)
      usermod -aG wheel "$NEW_USER"
      log "Added '$NEW_USER' to group: wheel"
      if ! grep -qE '^\s*%wheel\s+ALL=\(ALL\)\s+ALL' /etc/sudoers 2>/dev/null; then
        echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
      fi
      ;;
  esac

  # Passwordless sudo via a drop-in sudoers file (safer than editing /etc/sudoers)
  local sudoers_file="/etc/sudoers.d/${NEW_USER}"
  echo "${NEW_USER} ALL=(ALL) NOPASSWD: ALL" > "$sudoers_file"
  chmod 440 "$sudoers_file"
  log "Passwordless sudo configured for '$NEW_USER' ($sudoers_file)."

  # No password is set on a fresh account (SSH key login only via sshd config).
  # Set one manually for emergency VPS-console access: sudo passwd $NEW_USER
  if [[ "$USER_EXISTED" == "false" ]]; then
    log "No password set for '$NEW_USER'. Set one later for emergency console access: sudo passwd $NEW_USER"
  fi
}

# ── Step 4: Copy SSH authorized keys ─────────────────────────────────────────
step_copy_ssh_keys() {
  section "Copying SSH authorized keys to $NEW_USER"

  local src_keys=""

  # Candidate locations: SUDO_USER first, then root, then common cloud users
  local candidates=("/root/.ssh/authorized_keys")
  for candidate_user in azureuser ubuntu ec2-user centos admin; do
    local candidate_home
    candidate_home=$(getent passwd "$candidate_user" 2>/dev/null | cut -d: -f6 || true)
    [[ -n "$candidate_home" ]] && candidates+=("$candidate_home/.ssh/authorized_keys")
  done
  if [[ -n "${SUDO_USER:-}" ]]; then
    local sudo_home
    sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    candidates=("$sudo_home/.ssh/authorized_keys" "${candidates[@]}")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" && -s "$candidate" ]]; then
      src_keys="$candidate"
      log "Found authorized_keys at: $src_keys"
      break
    fi
  done

  if [[ -z "$src_keys" ]]; then
    warn "No authorized_keys found. Add SSH keys for '$NEW_USER' manually:"
    warn "  ssh-copy-id -i ~/.ssh/id_rsa.pub ${NEW_USER}@<server-ip>"
    return
  fi

  local dest_dir="/home/${NEW_USER}/.ssh"
  local dest_keys="${dest_dir}/authorized_keys"

  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$dest_dir"

  if [[ -f "$dest_keys" && -s "$dest_keys" ]]; then
    KEYS_EXISTED=true
    log "authorized_keys already exist for '$NEW_USER' — skipping copy to preserve existing keys."
    ssh-keygen -lf "$dest_keys" 2>/dev/null | sed 's/^/  /' || true
    return
  fi

  KEYS_EXISTED=false
  install -m 600 -o "$NEW_USER" -g "$NEW_USER" "$src_keys" "$dest_keys"
  log "SSH authorized_keys copied to $dest_keys"
}

# ── Config file resolver ─────────────────────────────────────────────────────
# If init.sh was run from a local clone, read from the repo.  Otherwise fetch
# from GitHub.  Usage: get_config_file <relative-path> → prints content to stdout.
get_config_file() {
  local relpath="$1"
  # $SCRIPT_DIR is set in main() before any step runs
  if [[ -f "${SCRIPT_DIR}/${relpath}" ]]; then
    cat "${SCRIPT_DIR}/${relpath}"
  else
    curl -fsSL "${GITHUB_RAW}/${relpath}"
  fi
}

# Deploy a config file to a target path owned by a specific user.
# If the destination already exists, backs it up (.bak) before overwriting.
# Usage: deploy_config <relative-path> <dest-path> <owner> <mode>
deploy_config() {
  local relpath="$1" dest="$2" owner="$3" mode="${4:-644}"
  install -d -o "$owner" -g "$owner" "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    cp "$dest" "${dest}.bak"
    chown "$owner:$owner" "${dest}.bak"
    log "Backed up existing ${dest} → ${dest}.bak"
  fi
  get_config_file "$relpath" > "$dest"
  chown "$owner:$owner" "$dest"
  chmod "$mode" "$dest"
}

# ── Step 5: Install mosh + tmux ─────────────────────────────────────────────
step_install_tmux_mosh() {
  section "Installing mosh, tmux, and jq"

  local pkgs=(mosh tmux jq)
  pkg_install "${pkgs[@]}"

  # Open Mosh UDP ports in ufw if active
  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 60000:61000/udp comment "Mosh" >/dev/null 2>&1 || true
    log "UFW: opened UDP 60000-61000 for Mosh."
  fi

  log "mosh $(mosh --version 2>&1 | head -1 || echo '?'), tmux $(tmux -V 2>/dev/null || echo '?'), jq installed."
}

# ── Step 6: Deploy Claude Code parallel dev environment ──────────────────────
step_setup_claude_code() {
  section "Setting up Claude Code parallel dev environment for $NEW_USER"

  local user_home="/home/${NEW_USER}"

  # 6a — Ensure Node.js and Claude Code are available
  if su - "$NEW_USER" -c 'command -v claude' &>/dev/null; then
    log "Claude Code already installed."
  else
    # Need Node.js first — prefer system node, fall back to nvm
    if ! su - "$NEW_USER" -c 'command -v node' &>/dev/null; then
      log "Node.js not found — installing via nvm..."
      su - "$NEW_USER" -c 'bash -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        if [ ! -d \"\$NVM_DIR\" ]; then
          curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
        fi
        . \"\$NVM_DIR/nvm.sh\"
        nvm install --lts
      "'
      log "Node.js installed via nvm."
    else
      log "Node.js already available: $(su - "$NEW_USER" -c 'node --version' 2>/dev/null)"
    fi

    log "Installing Claude Code..."
    su - "$NEW_USER" -c 'npm install -g @anthropic-ai/claude-code'
    log "Claude Code installed."
  fi

  # 6b — Deploy tmux.conf
  deploy_config "configs/tmux.conf" "${user_home}/.tmux.conf" "$NEW_USER" 644
  log "Deployed ~/.tmux.conf"

  # 6c — Deploy Claude Code hooks
  deploy_config "configs/hooks/claude-notify.sh" \
    "${user_home}/.claude/hooks/claude-notify.sh" "$NEW_USER" 755
  deploy_config "configs/hooks/claude-status.sh" \
    "${user_home}/.claude/hooks/claude-status.sh" "$NEW_USER" 755
  deploy_config "configs/hooks/clear-bell.sh" \
    "${user_home}/.claude/hooks/clear-bell.sh" "$NEW_USER" 755
  deploy_config "configs/hooks/status-line.sh" \
    "${user_home}/.claude/hooks/status-line.sh" "$NEW_USER" 755
  log "Deployed Claude Code hook scripts."

  # 6d — Deploy Claude Code settings.json (merge hooks if file already exists)
  local settings_dest="${user_home}/.claude/settings.json"
  install -d -o "$NEW_USER" -g "$NEW_USER" "$(dirname "$settings_dest")"
  if [[ -f "$settings_dest" ]]; then
    # File exists — check if hooks are already configured
    if jq -e '.hooks.Stop' "$settings_dest" &>/dev/null; then
      log "Claude Code settings.json already has hooks configured."
    else
      # Merge hooks into existing settings
      local hooks_json
      hooks_json=$(get_config_file "configs/claude-settings.json")
      jq -s '.[0] * .[1]' "$settings_dest" <(echo "$hooks_json") > "${settings_dest}.tmp"
      mv "${settings_dest}.tmp" "$settings_dest"
      chown "$NEW_USER:$NEW_USER" "$settings_dest"
      log "Merged hooks into existing ~/.claude/settings.json"
    fi
  else
    deploy_config "configs/claude-settings.json" "$settings_dest" "$NEW_USER" 644
    log "Deployed ~/.claude/settings.json"
  fi

  # 6e — Deploy helper scripts (tmuxs, tmuxw)
  install -d -o "$NEW_USER" -g "$NEW_USER" "${user_home}/bin"
  deploy_config "scripts/tmuxs" "${user_home}/bin/tmuxs" "$NEW_USER" 755
  deploy_config "scripts/tmuxw" "${user_home}/bin/tmuxw" "$NEW_USER" 755
  log "Deployed ~/bin/tmuxs and ~/bin/tmuxw"

  # 6f — Deploy cleanup-sessions.sh and cron job
  deploy_config "scripts/cleanup-sessions.sh" \
    "${user_home}/bin/cleanup-sessions.sh" "$NEW_USER" 755

  local cron_job="0 */6 * * * ${user_home}/bin/cleanup-sessions.sh >> /tmp/tmux-cleanup.log 2>&1"
  if ! su - "$NEW_USER" -c "crontab -l 2>/dev/null" | grep -qF "cleanup-sessions.sh"; then
    ( su - "$NEW_USER" -c "crontab -l 2>/dev/null" || true; echo "$cron_job" ) \
      | su - "$NEW_USER" -c "crontab -"
    log "Installed cleanup-sessions cron job (every 6h)."
  else
    log "Cleanup cron job already exists."
  fi

  # 6g — Configure shell environment (PATH, locale, and nvm if installed)
  local profile="${user_home}/.bashrc"
  local marker="# --- server-init: claude-code environment ---"
  if ! grep -qF "$marker" "$profile" 2>/dev/null; then
    cat >> "$profile" <<EOF

$marker
export PATH="\$HOME/bin:\$PATH"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
EOF
    # Only add nvm sourcing if nvm was actually installed
    if [[ -d "${user_home}/.nvm" ]]; then
      cat >> "$profile" <<'EOF'

# nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
EOF
    fi
    chown "$NEW_USER:$NEW_USER" "$profile"
    log "Configured shell environment in ~/.bashrc"
  else
    log "Shell environment already configured."
  fi

  log "Claude Code parallel dev environment ready for '$NEW_USER'."
}

# ── Step 7: Configure swap ────────────────────────────────────────────────────
step_setup_swap() {
  section "Configuring swap"

  # Always ensure kernel tuning is applied (safe to set even if swap pre-exists)
  local sysctl_conf="/etc/sysctl.d/99-swap.conf"
  cat > "$sysctl_conf" <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
  sysctl -p "$sysctl_conf" > /dev/null

  # Skip swap file creation if any swap is already active
  if [[ $(swapon --show | wc -l) -gt 0 ]]; then
    log "Swap already configured:"
    swapon --show
    return
  fi

  # Calculate swap size based on available RAM
  local ram_kb ram_gb swap_gb
  ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  ram_gb=$(( ram_kb / 1024 / 1024 ))

  # Sizing policy:
  #   RAM ≤ 2 GB  → swap = 2× RAM
  #   RAM 3–8 GB  → swap = RAM
  #   RAM 9–64 GB → swap = RAM / 2  (min 4 GB)
  #   RAM > 64 GB → swap = 4 GB
  if   (( ram_gb <= 2  )); then swap_gb=$(( ram_gb * 2 ))
  elif (( ram_gb <= 8  )); then swap_gb=$ram_gb
  elif (( ram_gb <= 64 )); then swap_gb=$(( ram_gb / 2 ))
                                (( swap_gb < 4 )) && swap_gb=4
  else                          swap_gb=4
  fi
  # Floor at 1 GB for very small VMs (e.g. 512 MB RAM → ram_gb rounds to 0)
  (( swap_gb < 1 )) && swap_gb=1

  log "RAM: ~${ram_gb} GB → swap size: ${swap_gb} GB"

  local swapfile="/swapfile"

  # Allocate with fallocate; fall back to dd on filesystems that don't support it
  if ! fallocate -l "${swap_gb}G" "$swapfile" 2>/dev/null; then
    warn "fallocate failed, falling back to dd (this may take a moment)..."
    dd if=/dev/zero of="$swapfile" bs=1M count=$(( swap_gb * 1024 )) status=progress
  fi

  chmod 600 "$swapfile"
  mkswap "$swapfile"
  swapon "$swapfile"

  # Persist across reboots
  if ! grep -q "$swapfile" /etc/fstab; then
    echo "${swapfile} none swap sw 0 0" >> /etc/fstab
  fi

  log "Swap configured: ${swap_gb} GB at $swapfile (swappiness=10)."
}

# ── Step 7: Harden SSH ────────────────────────────────────────────────────────
step_harden_ssh() {
  section "Hardening SSH configuration"

  local sshd_config="/etc/ssh/sshd_config"
  local backup="${sshd_config}.bak"
  local changed=false

  # Sets a key=value in sshd_config. No-ops if already correct.
  # Creates a single backup (.bak) on the first change of each run.
  set_sshd_option() {
    local key="$1" val="$2"
    # Already set to the exact desired value (uncommented)? Skip.
    if grep -qE "^\s*${key}\s+${val}\s*$" "$sshd_config" 2>/dev/null; then
      return
    fi
    # First change this run: back up current state
    if [[ "$changed" == "false" ]]; then
      cp "$sshd_config" "$backup"
      log "SSH config backed up to: $backup"
    fi
    changed=true
    if grep -qE "^\s*#?\s*${key}\s" "$sshd_config"; then
      sed -i -E "s|^\s*#?\s*${key}\s.*|${key} ${val}|" "$sshd_config"
    else
      echo "${key} ${val}" >> "$sshd_config"
    fi
  }

  set_sshd_option "PasswordAuthentication"          "no"
  set_sshd_option "KbdInteractiveAuthentication"    "no"

  # ChallengeResponseAuthentication was removed in OpenSSH 9.0 (Ubuntu 24.04+).
  # Only set it on older versions; KbdInteractiveAuthentication covers both.
  local ssh_major
  ssh_major=$(ssh -V 2>&1 | grep -oE 'OpenSSH_[0-9]+' | grep -oE '[0-9]+' || echo "0")
  if (( ssh_major < 9 )); then
    set_sshd_option "ChallengeResponseAuthentication" "no"
  else
    # Remove the deprecated option if a previous run left it in the file
    sed -i -E '/^\s*#?\s*ChallengeResponseAuthentication\s/d' "$sshd_config"
  fi
  set_sshd_option "UsePAM"                          "yes"
  set_sshd_option "PubkeyAuthentication"            "yes"
  set_sshd_option "AuthorizedKeysFile"              ".ssh/authorized_keys"
  set_sshd_option "PermitEmptyPasswords"            "no"
  set_sshd_option "MaxAuthTries"                    "4"
  set_sshd_option "LoginGraceTime"                  "30"
  set_sshd_option "X11Forwarding"                   "no"
  set_sshd_option "AllowAgentForwarding"            "yes"
  set_sshd_option "AllowTcpForwarding"              "yes"
  set_sshd_option "PrintLastLog"                    "yes"
  set_sshd_option "ClientAliveInterval"             "300"
  set_sshd_option "ClientAliveCountMax"             "2"

  if [[ "$changed" == "false" ]]; then
    SSH_HARDENED=true
    log "SSH already hardened. No changes needed."
    return
  fi

  # Validate config before restarting
  local validation_err
  if validation_err=$(sshd -t -f "$sshd_config" 2>&1); then
    SSH_HARDENED=true
    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
    log "SSH service restarted with new configuration."
  else
    SSH_HARDENED=false
    warn "SSH config validation failed:"
    warn "  $validation_err"
    cp "$backup" "$sshd_config"
    warn "Backup restored — SSH hardening skipped (remaining steps continue)."
  fi
}

# ── Step 8: Install and configure fail2ban ────────────────────────────────────
step_setup_fail2ban() {
  section "Installing and configuring fail2ban"

  pkg_install fail2ban || { warn "fail2ban installation failed. Skipping."; return; }

  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 24h
EOF

  systemctl enable fail2ban
  # reload preserves running state and existing bans; fall back to start if not yet running
  if systemctl is-active fail2ban &>/dev/null; then
    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
  else
    systemctl start fail2ban
  fi
  log "fail2ban configured (SSH: max 3 retries → 24h ban)."
}

# ── Step 9: Automatic security updates ───────────────────────────────────────
step_auto_updates() {
  section "Configuring automatic security updates"

  case "$PKG_MANAGER" in
    apt)
      pkg_install unattended-upgrades apt-listchanges

      cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESMApps:${distro_codename}-apps-security";
  "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

      cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
      # Re-enable timers (stopped earlier by stop_unattended_apt)
      systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
      log "Automatic security updates configured (unattended-upgrades)."
      ;;

    dnf|yum)
      if command -v dnf &>/dev/null; then
        pkg_install dnf-automatic
        sed -i 's/^apply_updates = .*/apply_updates = yes/' /etc/dnf/automatic.conf
        sed -i 's/^upgrade_type = .*/upgrade_type = security/' /etc/dnf/automatic.conf
        systemctl enable --now dnf-automatic.timer
        log "Automatic security updates configured (dnf-automatic)."
      else
        warn "yum-cron setup skipped. Configure manually for RHEL 7."
      fi
      ;;

    pacman)
      warn "Automatic updates on Arch Linux are not configured automatically."
      warn "Consider setting up a pacman hook or systemd timer manually."
      ;;
  esac
}

# ── Step 10: Final summary ────────────────────────────────────────────────────
print_summary() {
  echo
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║          server-init completed successfully          ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "${BOLD}What was done:${NC}"
  echo "  ✔  System packages updated"
  echo "  ✔  Essential tools installed (git, curl, vim, htop, ...)"

  if [[ "${USER_EXISTED:-false}" == "true" ]]; then
    echo "  ✔  Sudo user configured: $NEW_USER (already existed)"
  else
    echo "  ✔  Sudo user created: $NEW_USER"
  fi

  if [[ "${KEYS_EXISTED:-false}" == "true" ]]; then
    echo "  ✔  SSH authorized_keys preserved for $NEW_USER"
  else
    echo "  ✔  SSH authorized_keys copied to $NEW_USER"
  fi

  [[ "$INSTALL_TMUX" == "true" ]] && echo "  ✔  mosh + tmux installed"
  [[ "$INSTALL_CLAUDE_CODE" == "true" ]] && echo "  ✔  Claude Code parallel dev environment deployed"
  echo "  ✔  Swap configured"

  if [[ "${SSH_HARDENED:-false}" == "true" ]]; then
    echo "  ✔  SSH hardened (key-only, no password auth)"
  else
    echo -e "  ${YELLOW}⚠${NC}  SSH hardening skipped (check warnings above)"
  fi

  echo "  ✔  fail2ban configured"
  echo "  ✔  Automatic security updates enabled"
  echo

  # ── Dynamic action items (only show what's actually needed) ──
  local action_num=0 has_header=false
  local caller="${SUDO_USER:-root}"
  local any_pw_missing=false

  # 1) Password checks — both root AND $NEW_USER
  #    VPS console is the ONLY way in if you lose SSH keys. Both accounts need passwords.
  local root_pw user_pw
  root_pw=$(passwd -S root 2>/dev/null | awk '{print $2}' || echo "")
  user_pw=$(passwd -S "$NEW_USER" 2>/dev/null | awk '{print $2}' || echo "")

  if [[ "$root_pw" != "P" && "$root_pw" != "PS" ]] || \
     [[ "$user_pw" != "P" && "$user_pw" != "PS" ]]; then
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠  IMPORTANT: Set console passwords NOW!           ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo
    echo "  SSH password login is disabled. If you lose your SSH key, the VPS"
    echo "  provider's web console is your ONLY way back in. Without a password,"
    echo "  you will be permanently locked out."
    echo
    has_header=true
  fi

  if [[ "$root_pw" != "P" && "$root_pw" != "PS" ]]; then
    (( ++action_num ))
    echo -e "  ${RED}${action_num}.${NC} Set a password for ${BOLD}root${NC}:"
    echo -e "     ${BOLD}sudo passwd root${NC}"
    echo
    any_pw_missing=true
  fi

  if [[ "$user_pw" != "P" && "$user_pw" != "PS" ]]; then
    (( ++action_num ))
    echo -e "  ${RED}${action_num}.${NC} Set a password for ${BOLD}${NEW_USER}${NC}:"
    echo -e "     ${BOLD}sudo passwd $NEW_USER${NC}"
    echo
    any_pw_missing=true
  fi

  # 2) SSH verification — only if caller is not already the target user
  if [[ "$caller" != "$NEW_USER" ]]; then
    if [[ "$has_header" == "false" ]]; then
      echo -e "${BOLD}Next steps:${NC}"
      has_header=true
    fi
    (( ++action_num ))
    echo "  ${action_num}. Open a NEW terminal and verify SSH access as '$NEW_USER':"
    echo "     ssh ${NEW_USER}@<server-ip>"
    echo "     sudo whoami   # should print: root"
    echo
  fi

  if [[ "$has_header" == "false" ]]; then
    echo -e "${GREEN}All done — no further action needed.${NC}"
    echo
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  # Resolve script directory for local config file lookup
  if [[ -f "$0" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  else
    SCRIPT_DIR=""   # running via pipe — will fall back to GitHub raw URL
  fi

  echo
  echo -e "${BOLD}server-init${NC} — starting setup for user: ${CYAN}${NEW_USER}${NC}"
  echo

  detect_os
  step_update_packages
  step_install_essentials
  step_create_user
  step_copy_ssh_keys
  [[ "$INSTALL_TMUX" == "true" ]] && step_install_tmux_mosh
  [[ "$INSTALL_CLAUDE_CODE" == "true" ]] && step_setup_claude_code
  step_setup_swap
  step_harden_ssh
  step_setup_fail2ban
  step_auto_updates
  print_summary
}

main "$@"
