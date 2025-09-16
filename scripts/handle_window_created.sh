#!/bin/bash

CONFIG_DIR="$HOME/.config/switch-flow"
CONFIG_FILE="$CONFIG_DIR/config.json"
CACHE_FILE="/tmp/yabai_windows_cache.json"
LOG_FILE="$HOME/Library/Logs/SwitchFlow/handle_window_created.log"

# Ensure the cache is refreshed first
"$HOME/.local/switch-flow/scripts/refresh_window_list.sh"

# Get the newly created window's ID from yabai's environment variable
NEW_WINDOW_ID="$YABAI_WINDOW_ID"

# Read app name from the freshly updated cache_file
NEW_WINDOW_APP=$(jq -r --arg id_val "$NEW_WINDOW_ID" '.[] | select(.id == ($id_val | tonumber // $id_val)) | .app' "$CACHE_FILE")

# Debugging output
echo "DEBUG (handle_window_created): YABAI_WINDOW_ID (from env)='$YABAI_WINDOW_ID'" >> "$LOG_FILE"
echo "DEBUG (handle_window_created): NEW_WINDOW_APP (from cache)='$NEW_WINDOW_APP'" >> "$LOG_FILE"
echo "DEBUG (handle_window_created): NEW_WINDOW_ID (used)='$NEW_WINDOW_ID'" >> "$LOG_FILE"

if [[ -n "$NEW_WINDOW_APP" ]] && [[ "$NEW_WINDOW_APP" != "null" ]]; then
  # Use a single jq query to find the window_placement action for the new app
  MATCHING_PLACEMENT_ACTION=$(jq -r \
    --arg new_app "$NEW_WINDOW_APP" \
    '.window_focus | map(.[]) | flatten | map(select(.[$new_app] != null and .window_placement != null)) | .[0].window_placement // empty' "$CONFIG_FILE" | head -n 1)

  echo "DEBUG (handle_window_created): MATCHING_PLACEMENT_ACTION=$MATCHING_PLACEMENT_ACTION" >> "$LOG_FILE"

  if [[ -n "$MATCHING_PLACEMENT_ACTION" ]] && [[ "$MATCHING_PLACEMENT_ACTION" != "null" ]]; then
    echo "Applying window placement for $NEW_WINDOW_APP (ID: $NEW_WINDOW_ID) with action: $MATCHING_PLACEMENT_ACTION" >> "$LOG_FILE"
    "$HOME/.local/switch-flow/scripts/move_and_position_windows.sh" "$MATCHING_PLACEMENT_ACTION" "$NEW_WINDOW_ID"
  fi
fi
