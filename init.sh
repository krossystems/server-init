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

# ── Defaults ──────────────────────────────────────────────────────────────────
NEW_USER="${NEW_USER:-krossys}"
INSTALL_ZELLIJ="${INSTALL_ZELLIJ:-true}"

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
      --no-zellij           Skip zellij installation
  -h, --help                Show this help

${BOLD}Environment variables (alternative to flags):${NC}
  NEW_USER, INSTALL_ZELLIJ

${BOLD}Example:${NC}
  bash init.sh --username john
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--username) NEW_USER="$2";        shift 2 ;;
    --no-zellij)   INSTALL_ZELLIJ=false; shift   ;;
    -h|--help)     usage; exit 0 ;;
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
# apt wrapper: fully non-interactive, waits up to 5 min for the lock
# (DPkg::Lock::Timeout lets apt itself handle lock contention — more
# reliable than external polling because it holds the lock continuously).
# --force-confdef/confold prevents dpkg from stopping on config-file
# conflicts. NEEDRESTART_MODE=a auto-restarts services on Ubuntu 22.04+.
_apt() {
  DEBIAN_FRONTEND=noninteractive \
  NEEDRESTART_MODE=a \
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
      # update has no dpkg interaction, but still needs the lock timeout
      DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
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
step_update_packages() {
  section "Updating package lists and upgrading system"
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

  local user_existed=false
  if id "$NEW_USER" &>/dev/null; then
    warn "User '$NEW_USER' already exists. Skipping creation."
    user_existed=true
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
  if [[ "$user_existed" == "false" ]]; then
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
    log "authorized_keys already exist for '$NEW_USER' — skipping copy to preserve existing keys."
    ssh-keygen -lf "$dest_keys" 2>/dev/null | sed 's/^/  /' || true
    return
  fi

  install -m 600 -o "$NEW_USER" -g "$NEW_USER" "$src_keys" "$dest_keys"
  log "SSH authorized_keys copied to $dest_keys"
}

# ── Step 5: Install zellij ────────────────────────────────────────────────────
step_install_zellij() {
  section "Installing zellij"

  if command -v zellij &>/dev/null; then
    log "zellij already installed: $(zellij --version)"
    return
  fi

  local arch zellij_arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)        zellij_arch="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) zellij_arch="aarch64-unknown-linux-musl" ;;
    armv7l)        zellij_arch="armv7-unknown-linux-musleabihf" ;;
    *)
      warn "Unsupported architecture for zellij: $arch. Skipping."
      return
      ;;
  esac

  local version
  version=$(curl -fsSL "https://api.github.com/repos/zellij-org/zellij/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')

  if [[ -z "$version" ]]; then
    warn "Could not determine latest zellij version. Skipping."
    return
  fi

  local url="https://github.com/zellij-org/zellij/releases/download/${version}/zellij-${zellij_arch}.tar.gz"
  log "Downloading zellij ${version} (${zellij_arch})..."

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  curl -fsSL "$url" | tar -xzf - -C "$tmp"
  install -m 755 "$tmp/zellij" /usr/local/bin/zellij
  log "zellij ${version} installed to /usr/local/bin/zellij"
}

# ── Step 6: Configure swap ────────────────────────────────────────────────────
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
  set_sshd_option "ChallengeResponseAuthentication" "no"
  set_sshd_option "KbdInteractiveAuthentication"    "no"
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
    log "SSH already hardened. No changes needed."
    return
  fi

  # Validate config before restarting
  if sshd -t -f "$sshd_config" 2>/dev/null; then
    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
    log "SSH service restarted with new configuration."
  else
    warn "SSH config validation failed. Restoring backup..."
    cp "$backup" "$sshd_config"
    die "SSH hardening aborted. Original config restored."
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
  echo "  ✔  Sudo user created: $NEW_USER"
  echo "  ✔  SSH authorized_keys copied to $NEW_USER"
  [[ "$INSTALL_ZELLIJ" == "true" ]] && echo "  ✔  zellij installed"
  echo "  ✔  Swap configured"
  echo "  ✔  SSH hardened (key-only, no password auth)"
  echo "  ✔  fail2ban configured"
  echo "  ✔  Automatic security updates enabled"
  echo
  echo -e "${YELLOW}${BOLD}⚠  Required actions:${NC}"
  echo "  1. Set a password for '$NEW_USER' (needed for VPS-console emergency access):"
  echo -e "     ${BOLD}sudo passwd $NEW_USER${NC}"
  echo "     SSH password login remains disabled — this is for console fallback only."
  echo
  echo "  2. Open a NEW terminal and verify SSH access as '$NEW_USER':"
  echo "     ssh ${NEW_USER}@<server-ip>"
  echo "     sudo whoami   # should print: root"
  echo
  echo "  3. Once confirmed, you can close the root session."
  echo
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo
  echo -e "${BOLD}server-init${NC} — starting setup for user: ${CYAN}${NEW_USER}${NC}"
  echo

  detect_os
  step_update_packages
  step_install_essentials
  step_create_user
  step_copy_ssh_keys
  [[ "$INSTALL_ZELLIJ" == "true" ]] && step_install_zellij
  step_setup_swap
  step_harden_ssh
  step_setup_fail2ban
  step_auto_updates
  print_summary
}

main "$@"
