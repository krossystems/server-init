#!/usr/bin/env bash
# ==============================================================================
# cleanup-sessions.sh — Automatically clean up stale Tmux sessions
#
# Intended to run via cron (every 6 hours).
#
# Rules:
#   - "main" is never cleaned up
#   - "tmp-*" sessions unattached for > 7 days → killed
#   - Other sessions unattached for > 30 days → killed
# ==============================================================================

set -uo pipefail

# Exit silently if tmux is not installed or no server running
command -v tmux &>/dev/null || exit 0
tmux list-sessions &>/dev/null || exit 0

NOW=$(date +%s)
KILLED=0

while IFS= read -r line; do
  # Format: "session_name: N windows (created DAY MON DD HH:MM:SS YYYY) [WxH]"
  session_name=$(echo "$line" | cut -d: -f1)

  # Never touch "main"
  [[ "$session_name" == "main" ]] && continue

  # Skip attached sessions
  echo "$line" | grep -q "(attached)" && continue

  # Extract creation time from tmux
  created_epoch=$(tmux display-message -t "$session_name" -p '#{session_created}' 2>/dev/null || echo "0")
  # Last activity (last time any client was attached or a key was pressed)
  activity_epoch=$(tmux display-message -t "$session_name" -p '#{session_activity}' 2>/dev/null || echo "$created_epoch")

  # Use the more recent of created vs activity
  last_active="$activity_epoch"
  (( created_epoch > last_active )) && last_active="$created_epoch"

  age_days=$(( (NOW - last_active) / 86400 ))

  # tmp-* sessions: 7 day threshold
  if [[ "$session_name" == tmp-* ]] && (( age_days >= 7 )); then
    echo "[cleanup] Killing tmp session '$session_name' (idle ${age_days}d)"
    tmux kill-session -t "$session_name" 2>/dev/null && (( KILLED++ ))
    continue
  fi

  # Regular sessions: 30 day threshold
  if (( age_days >= 30 )); then
    echo "[cleanup] Killing session '$session_name' (idle ${age_days}d)"
    tmux kill-session -t "$session_name" 2>/dev/null && (( KILLED++ ))
  fi

done < <(tmux list-sessions 2>/dev/null)

(( KILLED > 0 )) && echo "[cleanup] Removed $KILLED stale session(s)."
exit 0
