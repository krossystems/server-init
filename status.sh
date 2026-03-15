#!/usr/bin/env bash
# ==============================================================================
# status.sh — Server status and health report
# https://github.com/krossystems/server-init
#
# Usage:
#   bash status.sh          (limited output — no sudo)
#   sudo bash status.sh     (full output — recommended)
# ==============================================================================

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ── Health tracking ───────────────────────────────────────────────────────────
HEALTH_PASS=(); HEALTH_WARN=(); HEALTH_FAIL=()
h_pass() { HEALTH_PASS+=("$*"); }
h_warn() { HEALTH_WARN+=("$*"); }
h_fail() { HEALTH_FAIL+=("$*"); }

# ── Display helpers ───────────────────────────────────────────────────────────
section()   { echo -e "\n${CYAN}${BOLD}── $* ──────────────────────────────────${NC}"; }
kv()        { printf "  ${BOLD}%-28s${NC}%s\n" "$1" "$2"; }
ok()        { echo -e "  ${GREEN}✔${NC}  $*"; }
warn_line() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail_line() { echo -e "  ${RED}✗${NC}  $*"; }
dim_line()  { echo -e "  ${DIM}$*${NC}"; }

# ── Privilege check ───────────────────────────────────────────────────────────
HAS_SUDO=false
if [[ "$EUID" -eq 0 ]] || sudo -n true 2>/dev/null; then HAS_SUDO=true; fi

# Wrapper: run with sudo if available; silently return 1 otherwise
esudo() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@" 2>/dev/null
  elif [[ "$HAS_SUDO" == "true" ]]; then
    sudo -n "$@" 2>/dev/null
  else
    return 1
  fi
}

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"; OS_ID_LIKE="${ID_LIKE:-}"; OS_PRETTY="${PRETTY_NAME:-$ID}"
  else
    OS_ID="unknown"; OS_ID_LIKE=""; OS_PRETTY="Unknown"
  fi
  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop) PKG_MANAGER="apt" ;;
    centos|rhel|rocky|almalinux|fedora|ol)
      PKG_MANAGER=$(command -v dnf &>/dev/null && echo "dnf" || echo "yum") ;;
    arch|manjaro) PKG_MANAGER="pacman" ;;
    *)
      if   echo "$OS_ID_LIKE" | grep -qiE "debian|ubuntu"; then PKG_MANAGER="apt"
      elif echo "$OS_ID_LIKE" | grep -qiE "rhel|centos|fedora"; then PKG_MANAGER="dnf"
      else PKG_MANAGER="unknown"; fi ;;
  esac
}

# ── Uptime human-readable ─────────────────────────────────────────────────────
human_uptime() {
  local s; s=$(awk '{print int($1)}' /proc/uptime)
  local d=$(( s/86400 )) h=$(( s%86400/3600 )) m=$(( s%3600/60 ))
  local r=""; (( d>0 )) && r+="${d}d "; (( h>0 )) && r+="${h}h "; r+="${m}m"
  echo "$r"
}

