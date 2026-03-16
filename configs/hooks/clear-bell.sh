#!/usr/bin/env bash
# ==============================================================================
# clear-bell.sh — Remove 🔔 prefix from window name when it gains focus
#
# Called by Tmux's pane-focus-in hook:
#   set-hook -g pane-focus-in "run-shell '~/.claude/hooks/clear-bell.sh #{window_id} #{window_name}'"
# ==============================================================================

window_id="${1:-}"
window_name="${2:-}"

[[ -z "$window_id" || -z "$window_name" ]] && exit 0

# Strip leading 🔔 (U+1F514, 4 bytes in UTF-8)
if [[ "$window_name" == "🔔"* ]]; then
  clean_name="${window_name#🔔}"
  tmux rename-window -t "$window_id" "$clean_name" 2>/dev/null || true
fi
