#!/usr/bin/env bash
# ==============================================================================
# claude-notify.sh — Notify via Tmux bell + OSC when Claude Code stops/needs input
#
# Triggered by Claude Code hooks (Stop / Notification).
# Only fires when the Tmux window is NOT in the foreground.
#
# Markers:
#   🟢 = Stop (task completed, no action needed)
#   🔔 = Notification (needs your input/decision)
#
# Reads hook JSON from stdin:
#   { "hook_event_name": "Stop", "message": "...", ... }
# ==============================================================================

set -uo pipefail

# ── Must be inside Tmux ─────────────────────────────────────────────────────
[[ -z "${TMUX:-}" ]] && exit 0

# ── Parse stdin JSON ────────────────────────────────────────────────────────
input=""
if ! [ -t 0 ]; then
  input=$(cat)
fi

event=""
message=""
if [[ -n "$input" ]] && command -v jq &>/dev/null; then
  event=$(echo "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
  message=$(echo "$input" | jq -r '.message // empty' 2>/dev/null || true)
fi

# Fallback labels
[[ -z "$event" ]] && event="Claude"
[[ -z "$message" ]] && message="Task finished"

# ── Choose marker based on event type ────────────────────────────────────────
marker="🟢"   # Stop — task completed
if [[ "$event" == "Notification" ]]; then
  marker="🔔"  # Notification — needs your decision
fi

# ── Identify which window THIS hook is running in ───────────────────────────
# $TMUX_PANE is set by tmux for every process inside a pane (e.g. %5)
# We use it to find the window that owns this pane.
if [[ -z "${TMUX_PANE:-}" ]]; then
  exit 0
fi

# Get the window ID and name for the pane where Claude Code is running
my_window_id=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null || true)
my_window_name=$(tmux display-message -t "$TMUX_PANE" -p '#{window_name}' 2>/dev/null || true)

[[ -z "$my_window_id" ]] && exit 0

# ── Check if this window is in the foreground ───────────────────────────────
active_window_id=$(tmux display-message -p '#{active_window_id}' 2>/dev/null || true)

# Only notify if we are in the BACKGROUND
[[ "$my_window_id" == "$active_window_id" ]] && exit 0

# ── 1. Send Tmux bell in the correct pane ───────────────────────────────────
tmux send-keys -t "$TMUX_PANE" "" 2>/dev/null || true
printf '\a'

# ── 2. Add marker prefix to window name ────────────────────────────────────
# Strip any existing marker first, then add the new one
clean_name="${my_window_name#🟢}"
clean_name="${clean_name#🔔}"
if [[ -n "$clean_name" ]]; then
  tmux rename-window -t "$my_window_id" "${marker}${clean_name}" 2>/dev/null || true
fi

# ── 3. Send OSC notification via Tmux passthrough to Ghostty ────────────────
title="${marker} Claude [${event}]"
body="${message}"

printf '\ePtmux;\e\e]777;notify;%s;%s\a\e\\' "$title" "$body" 2>/dev/null || true
printf '\ePtmux;\e\e]9;%s: %s\a\e\\' "$title" "$body" 2>/dev/null || true