# ══════════════════════════════════════════════════════════════════════════════
print_header() {
  local host; host=$(hostname)
  echo
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  SERVER STATUS REPORT${NC}"
  printf "  host: ${BOLD}%-20s${NC}  date: %s\n" "$host" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  if [[ "$HAS_SUDO" != "true" ]]; then
    echo -e "\n  ${YELLOW}⚠  Running without sudo — some checks will be limited.${NC}"
    echo -e "  ${YELLOW}   For full output: sudo bash status.sh${NC}"
  fi
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# 1 — SYSTEM
# ══════════════════════════════════════════════════════════════════════════════
check_system() {
  section "SYSTEM"

  local tz ntp virt
  tz=$(timedatectl show --property=Timezone --value 2>/dev/null \
       || cat /etc/timezone 2>/dev/null || date +%Z)
  ntp=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
  virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")

  kv "Hostname:"     "$(hostname)"
  kv "OS:"           "$OS_PRETTY"
  kv "Kernel:"       "$(uname -r) ($(uname -m))"
  kv "Uptime:"       "$(human_uptime)"
  kv "Boot time:"    "$(uptime -s 2>/dev/null || who -b 2>/dev/null | awk '{print $3,$4}' || echo unknown)"
  kv "Timezone:"     "$tz"
  kv "NTP sync:"     "$ntp"
  kv "Virt type:"    "$virt"

  local uptime_s; uptime_s=$(awk '{print int($1)}' /proc/uptime)
  if (( uptime_s < 300 )); then
    warn_line "Rebooted less than 5 minutes ago"
    h_warn "System rebooted < 5 minutes ago (unexpected?)"
  fi
  if [[ "$ntp" == "no" ]]; then
    warn_line "NTP is not synchronized"; h_warn "NTP not synchronized"
  elif [[ "$ntp" == "yes" ]]; then
    h_pass "NTP synchronized"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 2 — HARDWARE
# ══════════════════════════════════════════════════════════════════════════════
check_hardware() {
  section "HARDWARE"

  local cpu_model cpu_cores cpu_threads
  cpu_model=$(grep -m1 "^model name" /proc/cpuinfo | cut -d: -f2 | xargs)
  cpu_threads=$(grep -c "^processor" /proc/cpuinfo)
  cpu_cores=$(grep "^cpu cores" /proc/cpuinfo | tail -1 | awk '{print $NF}' 2>/dev/null || echo "$cpu_threads")

  kv "CPU:" "$cpu_model"
  kv "Cores / threads:" "${cpu_cores} cores / ${cpu_threads} threads"

  # RAM
  local ram_total ram_avail ram_used ram_pct
  ram_total=$(awk '/^MemTotal/{print $2}'     /proc/meminfo)
  ram_avail=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
  ram_used=$(( ram_total - ram_avail ))
  ram_pct=$(( ram_used * 100 / ram_total ))

  local ram_total_mb=$(( ram_total / 1024 ))
  local ram_used_mb=$(( ram_used / 1024 ))
  kv "RAM:" "${ram_total_mb} MB total  |  ${ram_used_mb} MB used  (${ram_pct}%)"

  if   (( ram_pct >= 90 )); then fail_line "RAM critical at ${ram_pct}%"; h_fail "RAM usage critical (${ram_pct}%)"
  elif (( ram_pct >= 75 )); then warn_line "RAM high at ${ram_pct}%";    h_warn "RAM usage high (${ram_pct}%)"
  else                           h_pass "RAM usage normal (${ram_pct}%)"
  fi

  # Swap
  local swap_total swap_free swap_used swap_pct
  swap_total=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
  swap_free=$(awk '/^SwapFree/{print $2}'   /proc/meminfo)
  swap_used=$(( swap_total - swap_free ))

  if (( swap_total == 0 )); then
    kv "Swap:" "none"
    if (( ram_total < 4194304 )); then
      warn_line "No swap and RAM < 4 GB"; h_warn "No swap configured (RAM < 4 GB)"
    fi
  else
    swap_pct=$(( swap_used * 100 / swap_total ))
    kv "Swap:" "$(( swap_total/1024 )) MB total  |  $(( swap_used/1024 )) MB used  (${swap_pct}%)"
    if (( swap_pct >= 50 )); then warn_line "Swap usage high (${swap_pct}%)"; h_warn "Swap usage high (${swap_pct}%)"; fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 3 — STORAGE
# ══════════════════════════════════════════════════════════════════════════════
check_storage() {
  section "STORAGE"

  echo
  df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null \
    | awk '{printf "  %s\n", $0}'

  # Disk usage health checks (using numeric df)
  while read -r _ _ _ _ pct_raw _ mount _; do
    local pct="${pct_raw//%/}"
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    if   (( pct >= 90 )); then fail_line "Disk $mount at ${pct}%"; h_fail "Disk $mount is ${pct}% full"
    elif (( pct >= 80 )); then warn_line "Disk $mount at ${pct}%"; h_warn "Disk $mount is ${pct}% full"
    fi
  done < <(df -T -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

  # Inode health checks
  while read -r _ _ _ _ pct_raw mount; do
    local pct="${pct_raw//%/}"
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    if   (( pct >= 90 )); then fail_line "Inodes $mount at ${pct}%"; h_fail "Inode exhaustion on $mount (${pct}%)"
    elif (( pct >= 80 )); then warn_line "Inodes $mount at ${pct}%"; h_warn "High inode usage on $mount (${pct}%)"
    fi
  done < <(df -i -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

  # Swap devices
  local swap_info; swap_info=$(swapon --show=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null || true)
  if [[ -n "$swap_info" ]]; then
    echo
    dim_line "Swap:"
    echo "$swap_info" | awk '{printf "  %s\n", $0}'
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 4 — NETWORK
# ══════════════════════════════════════════════════════════════════════════════
check_network() {
  section "NETWORK"

  # Public IP
  local pub4
  pub4=$(curl -fsSL --max-time 4 https://api.ipify.org 2>/dev/null \
      || curl -4 -fsSL --max-time 4 https://ifconfig.me 2>/dev/null \
      || echo "(unavailable)")
  kv "Public IPv4:" "$pub4"

  if [[ "$pub4" == "(unavailable)" ]]; then
    fail_line "Cannot reach internet"; h_fail "No internet connectivity"
  else
    h_pass "Internet connectivity OK ($pub4)"
  fi

  # Interfaces
  echo
  dim_line "Interfaces:"
  ip -brief addr show 2>/dev/null | awk '{printf "  %-14s %-14s %s\n",$1,$2,$3}' \
    || ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | sed 's/^/  /'

  # Gateway and DNS
  local gw dns dns_test
  gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}' || echo "unknown")
  dns=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | xargs || echo "none")
  kv "Default gateway:" "$gw"
  kv "DNS servers:" "$dns"

  # DNS test
  dns_test=$(dig +short +time=3 google.com A 2>/dev/null | head -1 \
    || host -W3 google.com 2>/dev/null | awk '/has address/{print $4; exit}' \
    || getent hosts google.com 2>/dev/null | awk '{print $1; exit}' || echo "")
  if [[ -n "$dns_test" ]]; then
    kv "DNS test:" "OK (google.com → $dns_test)"; h_pass "DNS resolution working"
  else
    kv "DNS test:" "FAILED"; fail_line "DNS resolution failed"; h_fail "DNS resolution failed"
  fi

  # Listening ports
  echo
  dim_line "Listening ports (TCP/UDP):"
  if [[ "$HAS_SUDO" == "true" ]]; then
    esudo ss -tlnpu 2>/dev/null \
      | awk 'NR>1{
          split($5,a,":");port=a[length(a)];
          match($7,/\(\("([^"]+)/,m);proc=m[1]?m[1]:"?"
          printf "  %-6s %-25s %s\n",$1,$5,proc
        }' \
      || esudo ss -tlnp | awk 'NR>1{printf "  %-6s %s\n",$1,$5}'
  else
    ss -tlnp 2>/dev/null | awk 'NR>1{printf "  %-6s %s\n",$1,$5}'
    dim_line "(sudo needed for process names)"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 5 — SECURITY
# ══════════════════════════════════════════════════════════════════════════════
check_security() {
  section "SECURITY"

  # 5a — SSH config via sshd -T (effective merged config)
  echo -e "\n  ${BOLD}SSH Configuration${NC}"

  local sshd_t=""
  sshd_t=$(esudo sshd -T 2>/dev/null || true)

  get_ssh() {
    local key="$1" default="${2:-?}"
    local val=""
    [[ -n "$sshd_t" ]] && val=$(echo "$sshd_t" | awk -v k="${key,,}" 'tolower($1)==k{print $2; exit}')
    [[ -z "$val" ]] && val=$(grep -iE "^\s*${key}\s" /etc/ssh/sshd_config 2>/dev/null \
                              | tail -1 | awk '{print $2}')
    echo "${val:-$default}"
  }

  local pw_auth pubkey root_login empty_pw max_tries grace x11 port
  pw_auth=$(get_ssh "passwordauthentication" "?")
  pubkey=$(get_ssh  "pubkeyauthentication"   "?")
  root_login=$(get_ssh "permitrootlogin"     "?")
  empty_pw=$(get_ssh  "permitemptypasswords"  "?")
  max_tries=$(get_ssh "maxauthtries"          "?")
  grace=$(get_ssh     "logingracetime"        "?")
  x11=$(get_ssh       "x11forwarding"         "?")
  port=$(get_ssh      "port"                  "22")

  # Colored value printer: green if matches expected, red if matches bad, else default
  cv() {
    local val="$1" good="${2:-}" bad="${3:-}"
    if   [[ -n "$good" && "$val" == "$good" ]]; then echo -e "${GREEN}${val}${NC}"
    elif [[ -n "$bad"  && "$val" == "$bad"  ]]; then echo -e "${RED}${val}${NC}"
    else echo "$val"; fi
  }

  printf "  ${BOLD}%-30s${NC}%s\n" "PasswordAuthentication:" "$(cv "$pw_auth" "no" "yes")"
  printf "  ${BOLD}%-30s${NC}%s\n" "PubkeyAuthentication:"   "$(cv "$pubkey" "yes" "no")"
  printf "  ${BOLD}%-30s${NC}%s\n" "PermitRootLogin:"        "$root_login"
  printf "  ${BOLD}%-30s${NC}%s\n" "PermitEmptyPasswords:"   "$(cv "$empty_pw" "no" "yes")"
  printf "  ${BOLD}%-30s${NC}%s\n" "MaxAuthTries:"           "$max_tries"
  printf "  ${BOLD}%-30s${NC}%s\n" "LoginGraceTime:"         "$grace"
  printf "  ${BOLD}%-30s${NC}%s\n" "X11Forwarding:"          "$(cv "$x11" "no" "yes")"
  printf "  ${BOLD}%-30s${NC}%s\n" "Port:"                   "$port"

  [[ "$pw_auth"   == "yes" ]] && { fail_line "Password auth enabled!"; h_fail "SSH: PasswordAuthentication=yes"; } \
                               || { [[ "$pw_auth" == "no" ]] && h_pass "SSH: key-only auth"; }
  [[ "$empty_pw"  == "yes" ]] && { fail_line "Empty passwords allowed!"; h_fail "SSH: PermitEmptyPasswords=yes"; }
  [[ "$x11"       == "yes" ]] && { warn_line "X11 forwarding enabled"; h_warn "SSH: X11Forwarding=yes"; }
  [[ "$max_tries" =~ ^[0-9]+$ && "$max_tries" -gt 4 ]] \
    && { warn_line "MaxAuthTries=$max_tries (recommend ≤4)"; h_warn "SSH: MaxAuthTries=$max_tries"; }

  # 5b — Authorized keys
  echo -e "\n  ${BOLD}Authorized Keys${NC}"
  local current_user_home
  current_user_home=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6 2>/dev/null || echo "$HOME")
  local auth_keys="${current_user_home}/.ssh/authorized_keys"

  if [[ -f "$auth_keys" && -s "$auth_keys" ]]; then
    local key_count
    key_count=$(grep -cE "^(ssh-|ecdsa-|sk-)" "$auth_keys" 2>/dev/null || wc -l < "$auth_keys")
    kv "Keys (${SUDO_USER:-$USER}):" "$key_count key(s)"
    ssh-keygen -lf "$auth_keys" 2>/dev/null | awk '{printf "  %s\n", $0}' || true
    h_pass "Authorized keys present ($key_count)"
  else
    warn_line "No authorized_keys for ${SUDO_USER:-$USER}!"; h_warn "No authorized_keys found"
  fi

  # Root authorized keys (informational)
  if [[ "$HAS_SUDO" == "true" ]]; then
    local root_keys_count
    root_keys_count=$(esudo wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo 0)
    (( root_keys_count > 0 )) && kv "Keys (root):" "$root_keys_count key(s)"
  fi

  # 5c — fail2ban
  echo -e "\n  ${BOLD}fail2ban${NC}"
  local f2b_active
  f2b_active=$(esudo systemctl is-active fail2ban 2>/dev/null || echo "inactive")
  kv "Status:" "$f2b_active"

  if [[ "$f2b_active" == "active" ]]; then
    h_pass "fail2ban active"
    local jail_output
    jail_output=$(esudo fail2ban-client status sshd 2>/dev/null || true)
    if [[ -n "$jail_output" ]]; then
      local currently_banned total_banned
      currently_banned=$(echo "$jail_output" | grep "Banned IP list:" | sed 's/.*Banned IP list://' | tr -s ' ' '\n' | grep -cE "[0-9]" || echo 0)
      total_banned=$(echo "$jail_output" | awk '/Total banned:/{print $NF}')
      kv "SSH jail:" "currently banned: ${currently_banned}  |  total bans: ${total_banned:-?}"
      (( currently_banned > 0 )) && { warn_line "Active banned IPs: $currently_banned"; h_warn "fail2ban: $currently_banned IPs currently banned"; }
    else
      warn_line "sshd jail not found"; h_warn "fail2ban: sshd jail not configured"
    fi
  else
    fail_line "fail2ban is NOT running"; h_fail "fail2ban not active"
  fi

  # 5d — Recent auth events
  echo -e "\n  ${BOLD}Authentication Events (last 24h)${NC}"
  local failed_count=0
  if [[ "$HAS_SUDO" == "true" ]]; then
    failed_count=$(
      esudo journalctl -u ssh -u sshd --since "24 hours ago" 2>/dev/null \
        | grep -cE "Failed password|Invalid user|authentication failure" \
      || esudo grep -cE "Failed|Invalid|authentication failure" /var/log/auth.log 2>/dev/null \
      || esudo grep -cE "Failed|Invalid" /var/log/secure 2>/dev/null \
      || echo 0
    )
  fi
  kv "Failed SSH attempts:" "${failed_count} (last 24h)"

  if   (( failed_count > 500 )); then fail_line "Very high failed attempts: $failed_count (active brute force?)"; h_fail "SSH: $failed_count failed attempts in 24h"
  elif (( failed_count > 100 )); then warn_line "Elevated failed attempts: $failed_count"; h_warn "SSH: $failed_count failed attempts in 24h"
  else                                h_pass "Auth attempts normal ($failed_count failed in 24h)"
  fi

  # Top attacking IPs
  if [[ "$HAS_SUDO" == "true" && "$failed_count" -gt 5 ]]; then
    dim_line "Top source IPs (failed auth):"
    esudo journalctl -u ssh -u sshd --since "24 hours ago" 2>/dev/null \
      | grep -oE "from [0-9]{1,3}(\.[0-9]{1,3}){3}" | awk '{print $2}' \
      | sort | uniq -c | sort -rn | head -5 \
      | awk '{printf "  %6d × %s\n", $1, $2}' || true
  fi

  # Last logins
  echo
  dim_line "Last 5 logins:"
  last -n 5 -w 2>/dev/null | head -5 | awk '{printf "  %s\n", $0}' || dim_line "(unavailable)"
}

# ══════════════════════════════════════════════════════════════════════════════
# 6 — SERVICES
# ══════════════════════════════════════════════════════════════════════════════
check_services() {
  section "SERVICES"

  # Print a service row; returns 0 if active
  svc_row() {
    local unit="$1" label="${2:-$1}"
    local status; status=$(systemctl is-active "$unit" 2>/dev/null || echo "not-found")
    local color
    case "$status" in
      active)   color="$GREEN" ;;
      inactive) color="$YELLOW" ;;
      *)        color="$RED" ;;
    esac
    printf "  ${BOLD}%-32s${NC}${color}%s${NC}\n" "$label" "$status"
    [[ "$status" == "active" ]]
  }

  # sshd (name differs by distro)
  local sshd_up=false
  svc_row "sshd" "sshd" && sshd_up=true || svc_row "ssh" "sshd (ssh)" && sshd_up=true || true
  $sshd_up && h_pass "sshd running" || h_fail "sshd is NOT running"

  svc_row "fail2ban"  "fail2ban"  || true   # already tracked in §5

  case "$PKG_MANAGER" in
    apt)
      if svc_row "unattended-upgrades" "unattended-upgrades"; then
        h_pass "Automatic security updates active"
      else
        warn_line "unattended-upgrades not running"; h_warn "Auto security updates not active"
      fi ;;
    dnf)
      if svc_row "dnf-automatic.timer" "dnf-automatic.timer"; then
        h_pass "Automatic security updates active"
      else
        warn_line "dnf-automatic.timer not active"; h_warn "Auto security updates not active"
      fi ;;
  esac

  # Docker (if present)
  if command -v docker &>/dev/null; then
    svc_row "docker" "docker" || true
    local containers; containers=$(docker ps --format "{{.Names}} — {{.Status}}" 2>/dev/null || echo "")
    if [[ -n "$containers" ]]; then
      dim_line "Running containers:"
      echo "$containers" | awk '{printf "  %s\n", $0}'
    else
      dim_line "  No running containers"
    fi
  fi

  # Failed units
  echo
  local failed_units
  failed_units=$(esudo systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null | grep -v "^$" || true)
  if [[ -n "$failed_units" ]]; then
    fail_line "Failed systemd units:"
    echo "$failed_units" | head -10 | awk '{printf "  %-38s %s\n", $1, $4}'
    local n; n=$(echo "$failed_units" | grep -c "." || echo "?")
    h_fail "$n systemd unit(s) in failed state"
  else
    ok "No failed systemd units"; h_pass "No failed systemd units"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 7 — PERFORMANCE
