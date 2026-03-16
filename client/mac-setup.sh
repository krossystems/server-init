#!/usr/bin/env bash
# ==============================================================================
# mac-setup.sh — Configure a Mac as a client for the remote dev server
#
# What it does:
#   1. Installs mosh and JetBrains Mono font via Homebrew
#   2. Deploys Ghostty terminal configuration
#   3. Creates ~/.ssh/sockets/ directory
#   4. Generates an Ed25519 SSH key (if none exists)
#   5. Creates ~/bin/dev quick-connect command
#   6. Prints next steps (SSH config, ssh-copy-id)
#
# Usage:
#   bash mac-setup.sh
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}── $* ──────────────────────────────────${NC}"; }
die()     { error "$*"; exit 1; }

# Resolve script directory for config file lookup
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

local_config="${SCRIPT_DIR}/ghostty-config"
dest_dir="$HOME/.config/ghostty"
dest_file="${dest_dir}/config"

if [[ ! -f "$local_config" ]]; then
  die "ghostty-config not found at $local_config. Run this script from the client/ directory."
fi

mkdir -p "$dest_dir"

if [[ -f "$dest_file" ]]; then
  backup="${dest_file}.backup.$(date +%Y%m%d%H%M%S)"
  cp "$dest_file" "$backup"
  warn "Existing Ghostty config backed up to: $backup"
fi

cp "$local_config" "$dest_file"
log "Ghostty config deployed to $dest_file"

# ── Step 3: SSH sockets directory ────────────────────────────────────────────
section "Setting up SSH"

mkdir -p "$HOME/.ssh/sockets"
chmod 700 "$HOME/.ssh" "$HOME/.ssh/sockets" 2>/dev/null || true
log "Created ~/.ssh/sockets/ for ControlMaster."

# ── Step 4: Generate SSH key ────────────────────────────────────────────────
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  log "Generating Ed25519 SSH key..."
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "$(whoami)@$(hostname)"
  log "SSH key generated: ~/.ssh/id_ed25519"
else
  log "Ed25519 SSH key already exists."
fi

# ── Step 5: Create ~/bin/dev quick-connect command ───────────────────────────
section "Creating ~/bin/dev command"

mkdir -p "$HOME/bin"
cat > "$HOME/bin/dev" <<'DEVEOF'
#!/usr/bin/env bash
# Quick connect to dev server via Mosh, auto-attach to Tmux "main" session.
#
# Usage:
#   dev              → connect to default host "dev" (from ~/.ssh/config)
#   dev myserver     → connect to "myserver"

set -euo pipefail

host="${1:-dev}"

# Mosh into the server, then attach or create the "main" Tmux session.
# tmux new -A -s main: attach if exists, otherwise create.
mosh "$host" -- tmux new-session -A -s main
DEVEOF

chmod +x "$HOME/bin/dev"
log "Created ~/bin/dev"

# Check if ~/bin is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/bin"; then
  warn "~/bin is not in your PATH. Add this to your shell profile:"
  warn "  export PATH=\"\$HOME/bin:\$PATH\""
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║            Mac setup completed successfully          ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${BOLD}What was done:${NC}"
echo "  ✔  mosh installed"
echo "  ✔  JetBrains Mono font installed"
echo "  ✔  Ghostty config deployed"
echo "  ✔  SSH sockets directory created"
echo "  ✔  SSH key ready"
echo "  ✔  ~/bin/dev quick-connect command created"
echo
echo -e "${YELLOW}${BOLD}Next steps:${NC}"
echo
echo "  1. Add the SSH config snippet to ~/.ssh/config:"
echo -e "     ${BOLD}cat ${SCRIPT_DIR}/ssh-config-snippet >> ~/.ssh/config${NC}"
echo "     Then edit it to set YOUR_SERVER_IP and YOUR_USERNAME."
echo
echo "  2. Copy your SSH key to the server:"
echo -e "     ${BOLD}ssh-copy-id -i ~/.ssh/id_ed25519.pub YOUR_USERNAME@YOUR_SERVER_IP${NC}"
echo
echo "  3. Connect:"
echo -e "     ${BOLD}dev${NC}"
echo
echo "  4. If using Ghostty, restart it to apply the new config."
echo
