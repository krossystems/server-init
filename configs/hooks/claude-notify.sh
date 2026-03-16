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

# ── Check if current window is in the foreground ────────────────────────────
current_window=$(tmux display-message -p '#{window_id}' 2>/dev/null || true)
active_window=$(tmux display-message -p '#{active_window_id}' 2>/dev/null || true)

# Only notify if we are in the BACKGROUND
[[ "$current_window" == "$active_window" ]] && exit 0

# ── 1. Send Tmux bell (marks window in status bar) ─────────────────────────
printf '\a'

# ── 2. Add marker prefix to window name ────────────────────────────────────
window_name=$(tmux display-message -p '#{window_name}' 2>/dev/null || true)
# Strip any existing marker first, then add the new one
clean_name="${window_name#🟢}"
clean_name="${clean_name#🔔}"
if [[ -n "$clean_name" ]]; then
  tmux rename-window "${marker}${clean_name}" 2>/dev/null || true
fi

# ── 3. Send OSC notification via Tmux passthrough to Ghostty ────────────────
title="${marker} Claude [${event}]"
body="${message}"

# Tmux passthrough: \ePtmux;\e ... \e\\
printf '\ePtmux;\e\e]777;notify;%s;%s\a\e\\' "$title" "$body" 2>/dev/null || true
printf '\ePtmux;\e\e]9;%s: %s\a\e\\' "$title" "$body" 2>/dev/null || true