# ══════════════════════════════════════════════════════════════════════════════
check_performance() {
  section "PERFORMANCE"

  local cpu_count load_1 load_5 load_15
  cpu_count=$(nproc)
  read -r load_1 load_5 load_15 _ < /proc/loadavg

  local load_pct
  load_pct=$(awk "BEGIN{printf \"%.0f\", $load_1 / $cpu_count * 100}")

  kv "CPUs:"      "$cpu_count"
  kv "Load avg:"  "${load_1} / ${load_5} / ${load_15}  (1m / 5m / 15m)"
  kv "Load (1m):" "${load_pct}% of capacity"

  if   (( load_pct >= 200 )); then fail_line "Load critical (${load_1} on ${cpu_count} CPU)"; h_fail "Load critical: ${load_1} (${load_pct}%)"
  elif (( load_pct >= 100 )); then warn_line "Load high (${load_1} on ${cpu_count} CPU)";     h_warn "Load high: ${load_1} (${load_pct}%)"
  else                              h_pass "Load normal: ${load_1} (${load_pct}%)"
  fi

  # Memory available (quick look)
  local mem_avail_pct
  mem_avail_pct=$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%.0f", a/t*100}' /proc/meminfo)
  kv "Memory avail:" "${mem_avail_pct}% free"

  # Top 5 by CPU
  echo
  dim_line "Top 5 by CPU:"
  ps axo user:12,pid,pcpu,pmem,comm --sort=-%cpu 2>/dev/null | head -6 | awk '{printf "  %s\n", $0}'

  echo
  dim_line "Top 5 by memory:"
  ps axo user:12,pid,pcpu,pmem,comm --sort=-%mem 2>/dev/null | head -6 | awk '{printf "  %s\n", $0}'

  # OOM events
  local oom=0
  oom=$(esudo journalctl -k --since boot 2>/dev/null \
    | grep -cE "oom_kill_process|Out of memory" || echo 0)
  kv "OOM events:" "$oom since last boot"
  (( oom > 0 )) && { warn_line "OOM killer has fired $oom time(s) since boot"; h_warn "OOM: $oom kill event(s) since boot"; }

  # I/O wait (optional, if sysstat installed)
  if command -v iostat &>/dev/null; then
    local iowait; iowait=$(iostat -c 1 1 2>/dev/null | awk 'NR==4{print $4}')
    [[ -n "$iowait" ]] && kv "I/O wait:" "${iowait}%"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 8 — UPDATES
# ══════════════════════════════════════════════════════════════════════════════
check_updates() {
  section "UPDATES"

  case "$PKG_MANAGER" in
    apt)
      dim_line "Checking cached package index (no network call)..."
      local total sec
      total=$(apt-get -q --dry-run upgrade 2>/dev/null | grep -c "^Inst" || echo 0)
      sec=$(apt-get   -q --dry-run upgrade 2>/dev/null | grep "^Inst" | grep -ci security || echo 0)
      kv "Pending updates:"    "$total total  |  $sec security"

      if   (( sec   > 0  )); then fail_line "$sec security update(s) pending!"; h_fail "$sec pending security updates"
      else                        h_pass "No pending security updates"
      fi
      (( total > 20 )) && { warn_line "$total total updates pending"; h_warn "$total total package updates pending"; }

      # Reboot required
      if [[ -f /var/run/reboot-required ]]; then
        warn_line "System reboot is required!"; h_warn "Reboot required"
        [[ -f /var/run/reboot-required.pkgs ]] \
          && dim_line "Packages: $(tr '\n' ',' < /var/run/reboot-required.pkgs | sed 's/,$//')"
      else
        ok "No reboot required"; h_pass "No reboot required"
      fi

      # Last upgrade timestamp
      local last_up
      last_up=$(stat -c '%y' /var/lib/apt/periodic/upgrade-stamp 2>/dev/null | cut -d. -f1 \
             || stat -c '%y' /var/lib/dpkg/lock 2>/dev/null | cut -d. -f1 \
             || echo "unknown")
      kv "Last upgrade:" "$last_up"
      ;;

    dnf|yum)
      dim_line "Checking for security updates..."
      local sec total
      sec=$(esudo "$PKG_MANAGER" check-update --security -q 2>/dev/null \
            | grep -cE "^\S+\.(x86_64|aarch64|noarch|i686)" || echo 0)
      total=$(esudo "$PKG_MANAGER" check-update -q 2>/dev/null \
              | grep -cE "^\S+\.(x86_64|aarch64|noarch|i686)" || echo 0)
      kv "Pending updates:" "$total total  |  $sec security"
      (( sec > 0 )) && { fail_line "$sec security update(s) pending!"; h_fail "$sec pending security updates"; } \
                     || h_pass "No pending security updates"
      ;;

    *)
      dim_line "Update check not implemented for: $PKG_MANAGER"
      ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════════════
