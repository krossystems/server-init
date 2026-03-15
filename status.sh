#!/usr/bin/env bash
# ==============================================================================
# status.sh — Server status and health report
# https://github.com/krossystems/server-init
# ==============================================================================

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN='\033[0;32m';  YELLOW='\033[1;33m'; RED='\033[0;31m'
  CYAN='\033[0;36m';   BOLD='\033[1m';      DIM='\033[2m';    NC='\033[0m'
  BG='\033[1;32m';     BY='\033[1;33m';     BR='\033[1;31m';  BC='\033[1;36m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; DIM=''; NC=''
  BG='';    BY='';     BR='';  BC=''
fi

# ── Health tracking ───────────────────────────────────────────────────────────
HEALTH_PASS=(); HEALTH_WARN=(); HEALTH_FAIL=()
h_pass() { HEALTH_PASS+=("$*"); }
h_warn() { HEALTH_WARN+=("$*"); }
h_fail() { HEALTH_FAIL+=("$*"); }

# ── Visual primitives ─────────────────────────────────────────────────────────
W=64  # inner width of the report

# Section header
section() {
  local title=" $1 " tlen=$(( ${#1} + 2 )) i
  printf "\n${BC}${BOLD}%s${NC}${DIM}" "$title"
  for (( i=0; i < W - tlen; i++ )); do printf '─'; done
  printf "${NC}\n"
}

# Progress bar — bar PCT [WIDTH=22]
bar() {
  local pct=$1 w=${2:-22} i
  (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  local f=$(( pct * w / 100 )) e=$(( w - pct * w / 100 ))
  local c; (( pct >= 90 )) && c="$BR" || { (( pct >= 75 )) && c="$BY" || c="$BG"; }
  printf "${c}"; for (( i=0; i<f; i++ )); do printf '█'; done
  printf "${NC}${DIM}"; for (( i=0; i<e; i++ )); do printf '░'; done
  printf "${NC}"
}

# pct_color PCT — inline colored percentage
pct_color() {
  local pct=$1 c
  (( pct >= 90 )) && c="$BR" || { (( pct >= 75 )) && c="$BY" || c="$BG"; }
  printf "${c}%3d%%${NC}" "$pct"
}

# Metric row: metric "LABEL" PCT "detail"
metric() {
  local label="$1" pct="$2" detail="$3"
  printf "  ${BOLD}%-7s${NC} "; bar "$pct"; printf "  "; pct_color "$pct"
  printf "  ${DIM}%s${NC}\n" "$detail"
}

# kv — single-column key/value
kv()  { printf "  ${DIM}%-22s${NC}%s\n" "$1" "$2"; }

# kv2 — two-column key/value
kv2() { printf "  ${DIM}%-14s${NC}%-22s  ${DIM}%-14s${NC}%s\n" "$1" "$2" "$3" "$4"; }

# Status dot for services
dot() {
  case "$1" in
    active)   printf "${BG}●${NC}" ;;
    inactive) printf "${YELLOW}●${NC}" ;;
    failed)   printf "${BR}●${NC}" ;;
    *)        printf "${DIM}●${NC}" ;;
  esac
}

# Check mark: chk VAL GOOD_VAL — green ✔ or red ✗
chk() { [[ "$1" == "$2" ]] && printf "${BG}✔${NC}" || printf "${BR}✗${NC}"; }

# Colorize value: cv VAL [GOOD] [BAD]
cv() {
  local v="$1" g="${2:-}" b="${3:-}"
  if   [[ -n "$g" && "$v" == "$g" ]]; then printf "${BG}%s${NC}" "$v"
  elif [[ -n "$b" && "$v" == "$b" ]]; then printf "${BR}%s${NC}" "$v"
  else printf "%s" "$v"; fi
}

# Human-readable from KB
human_kb() {
  awk -v k="$1" 'BEGIN{
    if(k>=1048576)      printf "%.1f GB", k/1048576
    else if(k>=1024)    printf "%.1f MB", k/1024
    else                printf "%d KB", k
  }'
}

# ── Privilege check ───────────────────────────────────────────────────────────
HAS_SUDO=false
if [[ "$EUID" -eq 0 ]] || sudo -n true 2>/dev/null; then HAS_SUDO=true; fi

esudo() {
  if   [[ "$EUID" -eq 0 ]];         then "$@" 2>/dev/null
  elif [[ "$HAS_SUDO" == "true" ]]; then sudo -n "$@" 2>/dev/null
  else return 1; fi
}

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
  [[ -f /etc/os-release ]] && . /etc/os-release || true
  OS_ID="${ID:-unknown}"; OS_ID_LIKE="${ID_LIKE:-}"; OS_PRETTY="${PRETTY_NAME:-${ID:-unknown}}"
  case "${OS_ID:-}" in
    ubuntu|debian|linuxmint|pop)          PKG_MANAGER="apt" ;;
    centos|rhel|rocky|almalinux|fedora|ol)
      PKG_MANAGER=$(command -v dnf &>/dev/null && echo "dnf" || echo "yum") ;;
    arch|manjaro)                         PKG_MANAGER="pacman" ;;
    *)
      if   echo "$OS_ID_LIKE" | grep -qiE "debian|ubuntu"; then PKG_MANAGER="apt"
      elif echo "$OS_ID_LIKE" | grep -qiE "rhel|centos|fedora"; then PKG_MANAGER="dnf"
      else PKG_MANAGER="unknown"; fi ;;
  esac
}

human_uptime() {
  local s; s=$(awk '{print int($1)}' /proc/uptime)
  local d=$(( s/86400 )) h=$(( s%86400/3600 )) m=$(( s%3600/60 ))
  local r=""; (( d>0 )) && r+="${d}d "; (( h>0 )) && r+="${h}h "; r+="${m}m"; echo "$r"
}

