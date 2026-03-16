#!/usr/bin/env bash
# ==============================================================================
# mac-setup.sh — Configure a Mac as a client for Mosh + Tmux remote development
#
# What it does:
#   1. Installs mosh and JetBrains Mono font via Homebrew
#   2. Deploys Ghostty terminal configuration
#   3. Creates ~/.ssh/sockets/ directory for ControlMaster
#
# Usage (either way works):
#   curl -fsSL https://raw.githubusercontent.com/krossystems/server-init/main/client/mac-setup.sh | bash
#   bash mac-setup.sh          # from a local clone
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}── $* ──────────────────────────────────${NC}"; }
die()     { error "$*"; exit 1; }

# GitHub raw base URL (used when running via curl | bash)
GITHUB_RAW="https://raw.githubusercontent.com/krossystems/server-init/main"

# Resolve script directory for local file lookup
if [[ -f "$0" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
  SCRIPT_DIR=""
fi

# Fetch a file from local clone or GitHub
get_file() {
  local relpath="$1"
  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/${relpath}" ]]; then
    cat "${SCRIPT_DIR}/${relpath}"
  else
    curl -fsSL "${GITHUB_RAW}/client/${relpath}"
  fi
}

echo
echo -e "${BOLD}mac-setup${NC} — Configuring this Mac for remote development"
echo

# ── Homebrew check ───────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  die "Homebrew not found. Install it first: https://brew.sh"
fi

# ── Step 1: Install mosh and font ───────────────────────────────────────────
section "Installing mosh and JetBrains Mono font"

if command -v mosh &>/dev/null; then
  log "mosh already installed."
else
  brew install mosh
  log "mosh installed."
fi

if brew list --cask font-jetbrains-mono &>/dev/null 2>&1; then
  log "JetBrains Mono font already installed."
else
  brew install --cask font-jetbrains-mono
  log "JetBrains Mono font installed."
fi

# ── Step 2: Deploy Ghostty config ───────────────────────────────────────────
section "Deploying Ghostty configuration"

dest_dir="$HOME/.config/ghostty"
dest_file="${dest_dir}/config"

mkdir -p "$dest_dir"

if [[ -f "$dest_file" ]]; then
  backup="${dest_file}.backup.$(date +%Y%m%d%H%M%S)"
  cp "$dest_file" "$backup"
  warn "Existing Ghostty config backed up to: $backup"
fi

get_file "ghostty-config" > "$dest_file"
log "Ghostty config deployed to $dest_file"

# ── Step 3: SSH sockets directory ────────────────────────────────────────────
section "Setting up SSH"

mkdir -p "$HOME/.ssh/sockets"
chmod 700 "$HOME/.ssh" "$HOME/.ssh/sockets" 2>/dev/null || true
log "Created ~/.ssh/sockets/ for ControlMaster."

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║            Mac setup completed successfully          ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${BOLD}What was done:${NC}"
echo "  ✔  mosh installed"
echo "  ✔  JetBrains Mono font installed"
echo "  ✔  Ghostty config deployed to ~/.config/ghostty/config"
echo "  ✔  SSH sockets directory created at ~/.ssh/sockets/"
echo
echo -e "${BOLD}Connect to a server:${NC}"
echo -e "  ${BOLD}mosh myhost -- tmux new-session -A -s main${NC}"
echo
echo "  If using Ghostty, restart it to apply the new config."
echo