# 9 — KERNEL TUNING
# ══════════════════════════════════════════════════════════════════════════════
check_kernel() {
  section "KERNEL TUNING"

  get_sysctl() { cat "/proc/sys/${1//\./\/}" 2>/dev/null || echo "N/A"; }

  local swappiness vfs_cache tcp_sync ip_fwd dmesg_r dirty_r
  swappiness=$(get_sysctl "vm.swappiness")
  vfs_cache=$(get_sysctl  "vm.vfs_cache_pressure")
  dirty_r=$(get_sysctl    "vm.dirty_ratio")
  tcp_sync=$(get_sysctl   "net.ipv4.tcp_syncookies")
  ip_fwd=$(get_sysctl     "net.ipv4.ip_forward")
  dmesg_r=$(get_sysctl    "kernel.dmesg_restrict")

  kv "vm.swappiness:"            "$swappiness"
  kv "vm.vfs_cache_pressure:"    "$vfs_cache"
  kv "vm.dirty_ratio:"           "$dirty_r"
  kv "net.ipv4.tcp_syncookies:"  "$tcp_sync"
  kv "net.ipv4.ip_forward:"      "$ip_fwd"
  kv "kernel.dmesg_restrict:"    "$dmesg_r"

  local fd_info; fd_info=$(awk '{print $1 " used / " $3 " max"}' /proc/sys/fs/file-nr 2>/dev/null || echo "N/A")
  kv "Open file descriptors:" "$fd_info"

  # Health checks
  [[ "$swappiness" =~ ^[0-9]+$ ]] && (( swappiness > 30 )) \
    && { warn_line "vm.swappiness=$swappiness (recommend ≤10 for servers)"; h_warn "Kernel: vm.swappiness=$swappiness too high"; }
  [[ "$tcp_sync" == "0" ]] \
    && { warn_line "tcp_syncookies=0 (SYN flood protection off)"; h_warn "Kernel: tcp_syncookies disabled"; }
  [[ "$ip_fwd" == "1" ]] \
    && dim_line "ip_forward=1 (expected if Docker/VPN/routing is active)"

  # Active sysctl drop-ins
  echo
  dim_line "Active sysctl drop-in files:"
  ls /etc/sysctl.d/ 2>/dev/null | grep -v "^$" | awk '{printf "  %s\n", $0}' || dim_line "(none or not accessible)"

  # Recent kernel errors
  echo
  dim_line "Kernel errors in last hour:"
  local kerr=""
  kerr=$(esudo dmesg --level=err,crit,alert,emerg --since "1 hour ago" 2>/dev/null \
      || esudo dmesg -T 2>/dev/null | grep -iE "error|fail|crit" | tail -5 \
      || true)
  if [[ -n "$kerr" ]]; then
    echo "$kerr" | tail -5 | awk '{printf "  %s\n", $0}'
    fail_line "Kernel errors in dmesg (last hour)"; h_fail "Kernel errors detected"
  else
    ok "No kernel errors in dmesg (last hour)"; h_pass "No recent kernel errors"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 10 — SCHEDULED TASKS
# ══════════════════════════════════════════════════════════════════════════════
check_scheduled() {
  section "SCHEDULED TASKS"

  # User crontab
  local current_user="${SUDO_USER:-$USER}"
  dim_line "Crontab ($current_user):"
  local cron_out; cron_out=$(crontab -u "$current_user" -l 2>/dev/null || crontab -l 2>/dev/null || echo "(none)")
  echo "$cron_out" | grep -vE "^#|^$" | awk '{printf "  %s\n", $0}' \
    || echo -e "  ${DIM}(none)${NC}"

  # Root crontab
  if [[ "$HAS_SUDO" == "true" ]]; then
    local root_cron; root_cron=$(esudo crontab -u root -l 2>/dev/null || echo "(none)")
    dim_line "Crontab (root):"
    echo "$root_cron" | grep -vE "^#|^$" | awk '{printf "  %s\n", $0}' \
      || echo -e "  ${DIM}(none)${NC}"
  fi

  # /etc/cron.d
  echo
  dim_line "/etc/cron.d entries:"
  ls /etc/cron.d/ 2>/dev/null | grep -v "^$" | awk '{printf "  %s\n", $0}' || dim_line "(empty or not accessible)"

  # Systemd timers (upcoming)
  echo
  dim_line "Next systemd timers:"
  systemctl list-timers --no-pager 2>/dev/null \
    | head -9 | awk 'NR>1{printf "  %s\n", $0}' \
    || dim_line "(systemctl not available)"
}

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
print_summary() {
  echo
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║              SERVER HEALTH SUMMARY                  ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo

  local item
  for item in "${HEALTH_FAIL[@]+"${HEALTH_FAIL[@]}"}"; do
    echo -e "  ${RED}[FAIL]${NC}  $item"
  done
  for item in "${HEALTH_WARN[@]+"${HEALTH_WARN[@]}"}"; do
    echo -e "  ${YELLOW}[WARN]${NC}  $item"
  done
  for item in "${HEALTH_PASS[@]+"${HEALTH_PASS[@]}"}"; do
    echo -e "  ${GREEN}[PASS]${NC}  $item"
  done

  local np=${#HEALTH_PASS[@]} nw=${#HEALTH_WARN[@]} nf=${#HEALTH_FAIL[@]}
  local total=$(( np + nw + nf ))
  echo
  echo -e "  ${BOLD}Checks:${NC}  ${GREEN}${np} PASS${NC}  /  ${YELLOW}${nw} WARN${NC}  /  ${RED}${nf} FAIL${NC}  (${total} total)"
  echo

  # Exit code convention: 0=all clear, 1=warnings, 2=failures
  (( nf > 0 )) && return 2
  (( nw > 0 )) && return 1
  return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  detect_os
  print_header
  check_system
  check_hardware
  check_storage
  check_network
  check_security
  check_services
  check_performance
  check_updates
  check_kernel
  check_scheduled
  print_summary
}

main "$@"