# ══════════════════════════════════════════════════════════════════════════════
# Header
# ══════════════════════════════════════════════════════════════════════════════
print_header() {
  local host; host=$(hostname)
  local dt; dt=$(date '+%Y-%m-%d %H:%M %Z')
  local i
  echo
  printf "${BC}${BOLD}┌"; for ((i=0;i<W+2;i++)); do printf '─'; done; printf "┐${NC}\n"
  printf "${BC}${BOLD}│${NC}  ${BOLD}SERVER STATUS REPORT${NC}"
  local pad=$(( W + 2 - 22 - ${#host} - ${#dt} - 4 ))
  printf "  ${CYAN}${BOLD}%s${NC}" "$host"
  printf "%*s" "$pad" ""
  printf "${DIM}%s${NC}" "$dt"
  printf "  ${BC}${BOLD}│${NC}\n"
  printf "${BC}${BOLD}└"; for ((i=0;i<W+2;i++)); do printf '─'; done; printf "┘${NC}\n"
  [[ "$HAS_SUDO" != "true" ]] && \
    printf "\n  ${YELLOW}⚠  No sudo — some checks limited. Re-run: sudo bash status.sh${NC}\n"
}

# ══════════════════════════════════════════════════════════════════════════════
# 1 — SYSTEM
# ══════════════════════════════════════════════════════════════════════════════
check_system() {
  section "SYSTEM"

  local tz ntp virt boot_time uptime_str
  tz=$(timedatectl show --property=Timezone --value 2>/dev/null \
       || cat /etc/timezone 2>/dev/null || date +%Z)
  ntp=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "?")
  virt=$(systemd-detect-virt 2>/dev/null || echo "?")
  boot_time=$(uptime -s 2>/dev/null || who -b 2>/dev/null | awk '{print $3,$4}' || echo "?")
  uptime_str=$(human_uptime)

  local ntp_str
  [[ "$ntp" == "yes" ]] && ntp_str="${BG}✔ NTP${NC}" || ntp_str="${BY}✗ NTP${NC}"

  kv2 "Hostname"  "$(hostname)"         "OS"       "$OS_PRETTY"
  kv2 "Kernel"    "$(uname -r)"         "Arch"     "$(uname -m)"
  kv2 "Uptime"    "$uptime_str"         "Boot"     "$boot_time"
  kv2 "Timezone"  "$tz"                 "NTP"      "$(printf "$ntp_str")"
  kv  "Virt"      "$virt"

  local uptime_s; uptime_s=$(awk '{print int($1)}' /proc/uptime)
  if (( uptime_s < 300 )); then
    printf "  ${BY}⚠  Rebooted < 5 min ago${NC}\n"; h_warn "Rebooted < 5 minutes ago"
  fi
  [[ "$ntp" == "no"  ]] && { printf "  ${BY}⚠  NTP not synced${NC}\n"; h_warn "NTP not synchronized"; }
  [[ "$ntp" == "yes" ]] && h_pass "NTP synchronized"
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

  printf "  ${DIM}CPU${NC}  %s  ${DIM}·${NC}  %s cores / %s threads\n" \
    "$cpu_model" "$cpu_cores" "$cpu_threads"
  echo

  # RAM
  local rt ra ru rp
  rt=$(awk '/^MemTotal/{print $2}'     /proc/meminfo)
  ra=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
  ru=$(( rt - ra )); rp=$(( ru * 100 / rt ))
  metric "RAM"  "$rp"  "$(human_kb $ru) used / $(human_kb $rt) total"
  (( rp >= 90 )) && { printf "  ${BR}✗  RAM critical (${rp}%%)${NC}\n"; h_fail "RAM critical (${rp}%)"; } \
  || { (( rp >= 75 )) && { printf "  ${BY}⚠  RAM high (${rp}%%)${NC}\n"; h_warn "RAM high (${rp}%)"; } \
  || h_pass "RAM normal (${rp}%)"; }

  # Swap
  local st sf su sp
  st=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
  sf=$(awk '/^SwapFree/{print $2}'  /proc/meminfo)
  su=$(( st - sf ))
  if (( st == 0 )); then
    printf "  ${BOLD}%-7s${NC} ${DIM}(none configured)${NC}\n" "Swap"
    (( rt < 4194304 )) && { printf "  ${BY}⚠  No swap, RAM < 4 GB${NC}\n"; h_warn "No swap (RAM < 4 GB)"; }
  else
    sp=$(( su * 100 / st ))
    metric "Swap" "$sp" "$(human_kb $su) used / $(human_kb $st) total"
    (( sp >= 50 )) && { h_warn "Swap high (${sp}%)"; }
  fi

  # Load
  local load_1 load_5 load_15 cpu_count lp
  read -r load_1 load_5 load_15 _ < /proc/loadavg
  cpu_count=$(nproc)
  lp=$(awk "BEGIN{printf \"%.0f\", $load_1/$cpu_count*100}")
  metric "Load" "$lp" "${load_1} / ${load_5} / ${load_15}  (${cpu_count} CPUs,  1m / 5m / 15m)"
  (( lp >= 200 )) && { printf "  ${BR}✗  Load critical${NC}\n"; h_fail "Load critical: ${load_1} (${lp}%)"; } \
  || { (( lp >= 100 )) && { printf "  ${BY}⚠  Load high${NC}\n"; h_warn "Load high: ${load_1} (${lp}%)"; } \
  || h_pass "Load normal: ${load_1} (${lp}%)"; }
}

# ══════════════════════════════════════════════════════════════════════════════
# 3 — STORAGE
# ══════════════════════════════════════════════════════════════════════════════
check_storage() {
  section "STORAGE"

  echo
  # Parse df -hT and df -T together using awk
  # Display: name bar pct used/total type
  local fs_data
  fs_data=$(df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)
  local fs_data_num
  fs_data_num=$(df -T  -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

  # Build a display for each filesystem
  while IFS= read -r line; do
    local fs type size used avail pct_str mount
    read -r fs type size used avail pct_str mount <<< "$line"
    local pct="${pct_str//%/}"
    [[ "$pct" =~ ^[0-9]+$ ]] || continue

    # Determine color
    local bar_str; bar_str=$(bar "$pct")
    local pct_str_colored; pct_str_colored=$(pct_color "$pct")

    printf "  ${BOLD}%-20s${NC} %s  %s  ${DIM}%s / %s  (%s)${NC}\n" \
      "$mount" "$bar_str" "$pct_str_colored" "$used" "$size" "$type"

    (( pct >= 90 )) && { printf "  ${BR}✗  Disk %s at %d%% — CRITICAL${NC}\n" "$mount" "$pct"
                         h_fail "Disk $mount is ${pct}% full"; } \
    || { (( pct >= 80 )) && { printf "  ${BY}⚠  Disk %s at %d%%${NC}\n" "$mount" "$pct"
                               h_warn "Disk $mount is ${pct}% full"; }; }
  done <<< "$fs_data"

  # Inode checks (silent — only report problems)
  while read -r _ _ _ _ _ ipct_raw imount; do
    local ipct="${ipct_raw//%/}"
    [[ "$ipct" =~ ^[0-9]+$ ]] || continue
    (( ipct >= 90 )) && { printf "  ${BR}✗  Inodes %s at %d%%${NC}\n" "$imount" "$ipct"
                          h_fail "Inode exhaustion on $imount (${ipct}%)"; } \
    || { (( ipct >= 80 )) && { printf "  ${BY}⚠  Inodes %s at %d%%${NC}\n" "$imount" "$ipct"
                                h_warn "High inode usage on $imount (${ipct}%)"; }; }
  done < <(df -iT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

  # Swap
  local swap_info; swap_info=$(swapon --show=NAME,TYPE,SIZE,USED 2>/dev/null | tail -n +2 || true)
  [[ -n "$swap_info" ]] && printf "\n  ${DIM}Swap:${NC}  %s\n" "$swap_info"
}

# ══════════════════════════════════════════════════════════════════════════════
# 4 — NETWORK
# ══════════════════════════════════════════════════════════════════════════════
check_network() {
  section "NETWORK"

  local pub4
  pub4=$(curl -fsSL --max-time 4 https://api.ipify.org 2>/dev/null \
      || curl -4 -fsSL --max-time 4 https://ifconfig.me 2>/dev/null \
      || echo "(unavailable)")

  local gw dns dns_test
  gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}' || echo "?")
  dns=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | xargs || echo "none")
  dns_test=$(dig +short +time=3 google.com A 2>/dev/null | head -1 \
    || host -W3 google.com 2>/dev/null | awk '/has address/{print $4; exit}' \
    || getent hosts google.com 2>/dev/null | awk '{print $1; exit}' || echo "")

  local pub4_str dns_str
  [[ "$pub4" == "(unavailable)" ]] \
    && { pub4_str="${BR}(unavailable)${NC}"; h_fail "No internet"; } \
    || { pub4_str="${BG}${pub4}${NC}"; h_pass "Internet OK ($pub4)"; }
  [[ -n "$dns_test" ]] \
    && { dns_str="${BG}✔${NC} ${dns_test}"; h_pass "DNS OK"; } \
    || { dns_str="${BR}✗ FAILED${NC}"; h_fail "DNS resolution failed"; }

  kv2 "Public IPv4"  "$(printf "$pub4_str")"  "Gateway"  "$gw"
  kv2 "DNS servers"  "$dns"                   "Resolve"  "$(printf "$dns_str")"

  echo
  printf "  ${DIM}Interfaces:${NC}\n"
  ip -brief addr show 2>/dev/null | awk '{
    st = ($2=="UP") ? "\033[1;32m●\033[0m" : "\033[2m○\033[0m"
    printf "  %s  \033[1m%-12s\033[0m  \033[2m%-10s\033[0m  %s\n", st, $1, $2, $3
  }'

  echo
  printf "  ${DIM}Listening ports:${NC}\n"
  if [[ "$HAS_SUDO" == "true" ]]; then
    esudo ss -tlnpu 2>/dev/null \
      | awk 'NR>1{
          match($7,/\(\("([^"]+)/,m); proc=m[1]?m[1]:"?"
          printf "  \033[2m%-6s\033[0m  %-26s \033[2m%s\033[0m\n",$1,$5,proc
        }' || true
  else
    ss -tlnp 2>/dev/null | awk 'NR>1{printf "  \033[2m%-6s\033[0m  %s\n",$1,$5}'
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 5 — SECURITY
# ══════════════════════════════════════════════════════════════════════════════
check_security() {
  section "SECURITY"

  # 5a — SSH config
  printf "\n  ${BOLD}SSH Configuration${NC}\n"

  local sshd_t=""
  sshd_t=$(esudo sshd -T 2>/dev/null || true)

  get_ssh() {
    local key="$1" default="${2:-?}" val=""
    [[ -n "$sshd_t" ]] && val=$(echo "$sshd_t" | awk -v k="${key,,}" 'tolower($1)==k{print $2;exit}')
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

  # Two-column checklist
  printf "  $(chk "$pw_auth"  "no")  ${DIM}PasswordAuth${NC}    %-8s  " "$(cv "$pw_auth" "no" "yes")"
  printf "  $(chk "$empty_pw" "no")  ${DIM}EmptyPwd${NC}      %s\n"        "$(cv "$empty_pw" "no" "yes")"
  printf "  $(chk "$pubkey"  "yes")  ${DIM}PubkeyAuth${NC}     %-8s  " "$(cv "$pubkey" "yes" "no")"
  printf "  $(chk "$x11"      "no")  ${DIM}X11Forward${NC}    %s\n"        "$(cv "$x11" "no" "yes")"
  printf "  ${DIM}◦  PermitRootLogin${NC}  %-12s  " "$root_login"
  printf "  ${DIM}◦  MaxAuthTries${NC}    %s   ${DIM}Port${NC} %s\n" "$max_tries" "$port"

  [[ "$pw_auth" == "yes" ]] && { printf "  ${BR}✗  Password auth enabled!${NC}\n"; h_fail "SSH: PasswordAuthentication=yes"; } \
                             || { [[ "$pw_auth" == "no" ]] && h_pass "SSH: key-only auth"; }
  [[ "$empty_pw" == "yes" ]] && { printf "  ${BR}✗  Empty passwords allowed!${NC}\n"; h_fail "SSH: PermitEmptyPasswords=yes"; }

  # 5b — Authorized keys
  printf "\n  ${BOLD}Authorized Keys${NC}\n"
  local user_home
  user_home=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6 2>/dev/null || echo "$HOME")
  local auth_keys="${user_home}/.ssh/authorized_keys"

  if [[ -f "$auth_keys" && -s "$auth_keys" ]]; then
    local kc; kc=$(grep -cE "^(ssh-|ecdsa-|sk-)" "$auth_keys" 2>/dev/null \
                   || wc -l < "$auth_keys")
    printf "  ${BG}✔${NC}  ${DIM}%s${NC}  %d key(s)\n" "${SUDO_USER:-$USER}" "$kc"
    ssh-keygen -lf "$auth_keys" 2>/dev/null \
      | awk '{printf "     \033[2m%s  %s  %s\033[0m\n", $1,$2,$4}' || true
    h_pass "Authorized keys OK ($kc)"
  else
    printf "  ${BR}✗  No authorized_keys for %s${NC}\n" "${SUDO_USER:-$USER}"
    h_warn "No authorized_keys"
  fi
  if [[ "$HAS_SUDO" == "true" ]]; then
    local rk; rk=$(esudo wc -l < /root/.ssh/authorized_keys 2>/dev/null | tr -d ' ' || echo 0)
    (( rk > 0 )) && printf "  ${DIM}◦  root: %d key(s)${NC}\n" "$rk"
  fi

  # 5c — fail2ban
  printf "\n  ${BOLD}fail2ban${NC}\n"
  local f2b_active
  f2b_active=$(esudo systemctl is-active fail2ban 2>/dev/null || true)
  [[ -z "$f2b_active" ]] && f2b_active="inactive"

  printf "  $(dot "$f2b_active")  fail2ban  "
  if [[ "$f2b_active" == "active" ]]; then
    printf "${BG}active${NC}"
    h_pass "fail2ban active"
    local jail; jail=$(esudo fail2ban-client status sshd 2>/dev/null || true)
    if [[ -n "$jail" ]]; then
      local now total
      now=$(echo "$jail" | grep "Banned IP list:" | sed 's/.*Banned IP list://' \
            | tr -s ' ' '\n' | grep -cE "[0-9]" || echo 0)
      total=$(echo "$jail" | awk '/Total banned:/{print $NF}')
      printf "   ${DIM}Banned now:${NC} ${BY}%s${NC}   ${DIM}Total bans:${NC} %s\n" "$now" "${total:-?}"
      (( now > 0 )) && { printf "  ${BY}⚠  %s IPs currently banned${NC}\n" "$now"
                         h_warn "fail2ban: $now IPs banned"; }
    else
      printf "\n  ${BY}⚠  sshd jail not found${NC}\n"; h_warn "fail2ban sshd jail missing"
    fi
  else
    printf "${BR}NOT running${NC}\n"
    h_fail "fail2ban not active"
  fi

  # 5d — Auth events
  printf "\n  ${BOLD}Auth Events  ${DIM}(last 24h)${NC}\n"
  local failed=0
  if [[ "$HAS_SUDO" == "true" ]]; then
    failed=$(
      esudo journalctl -u ssh -u sshd --since "24 hours ago" 2>/dev/null \
        | grep -E "Failed password|Invalid user|authentication failure" | wc -l \
      || esudo grep -cE "Failed|Invalid|authentication failure" /var/log/auth.log 2>/dev/null \
      || true
    )
    failed=${failed:-0}
  fi

  # Visual attack bar (max scale = 5000)
  local scale=5000
  local attack_pct=$(( failed * 100 / scale ))
  (( attack_pct > 100 )) && attack_pct=100
  local attack_color
  (( failed > 500 )) && attack_color="$BR" || { (( failed > 100 )) && attack_color="$BY" || attack_color="$BG"; }

  printf "  %s  ${DIM}Failed attempts:${NC}  ${attack_color}%s${NC}\n" \
    "$(bar "$attack_pct" 22)" "$failed"

  if   (( failed > 500 )); then
    printf "  ${BR}✗  High volume — brute force attack likely${NC}\n"
    h_fail "SSH: $failed failed attempts in 24h"
  elif (( failed > 100 )); then
    printf "  ${BY}⚠  Elevated attack activity${NC}\n"
    h_warn "SSH: $failed failed attempts in 24h"
  else
    h_pass "Auth attempts normal ($failed in 24h)"
  fi

  # Top attacking IPs
  if [[ "$HAS_SUDO" == "true" && "$failed" -gt 5 ]]; then
    printf "  ${DIM}Top source IPs:${NC}\n"
    esudo journalctl -u ssh -u sshd --since "24 hours ago" 2>/dev/null \
      | grep -oE "from [0-9]{1,3}(\.[0-9]{1,3}){3}" | awk '{print $2}' \
      | sort | uniq -c | sort -rn | head -5 \
      | awk '{printf "     \033[2m%6d ×\033[0m  %s\n",$1,$2}' || true
  fi

  # Last logins
  printf "\n  ${DIM}Last logins:${NC}\n"
  last -n 5 -w 2>/dev/null | head -5 \
    | awk '{printf "  \033[2m%s\033[0m\n",$0}' || printf "  ${DIM}(unavailable)${NC}\n"
}

# ══════════════════════════════════════════════════════════════════════════════
# 6 — SERVICES
# ══════════════════════════════════════════════════════════════════════════════
check_services() {
  section "SERVICES"

  svc_row() {
    local unit="$1" label="${2:-$1}"
    local status
    status=$(systemctl is-active "$unit" 2>/dev/null || true)
    [[ -z "$status" ]] && status="not-found"
    printf "  $(dot "$status")  ${BOLD}%-30s${NC}" "$label"
    case "$status" in
      active)   printf "${BG}active${NC}\n" ;;
      inactive) printf "${YELLOW}inactive${NC}\n" ;;
      failed)   printf "${BR}failed${NC}\n" ;;
      *)        printf "${DIM}not found${NC}\n" ;;
    esac
    [[ "$status" == "active" ]]
  }

  echo
  # SSH: try sshd first, then ssh
  local sshd_up=false
  if svc_row "sshd" "sshd"; then sshd_up=true
  elif svc_row "ssh" "ssh (sshd)"; then sshd_up=true; fi
  $sshd_up && h_pass "sshd running" || h_fail "sshd NOT running"

  svc_row "fail2ban" "fail2ban" || true

  case "$PKG_MANAGER" in
    apt)
      svc_row "unattended-upgrades" "unattended-upgrades" \
        && h_pass "Auto security updates active" \
        || { printf "  ${BY}⚠  auto updates inactive${NC}\n"; h_warn "Auto updates not active"; } ;;
    dnf)
      svc_row "dnf-automatic.timer" "dnf-automatic.timer" \
        && h_pass "Auto security updates active" \
        || { printf "  ${BY}⚠  auto updates inactive${NC}\n"; h_warn "Auto updates not active"; } ;;
  esac

  if command -v docker &>/dev/null; then
    svc_row "docker" "docker" || true
    local containers; containers=$(docker ps --format "  ${DIM}↳${NC} {{.Names}}  {{.Status}}" 2>/dev/null || true)
    [[ -n "$containers" ]] && echo "$containers"
  fi

  echo
  local failed_units
  failed_units=$(esudo systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null \
                 | grep -v "^$" || true)
  if [[ -n "$failed_units" ]]; then
    printf "  ${BR}✗  Failed systemd units:${NC}\n"
    echo "$failed_units" | head -8 | awk '{printf "     \033[1;31m%s\033[0m\n",$1}'
    local n; n=$(echo "$failed_units" | grep -c "." || echo "?")
    h_fail "$n systemd unit(s) failed"
  else
    printf "  ${BG}✔${NC}  No failed systemd units\n"
    h_pass "No failed systemd units"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 7 — PERFORMANCE
