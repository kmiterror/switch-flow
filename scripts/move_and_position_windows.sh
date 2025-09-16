#!/bin/bash

LOG_FILE="$HOME/Library/Logs/SwitchFlow/move_and_position_windows.log"

# Get the grid pattern from the first argument
grid_pattern=$1

# Get the window ID from the second argument, or fallback to YABAI_WINDOW_ID
window_id="${2:-$YABAI_WINDOW_ID}"

# Check if window_id is still empty
if [[ -z "$window_id" ]]; then
  echo "Error: No window ID provided or found." >> "$LOG_FILE"
  exit 1
fi

# Apply the grid pattern to the window
yabai -m window "$window_id" --grid "$grid_pattern" >> "$LOG_FILE" 2>&1
