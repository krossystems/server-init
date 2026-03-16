#!/usr/bin/env bash
# ==============================================================================
# claude-status.sh — Show working animation on window name
#
# Triggered by PreToolUse / PostToolUse hooks.
# Alternates ⏳/⌛ to create a hourglass flip animation.
# Lightweight: just one tmux rename call per invocation.
# ==============================================================================

[[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]] && exit 0

# Parse event type from stdin
event=""
if ! [ -t 0 ]; then
  input=$(cat)
  if [[ -n "$input" ]] && command -v jq &>/dev/null; then
    event=$(echo "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
  fi
fi

# Pick marker based on event
if [[ "$event" == "PreToolUse" ]]; then
  marker="⏳"
else
  marker="⌛"
fi

# Get current window name for THIS pane
window_id=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null || true)
window_name=$(tmux display-message -t "$TMUX_PANE" -p '#{window_name}' 2>/dev/null || true)

[[ -z "$window_id" || -z "$window_name" ]] && exit 0

# Strip any existing status/notification marker
clean_name="${window_name#⏳}"
clean_name="${clean_name#⌛}"
clean_name="${clean_name#🟢}"
clean_name="${clean_name#🔔}"

[[ -z "$clean_name" ]] && exit 0

tmux rename-window -t "$window_id" "${marker}${clean_name}" 2>/dev/null || true