# ══════════════════════════════════════════════════════════════════════════════
check_performance() {
  section "PERFORMANCE"

  local load_1 load_5 load_15 cpu_count lp
  read -r load_1 load_5 load_15 _ < /proc/loadavg
  cpu_count=$(nproc)
  lp=$(awk "BEGIN{printf \"%.0f\", $load_1/$cpu_count*100}")

  echo
  metric "Load"  "$lp"  "${load_1} / ${load_5} / ${load_15}  (1m / 5m / 15m,  ${cpu_count} CPUs)"

  local mem_avail_pct
  mem_avail_pct=$(awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{printf "%.0f",a/t*100}' /proc/meminfo)
  local mem_used_pct=$(( 100 - mem_avail_pct ))
  metric "Memory" "$mem_used_pct" "${mem_avail_pct}% available"

  echo
  printf "  ${DIM}Top 5 by CPU:${NC}\n"
  ps axo user:12,pid,pcpu,pmem,comm --sort=-%cpu 2>/dev/null \
    | head -6 | awk 'NR==1{printf "  \033[2m%-12s %6s %5s %5s %s\033[0m\n",$1,$2,$3,$4,$5; next}
                     {printf "  %-12s \033[2m%6s\033[0m %5s %5s %s\n",$1,$2,$3,$4,$5}'

  echo
  printf "  ${DIM}Top 5 by memory:${NC}\n"
  ps axo user:12,pid,pcpu,pmem,comm --sort=-%mem 2>/dev/null \
    | head -6 | awk 'NR==1{printf "  \033[2m%-12s %6s %5s %5s %s\033[0m\n",$1,$2,$3,$4,$5; next}
                     {printf "  %-12s \033[2m%6s\033[0m %5s %5s %s\n",$1,$2,$3,$4,$5}'

  local oom=0
  oom=$(esudo journalctl -k --since boot 2>/dev/null \
        | grep -E "oom_kill_process|Out of memory" | wc -l || true)
  oom=${oom:-0}
  echo
  if (( oom > 0 )); then
    printf "  ${BY}⚠  OOM killer fired %d time(s) since boot${NC}\n" "$oom"
    h_warn "OOM: $oom kill event(s) since boot"
  else
    printf "  ${BG}✔${NC}  No OOM events since boot\n"
  fi

  if command -v iostat &>/dev/null; then
    local iowait; iowait=$(iostat -c 1 1 2>/dev/null | awk 'NR==4{print $4}')
    [[ -n "$iowait" ]] && printf "  ${DIM}I/O wait:${NC}  %s%%\n" "$iowait"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 8 — UPDATES
# ══════════════════════════════════════════════════════════════════════════════
check_updates() {
  section "UPDATES"
  echo

  case "$PKG_MANAGER" in
    apt)
      local dry_run_out total sec
      dry_run_out=$(apt-get -q --dry-run upgrade 2>/dev/null || true)
      total=$(echo "$dry_run_out" | grep -c "^Inst" || true); total=${total:-0}
      sec=$(echo "$dry_run_out"   | grep "^Inst" | grep -ci security || true); sec=${sec:-0}

      if (( sec > 0 )); then
        printf "  ${BR}✗  %d security update(s) pending  ${DIM}(%d total)${NC}\n" "$sec" "$total"
        h_fail "$sec pending security updates"
      elif (( total > 0 )); then
        printf "  ${BY}⚠  %d update(s) pending (0 security)${NC}\n" "$total"
        h_warn "$total package updates pending"
      else
        printf "  ${BG}✔${NC}  All packages up to date\n"
        h_pass "No pending security updates"
      fi
      (( total > 20 )) && { printf "  ${BY}⚠  %d total updates pending${NC}\n" "$total"
                             h_warn "$total total updates pending"; }

      if [[ -f /var/run/reboot-required ]]; then
        local running_kernel installed_kernel
        running_kernel=$(uname -r)
        installed_kernel=$(dpkg -l 'linux-image-*' 2>/dev/null \
          | awk '/^ii/{print $3}' | grep -v "$running_kernel" \
          | sort -V | tail -1 || echo "")
        printf "  ${BY}⚠  Reboot required${NC}"
        if [[ -n "$installed_kernel" ]]; then
          printf "  ${DIM}running:${NC} %s  ${DIM}→  pending:${NC} ${BY}%s${NC}" \
            "$running_kernel" "$installed_kernel"
        elif [[ -f /var/run/reboot-required.pkgs ]]; then
          printf "  ${DIM}(%s)${NC}" "$(tr '\n' ',' < /var/run/reboot-required.pkgs | sed 's/,$//')"
        fi
        printf "\n"
        h_warn "Reboot required (running: ${running_kernel})"
      else
        printf "  ${BG}✔${NC}  No reboot required  ${DIM}(kernel: $(uname -r))${NC}\n"
        h_pass "No reboot required"
      fi

      local last_up
      last_up=$(stat -c '%y' /var/lib/apt/periodic/upgrade-stamp 2>/dev/null | cut -d. -f1 \
             || stat -c '%y' /var/lib/dpkg/lock 2>/dev/null | cut -d. -f1 || echo "unknown")
      printf "  ${DIM}Last upgrade:${NC}  %s\n" "$last_up"
      ;;

    dnf|yum)
      local sec total
      sec=$(esudo "$PKG_MANAGER" check-update --security -q 2>/dev/null \
            | grep -cE "^\S+\.(x86_64|aarch64|noarch|i686)" || true); sec=${sec:-0}
      total=$(esudo "$PKG_MANAGER" check-update -q 2>/dev/null \
              | grep -cE "^\S+\.(x86_64|aarch64|noarch|i686)" || true); total=${total:-0}
      if (( sec > 0 )); then
        printf "  ${BR}✗  %d security update(s) pending${NC}\n" "$sec"; h_fail "$sec pending security updates"
      else
        printf "  ${BG}✔${NC}  No pending security updates\n"; h_pass "No pending security updates"
      fi
      ;;
    *) printf "  ${DIM}Update check not implemented for: %s${NC}\n" "$PKG_MANAGER" ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════════════
