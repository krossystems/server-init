#!/usr/bin/env bash
# ==============================================================================
# clear-bell.sh — Remove notification marker from window name when it gains focus
#
# Clears 🟢 (completed) and 🔔 (needs input) prefixes.
#
# Called by Tmux's pane-focus-in hook:
#   set-hook -g pane-focus-in "run-shell '~/.claude/hooks/clear-bell.sh #{window_id} #{window_name}'"
# ==============================================================================

window_id="${1:-}"
window_name="${2:-}"

[[ -z "$window_id" || -z "$window_name" ]] && exit 0

clean_name="$window_name"
clean_name="${clean_name#🟢}"
clean_name="${clean_name#🔔}"
clean_name="${clean_name#🔄}"
clean_name="${clean_name#⏳}"
clean_name="${clean_name#⌛}"

if [[ "$clean_name" != "$window_name" ]]; then
  tmux rename-window -t "$window_id" "$clean_name" 2>/dev/null || true
fi
