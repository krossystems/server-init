#!/usr/bin/env bash
# Status line: comprehensive project status with colors

input=""
if ! [ -t 0 ]; then
  input=$(cat)
fi

# Colors — $'...' embeds real ESC bytes at assignment time
C_DIR=$'\033[38;5;75m'      # blue
C_GIT=$'\033[38;5;114m'     # green
C_MODEL=$'\033[38;5;183m'   # purple
C_CTX=$'\033[38;5;222m'     # yellow
C_WARN=$'\033[38;5;203m'    # red
C_ADD=$'\033[38;5;114m'     # green
C_RM=$'\033[38;5;203m'      # red
C_TOK=$'\033[38;5;180m'     # orange
C_TIME=$'\033[38;5;245m'    # gray
C_DIM=$'\033[38;5;240m'     # dim gray
C_LOAD=$'\033[38;5;147m'    # light purple
C_MEM=$'\033[38;5;117m'     # light cyan
NC=$'\033[0m'

# Parse JSON
cwd="" model="" pct="" size="" cost=""
in_tok="0" out_tok="0" lines_add="" lines_rm="" turns=""
if [[ -n "$input" ]] && command -v jq &>/dev/null; then
  cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
  model=$(echo "$input" | jq -r '.model.display_name // empty' 2>/dev/null || true)
  pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null || true)
  size=$(echo "$input" | jq -r '.context_window.context_window_size // empty' 2>/dev/null || true)
  cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null || true)
  in_tok=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0 | floor' 2>/dev/null || echo "0")
  out_tok=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0 | floor' 2>/dev/null || echo "0")
  lines_add=$(echo "$input" | jq -r '.cost.total_lines_added // empty' 2>/dev/null || true)
  lines_rm=$(echo "$input" | jq -r '.cost.total_lines_removed // empty' 2>/dev/null || true)
  turns=$(echo "$input" | jq -r '.num_turns // empty' 2>/dev/null || true)
fi

# Helper: format numbers with K/M suffix (integer only)
fmt_n() {
  local n="${1:-0}"
  n="${n%%.*}"
  n="${n:-0}"
  if (( n >= 1000000 )); then
    printf "%dM" $((n / 1000000))
  elif (( n >= 1000 )); then
    printf "%dK" $((n / 1000))
  else
    printf "%d" "$n"
  fi
}

# Helper: format seconds → human duration
fmt_duration() {
  local s="$1"
  if (( s >= 86400 )); then
    printf "%dd%dh" $((s/86400)) $((s%86400/3600))
  elif (( s >= 3600 )); then
    printf "%dh%dm" $((s/3600)) $((s%3600/60))
  elif (( s >= 60 )); then
    printf "%dm%ds" $((s/60)) $((s%60))
  else
    printf "%ds" "$s"
  fi
}

# ── System stats cache ──────────────────────────────────────────────────────
# Read system stats from a cache file updated at most every 2 seconds.
# This avoids concurrent reads of /proc corrupting values.
SYS_CACHE="/tmp/.claude-sys-stats-$(id -u)"

update_sys_cache() {
  local tmp="${SYS_CACHE}.$$"
  local load cpus mu mp
  read -r load _ < /proc/loadavg 2>/dev/null || load="0"
  cpus=$(nproc 2>/dev/null || echo 1)
  read -r mu mp <<< "$(awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{
    printf "%.1f %d", (t-a)/1048576, int((t-a)*100/t)
  }' /proc/meminfo 2>/dev/null)"
  printf '%s %s %s %s\n' "${load:-0}" "${cpus:-1}" "${mu:-0}" "${mp:-0}" > "$tmp"
  mv -f "$tmp" "$SYS_CACHE"   # atomic rename — readers never see partial data
}

# Update cache if missing or older than 2 seconds
if [[ ! -f "$SYS_CACHE" ]]; then
  update_sys_cache
else
  cache_age=$(( $(date +%s) - $(stat -c %Y "$SYS_CACHE" 2>/dev/null || echo 0) ))
  (( cache_age >= 2 )) && update_sys_cache