# 9 — KERNEL TUNING
# ══════════════════════════════════════════════════════════════════════════════
check_kernel() {
  section "KERNEL TUNING"

  get_sysctl() { cat "/proc/sys/${1//\./\/}" 2>/dev/null || echo "N/A"; }

  local swappiness vfs_cache dirty_r tcp_sync ip_fwd dmesg_r
  swappiness=$(get_sysctl "vm.swappiness")
  vfs_cache=$(get_sysctl  "vm.vfs_cache_pressure")
  dirty_r=$(get_sysctl    "vm.dirty_ratio")
  tcp_sync=$(get_sysctl   "net.ipv4.tcp_syncookies")
  ip_fwd=$(get_sysctl     "net.ipv4.ip_forward")
  dmesg_r=$(get_sysctl    "kernel.dmesg_restrict")

  echo
  # Two-column sysctl display with inline check marks
  printf "  ${DIM}vm.swappiness${NC}          %-6s  " \
    "$(cv "$swappiness" "" "")"; [[ "$swappiness" =~ ^[0-9]+$ ]] && (( swappiness <= 10 )) \
    && printf "${BG}✔${NC}" || printf "${BY}~${NC}"; printf "  "
  printf "  ${DIM}vm.vfs_cache_pressure${NC}  %s\n" "$vfs_cache"

  printf "  ${DIM}vm.dirty_ratio${NC}         %-6s     " "$dirty_r"
  printf "  ${DIM}net.ipv4.tcp_syncookies${NC} %-3s " "$tcp_sync"
  [[ "$tcp_sync" == "1" ]] && printf "${BG}✔${NC}" || printf "${BR}✗${NC}"; printf "\n"

  printf "  ${DIM}net.ipv4.ip_forward${NC}    %-6s     " "$ip_fwd"
  printf "  ${DIM}kernel.dmesg_restrict${NC}   %s\n" "$dmesg_r"

  local fd_info; fd_info=$(awk '{print $1 " / " $3}' /proc/sys/fs/file-nr 2>/dev/null || echo "N/A")
  printf "  ${DIM}Open file descriptors:${NC}  %s\n" "$fd_info"

  [[ "$swappiness" =~ ^[0-9]+$ ]] && (( swappiness > 30 )) \
    && { printf "  ${BY}⚠  vm.swappiness=%s (recommend ≤10 for servers)${NC}\n" "$swappiness"
         h_warn "Kernel: vm.swappiness=$swappiness too high"; }
  [[ "$tcp_sync" == "0" ]] \
    && { printf "  ${BY}⚠  tcp_syncookies disabled (SYN flood risk)${NC}\n"
         h_warn "Kernel: tcp_syncookies=0"; }

  echo
  printf "  ${DIM}sysctl drop-ins:${NC}  "
  ls /etc/sysctl.d/ 2>/dev/null | grep -v "^$" | tr '\n' ' ' | awk '{printf "%s",$0}'; printf "\n"

  echo
  local kerr=""
  kerr=$(esudo dmesg --level=err,crit,alert,emerg --since "1 hour ago" 2>/dev/null \
      || esudo dmesg -T 2>/dev/null | grep -iE "error|fail|crit" | tail -5 || true)
  if [[ -n "$kerr" ]]; then
    printf "  ${BR}✗  Kernel errors in last hour:${NC}\n"
    echo "$kerr" | tail -5 | awk '{printf "  \033[2m%s\033[0m\n",$0}'
    h_fail "Kernel errors in dmesg"
  else
    printf "  ${BG}✔${NC}  No kernel errors (dmesg, last hour)\n"
    h_pass "No recent kernel errors"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 10 — SCHEDULED TASKS
# ══════════════════════════════════════════════════════════════════════════════
check_scheduled() {
  section "SCHEDULED TASKS"

  local current_user="${SUDO_USER:-$USER}"
  local cron_out root_cron

  cron_out=$(crontab -u "$current_user" -l 2>/dev/null || crontab -l 2>/dev/null || echo "")
  local user_cron; user_cron=$(echo "$cron_out" | grep -vE "^#|^$" | wc -l | tr -d ' ')

  if [[ "$HAS_SUDO" == "true" ]]; then
    root_cron=$(esudo crontab -u root -l 2>/dev/null || echo "")
    local root_entries; root_entries=$(echo "$root_cron" | grep -vE "^#|^$" | wc -l | tr -d ' ')
    printf "\n  ${DIM}Crontab:${NC}  %s: %s entries  ·  root: %s entries\n" \
      "$current_user" "$user_cron" "$root_entries"
  else
    printf "\n  ${DIM}Crontab (%s):${NC}  %s entries\n" "$current_user" "$user_cron"
  fi

  printf "  ${DIM}cron.d:${NC}  "
  ls /etc/cron.d/ 2>/dev/null | grep -v "^$" | tr '\n' ',' | sed 's/,$//' | awk '{printf "%s",$0}'
  printf "\n"

  echo
  printf "  ${DIM}Upcoming systemd timers:${NC}\n"
  local timer_out
  timer_out=$(systemctl list-timers --no-pager 2>/dev/null || true)
  if [[ -n "$timer_out" ]]; then
    echo "$timer_out" | awk '
      NR>1 && /[a-zA-Z]/ && !/^NEXT/ && !/listed/{
        # field 1-4=NEXT datetime, 5-6=LEFT, 7-10=LAST, 11-12=PASSED, 13=UNIT, rest=ACTIVATES
        split($0,a," ")
        left=$5" "$6
        unit=$13
        if(unit!="" && unit!="UNIT")
          printf "  \033[2m%-14s\033[0m  %s\n", left, unit
      }' | head -8
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
print_summary() {
  local np=${#HEALTH_PASS[@]} nw=${#HEALTH_WARN[@]} nf=${#HEALTH_FAIL[@]}
  local total=$(( np + nw + nf )) i W2=66

  echo
  printf "${BC}${BOLD}┌"; local j; for ((j=0;j<W2;j++)); do printf '─'; done; printf "┐${NC}\n"
  printf "${BC}${BOLD}│${NC}  ${BOLD}HEALTH SUMMARY${NC}"
  printf "%*s" $(( W2 - 16 )) ""; printf "${BC}${BOLD}│${NC}\n"
  printf "${BC}${BOLD}├"; for ((j=0;j<W2;j++)); do printf '─'; done; printf "┤${NC}\n"

  # Score bar
  local pass_w=$(( np * 30 / (total>0?total:1) ))
  local warn_w=$(( nw * 30 / (total>0?total:1) ))
  local fail_w=$(( nf * 30 / (total>0?total:1) ))
  printf "${BC}${BOLD}│${NC}  "
  printf "${BG}"; for ((j=0;j<pass_w;j++)); do printf '█'; done; printf "${NC}"
  printf "${BY}"; for ((j=0;j<warn_w;j++)); do printf '█'; done; printf "${NC}"
  printf "${BR}"; for ((j=0;j<fail_w;j++)); do printf '█'; done; printf "${NC}"
  local rem=$(( 30 - pass_w - warn_w - fail_w ))
  printf "${DIM}"; for ((j=0;j<rem;j++)); do printf '░'; done; printf "${NC}"
  printf "  ${BG}%-2d PASS${NC}  ${BY}%-2d WARN${NC}  ${BR}%-2d FAIL${NC}" "$np" "$nw" "$nf"
  printf "%*s" $(( W2 - 30 - 24 - 2 )) ""
  printf "${BC}${BOLD}│${NC}\n"

  printf "${BC}${BOLD}├"; for ((j=0;j<W2;j++)); do printf '─'; done; printf "┤${NC}\n"

  # Failures first, then warnings, then passes
  local printed=0
  for item in "${HEALTH_FAIL[@]+"${HEALTH_FAIL[@]}"}"; do
    printf "${BC}${BOLD}│${NC}  ${BR}✗${NC}  %-${W2}s${BC}${BOLD}│${NC}\n" "$item"
    (( printed++ ))
  done
  for item in "${HEALTH_WARN[@]+"${HEALTH_WARN[@]}"}"; do
    printf "${BC}${BOLD}│${NC}  ${BY}⚠${NC}  %-${W2}s${BC}${BOLD}│${NC}\n" "$item"
    (( printed++ ))
  done
  # Show only first few passes to keep summary compact
  local pass_shown=0
  for item in "${HEALTH_PASS[@]+"${HEALTH_PASS[@]}"}"; do
    (( pass_shown >= 8 )) && break
    printf "${BC}${BOLD}│${NC}  ${BG}✔${NC}  %-${W2}s${BC}${BOLD}│${NC}\n" "$item"
    (( pass_shown++ ))
  done
  (( np > 8 )) && printf "${BC}${BOLD}│${NC}  ${DIM}✔  … and %d more passing checks${NC}%*s${BC}${BOLD}│${NC}\n" \
    "$(( np - 8 ))" "$(( W2 - $(printf "   … and %d more passing checks" "$(( np - 8 ))" | wc -c) ))" ""

  printf "${BC}${BOLD}└"; for ((j=0;j<W2;j++)); do printf '─'; done; printf "┘${NC}\n\n"

  (( nf > 0 )) && return 2
  (( nw > 0 )) && return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# 11 — USER ACCOUNTS
# ══════════════════════════════════════════════════════════════════════════════
check_users() {
  section "USER ACCOUNTS"

  # Global SSH password auth setting (re-read sshd effective config)
  local sshd_t="" pw_auth_global="?"
  sshd_t=$(esudo sshd -T 2>/dev/null || true)
  [[ -n "$sshd_t" ]] \
    && pw_auth_global=$(echo "$sshd_t" | awk 'tolower($1)=="passwordauthentication"{print $2;exit}') \
    || pw_auth_global=$(grep -iE "^\s*PasswordAuthentication\s" /etc/ssh/sshd_config 2>/dev/null \
                        | tail -1 | awk '{print $2}')
  pw_auth_global="${pw_auth_global:-?}"

  printf "\n  ${DIM}SSH PasswordAuthentication:${NC}  %s\n\n" "$(cv "$pw_auth_global" "no" "yes")"

  # Table header
  printf "  ${DIM}%-18s %-6s %-22s %-10s %s${NC}\n" \
    "User" "UID" "Shell" "Password" "SSH Keys"
  printf "  ${DIM}%s${NC}\n" "─────────────────────────────────────────────────────────────"

  local any_pw_issue=false any_no_keys=false

  # Iterate interactive users: root + UID >= 1000 with real shells
  while IFS=: read -r user _ uid _ _ home shell; do
    [[ "$user" != "root" ]] && (( uid < 1000 )) && continue
    case "$shell" in
      /sbin/nologin|/usr/sbin/nologin|/bin/false|/usr/bin/false|/bin/sync|/usr/bin/nologin)
        continue ;;
      "") continue ;;
    esac

    # Password status via passwd -S (needs sudo)
    local pw_raw="" pw_status="" pw_display
    if [[ "$HAS_SUDO" == "true" ]]; then
      pw_raw=$(esudo passwd -S "$user" 2>/dev/null | awk '{print $2}')
    fi
    case "${pw_raw:-}" in
      P|PS)  pw_status="set";    pw_display="${BG}set${NC}" ;;
      L|LK)  pw_status="locked"; pw_display="${BY}locked${NC}" ;;
      NP)    pw_status="none";   pw_display="${BY}none${NC}" ;;
      *)     pw_status="?";      pw_display="${DIM}?${NC}" ;;
    esac

    # Authorized SSH keys count
    local auth_keys="${home}/.ssh/authorized_keys" key_count=0 key_display
    if [[ -f "$auth_keys" && -s "$auth_keys" ]]; then
      key_count=$(grep -cE "^(ssh-|ecdsa-|sk-)" "$auth_keys" 2>/dev/null || wc -l < "$auth_keys")
      key_display="${BG}${key_count} key(s)${NC}"
    else
      key_display="${BY}none${NC}"
    fi

    # Print row
    printf "  ${BOLD}%-18s${NC} ${DIM}%-6s${NC} ${DIM}%-22s${NC} " "$user" "$uid" "$shell"
    printf "%b  %b\n" "$pw_display" "$key_display"

    # Per-user warnings (collected, printed after table)
    if [[ "$pw_status" == "none" ]]; then
      any_pw_issue=true
      printf "  ${BR}✗${NC}  ${BOLD}%s${NC}: no password set — set one for emergency console access\n" "$user"
      printf "     ${DIM}→ sudo passwd %s${NC}\n" "$user"
      h_fail "$user: no password set (no console fallback)"
    fi

    if [[ "$pw_status" == "locked" ]]; then
      any_pw_issue=true
      printf "  ${BY}⚠${NC}  ${BOLD}%s${NC}: password locked — no emergency console access\n" "$user"
      printf "     ${DIM}→ sudo passwd %s${NC}\n" "$user"
      h_warn "$user: password locked (no console fallback)"
    fi

    if (( key_count == 0 )) && [[ "$pw_auth_global" == "no" ]]; then
      any_no_keys=true
      printf "  ${BR}✗${NC}  ${BOLD}%s${NC}: no SSH keys + password auth disabled → ${BR}cannot login!${NC}\n" "$user"
      h_fail "$user: no SSH keys and PasswordAuthentication=no (locked out)"
    fi

    if [[ "$pw_status" == "set" && "$pw_auth_global" == "yes" ]]; then
      printf "  ${BY}⚠${NC}  ${BOLD}%s${NC}: has password + SSH password auth enabled — password login possible\n" "$user"
      h_warn "$user: password login via SSH is possible"
    fi

  done < /etc/passwd

  echo
  # Summary line
  if [[ "$any_pw_issue" == "false" && "$any_no_keys" == "false" ]]; then
    printf "  ${BG}✔${NC}  All interactive users have a password and SSH keys\n"
    h_pass "All interactive users have a password and SSH keys"
  fi
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
  check_users
  check_services
  check_performance
  check_updates
  check_kernel
  check_scheduled
  print_summary
}

main "$@"
