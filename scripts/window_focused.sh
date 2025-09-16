#!/bin/bash

LOG_FILE="$HOME/Library/Logs/SwitchFlow/window_focused.log"

# This script is triggered by yabai's window_focused event.
# It can be used to perform actions when a window gains focus.

# Example: Log the focused window ID
echo "$(date): Focused window ID $YABAI_WINDOW_ID" >> "$LOG_FILE"

# You can add more logic here based on the focused window, e.g.,
# - Adjusting display settings
# - Triggering other scripts
# - Updating status bars

# To get details about the focused window:
# FOCUSED_WINDOW_INFO=$(yabai -m query --windows --window "$YABAI_WINDOW_ID")
# FOCUSED_APP=$(echo "$FOCUSED_WINDOW_INFO" | jq -r '.app')
# FOCUSED_TITLE=$(echo "$FOCUSED_WINDOW_INFO" | jq -r '.title')

# echo "Focused App: $FOCUSED_APP, Title: $FOCUSED_TITLE" >> "$LOG_FILE"