fi

sys_load="" cpu_count="" mem_used="" mem_pct=""
read -r sys_load cpu_count mem_used mem_pct < "$SYS_CACHE" 2>/dev/null || true

# ── Build output ────────────────────────────────────────────────────────────
r=""

# 1. Directory (~/relative)
if [[ -n "$cwd" ]]; then
  short_cwd="${cwd/#$HOME/\~}"
  r+="${C_DIR}📂 ${short_cwd}${NC}"
fi

# 2. Git branch + uncommitted diff stats
if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  branch=$(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
  dirty=""
  diff_stat=""
  local_diff=$(git diff --shortstat HEAD 2>/dev/null || true)
  if [[ -n "$local_diff" ]]; then
    dirty="*"
    ga=$(echo "$local_diff" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "")
    gd=$(echo "$local_diff" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "")
    [[ -n "$ga" || -n "$gd" ]] && diff_stat=" ${C_ADD}+${ga:-0}${NC} ${C_RM}-${gd:-0}${NC}"
  fi
  r+="  ${C_GIT}⎇ ${branch}${dirty}${NC}${diff_stat}"
fi

# 3. Model
if [[ -n "$model" ]]; then
  short=$(echo "$model" | sed 's/ (\(.*\) context)//' | sed 's/[()]//g')
  r+="  ${C_MODEL}◆ ${short}${NC}"
fi

# 4. Context window
if [[ -n "$pct" && -n "$size" ]]; then
  ctx_color="$C_CTX"
  (( pct >= 80 )) && ctx_color="$C_WARN"
  r+="  ${ctx_color}⧖ ${pct}%${C_DIM}/${NC}${ctx_color}$(fmt_n "${size}")${NC}"
fi

# 5. Tokens + turns
if (( in_tok > 0 )); then
  r+="  ${C_TOK}in:$(fmt_n "$in_tok") out:$(fmt_n "$out_tok")"
  [[ -n "$turns" && "$turns" != "0" ]] && r+=" ${turns}t"
  r+="${NC}"
fi

# 6. Code lines (+added -removed) — cumulative for entire conversation
if [[ -n "$lines_add" || -n "$lines_rm" ]]; then
  add="${lines_add:-0}"
  rm="${lines_rm:-0}"
  if [[ "$add" != "0" || "$rm" != "0" ]]; then
    r+="  ${C_ADD}+${add}${NC} ${C_RM}-${rm}${NC}"
  fi
fi

# 7. Cost
if [[ -n "$cost" && "$cost" != "0" ]]; then
  cost_fmt=$(printf "%.2f" "$cost" 2>/dev/null || echo "$cost")
  r+="  ${C_DIM}\$${cost_fmt}${NC}"
fi

# 8. Session duration
elapsed=""
pid=$$
for _ in 1 2 3 4 5 6 7 8; do
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -z "$pid" || "$pid" == "1" ]] && break
  cmd=$(ps -o comm= -p "$pid" 2>/dev/null || true)
  if [[ "$cmd" == "claude" ]]; then
    et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n "$et" && "$et" != "0" ]] && elapsed="$et"
    break
  fi
done
[[ -n "$elapsed" ]] && r+="  ${C_TIME}⏱ $(fmt_duration $elapsed)${NC}"

# 9. Server load
if [[ -n "$sys_load" && "$sys_load" != "0" ]]; then
  load_color="$C_LOAD"
  load_int="${sys_load%%.*}"
  (( load_int >= cpu_count )) && load_color="$C_WARN"
  load_fmt=$(printf "%.1f" "$sys_load" 2>/dev/null || echo "$sys_load")
  r+="  ${load_color}☰${load_fmt}/${cpu_count}${NC}"
fi

# 10. Memory
if [[ -n "$mem_used" && "$mem_pct" =~ ^[0-9]+$ ]]; then
  mem_color="$C_MEM"
  (( mem_pct >= 80 )) && mem_color="$C_WARN"
  r+="  ${mem_color}◈ ${mem_used}G/${mem_pct}%${NC}"
fi

printf '%s\n' "$r"
