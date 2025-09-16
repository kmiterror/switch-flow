#!/bin/bash

# This script cycles focus through a list of windows defined in window_configs.json
# for a given hotkey. It uses yabai to query and focus windows.

CONFIG_DIR="$HOME/.config/switch-flow"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_BASE_DIR="$HOME/Library/Application Support/SwitchFlow"
mkdir -p "$STATE_BASE_DIR" # Ensure state directory exists
LOG_FILE="$HOME/Library/Logs/SwitchFlow/cycle_focus_window.log"
echo "Checking config file at: $CONFIG_FILE" >>"$LOG_FILE"
# Ensure config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Unified config file not found at $CONFIG_FILE." >&2
  echo "Please create and configure it based on config.json.example." >&2
  exit 1
fi

hotkey="$1"

if [[ -z "$hotkey" ]]; then
  echo "Usage: $0 <hotkey>"
  exit 1
fi

# Get the list of window configurations for the given hotkey from config.json
WINDOW_LIST_JSON=$(jq -r ".window_focus.\"$hotkey\" // empty" "$CONFIG_FILE")
echo "Executing jq command: jq -r ".window_focus.\"$hotkey\" // empty" "$CONFIG_FILE"" "Using config file: $CONFIG_FILE" >>"$LOG_FILE"
echo "WINDOW_LIST_JSON (raw from jq): $(jq -r ".window_focus.\"$hotkey\" // empty" "$CONFIG_FILE")" >>"$LOG_FILE"
echo "WINDOW_LIST_JSON: $WINDOW_LIST_JSON" >>"$LOG_FILE"

if [[ -z "$WINDOW_LIST_JSON" || "$WINDOW_LIST_JSON" == "null" ]]; then
  echo "No window configurations found for hotkey '$hotkey' in $CONFIG_FILE." >&2
  exit 0
fi

# Convert JSON array to bash array
WINDOW_CONFIGS=()
while IFS= read -r line; do
  WINDOW_CONFIGS+=("$line")
done < <(echo "$WINDOW_LIST_JSON" | jq -c '.[]')

STATE_FILE="$STATE_BASE_DIR/.cycle_state_${hotkey}"

# Calculate a hash of the current app list to detect changes
CURRENT_CONFIG_HASH=$(echo "$WINDOW_LIST_JSON" | shasum | awk '{print $1}')

# Read current state (last index and previous hash)
LAST_FOCUSED_INDEX=0
PREV_CONFIG_HASH=""

if [ -f "$STATE_FILE" ]; then
  STATE_CONTENT=$(cat "$STATE_FILE")
  LAST_FOCUSED_INDEX=$(echo "$STATE_CONTENT" | awk '{print $1}')
  PREV_CONFIG_HASH=$(echo "$STATE_CONTENT" | awk '{print $2}')

  # Validate LAST_FOCUSED_INDEX is a number and within bounds
  if ! [[ "$LAST_FOCUSED_INDEX" =~ ^[0-9]+$ ]] || [ "$LAST_FOCUSED_INDEX" -ge "${#WINDOW_CONFIGS[@]}" ]; then
    LAST_FOCUSED_INDEX=0
  fi
fi

# Reset index if app list has changed
if [ "$CURRENT_CONFIG_HASH" != "$PREV_CONFIG_HASH" ]; then
  LAST_FOCUSED_INDEX=0
fi

CURRENT_FOCUSED_APP=""
CURRENT_FOCUSED_TITLE=""

# Get currently focused window details from cache
# Check if yabai is installed and available (for current window ID)
if command -v yabai &>/dev/null; then
  CURRENT_WINDOW_ID=$(yabai -m query --windows --window | jq -r '.id')
  if [ -n "$CURRENT_WINDOW_ID" ] && [ "$CURRENT_WINDOW_ID" != "null" ]; then
    # The current script doesn't use a global cache, so we need to query for the focused window details directly
    YABAI_OUTPUT=$(yabai -m query --windows | jq --arg id_val "$CURRENT_WINDOW_ID" '.[] | select(.id == ($id_val | tonumber // $id_val))')
    if [ -n "$YABAI_OUTPUT" ] && [ "$YABAI_OUTPUT" != "null" ]; then
      CURRENT_FOCUSED_APP=$(echo "$YABAI_OUTPUT" | jq -r '.app')
      CURRENT_FOCUSED_TITLE=$(echo "$YABAI_OUTPUT" | jq -r '.title')
    fi
  fi
fi

# Determine the starting point for cycling
INITIAL_TARGET_INDEX="$LAST_FOCUSED_INDEX" # Default to last focused

MATCHING_CURRENT_WINDOW_INDEX=-1
for i in "${!WINDOW_CONFIGS[@]}"; do
  APP_CONFIG_JSON_IN_LIST="${WINDOW_CONFIGS[$i]}"
  APP_NAME_IN_LIST=$(echo "$APP_CONFIG_JSON_IN_LIST" | jq -r 'keys[0]')
  WINDOW_TITLE_PATTERN_IN_LIST=$(echo "$APP_CONFIG_JSON_IN_LIST" | jq -r --arg app_name_arg "$APP_NAME_IN_LIST" '.[$app_name_arg]')

  if [ "$APP_NAME_IN_LIST" == "$CURRENT_FOCUSED_APP" ]; then
    if [ -z "$WINDOW_TITLE_PATTERN_IN_LIST" ] || [ "$WINDOW_TITLE_PATTERN_IN_LIST" == "null" ]; then
      MATCHING_CURRENT_WINDOW_INDEX="$i"
      break
    elif [[ "$CURRENT_FOCUSED_TITLE" == *"$WINDOW_TITLE_PATTERN_IN_LIST"* ]]; then
      MATCHING_CURRENT_WINDOW_INDEX="$i"
      break
    fi
  fi
done

if [ "$MATCHING_CURRENT_WINDOW_INDEX" -ne -1 ]; then
  # Currently focused window is in the list
  if [ "$MATCHING_CURRENT_WINDOW_INDEX" -eq "$LAST_FOCUSED_INDEX" ]; then
    # User is pressing the hotkey again on the same app that was last focused by this hotkey
    INITIAL_TARGET_INDEX=$(((LAST_FOCUSED_INDEX + 1) % ${#WINDOW_CONFIGS[@]}))
  else
    # User switched to this app manually or with another hotkey, so we just focus this one
    INITIAL_TARGET_INDEX="$MATCHING_CURRENT_WINDOW_INDEX"
  fi
else
  # Currently focused window is NOT in the list, go back to the last focused by this hotkey
  INITIAL_TARGET_INDEX="$LAST_FOCUSED_INDEX"
fi

SCRIPTS_BIN_DIR="$HOME/.local/switch-flow/scripts"
FOCUSED_SUCCESSFULLY=false
CURRENT_ATTEMPT_INDEX="$INITIAL_TARGET_INDEX"

# Loop through applications, starting from the determined initial target index
for ((k = 0; k < ${#WINDOW_CONFIGS[@]}; k++)); do
  APP_CONFIG_JSON="${WINDOW_CONFIGS[$CURRENT_ATTEMPT_INDEX]}"
  echo "DEBUG: APP_CONFIG_JSON=$APP_CONFIG_JSON" >>"$LOG_FILE"

  APP_NAME=$(echo "$APP_CONFIG_JSON" | jq -r 'keys[0]')
  echo "DEBUG: APP_NAME=$APP_NAME" >>"$LOG_FILE"
  WINDOW_TITLE_PATTERN=$(echo "$APP_CONFIG_JSON" | jq -r --arg app_name_arg "$APP_NAME" '.[$app_name_arg]')
  echo "DEBUG: WINDOW_TITLE_PATTERN=$WINDOW_TITLE_PATTERN" >>"$LOG_FILE"

  echo "Attempting to focus: APP_NAME=$APP_NAME, WINDOW_TITLE_PATTERN=$WINDOW_TITLE_PATTERN (Index: $CURRENT_ATTEMPT_INDEX)" >>"$LOG_FILE"

  set +e # Temporarily disable exit on error
  if [ -z "$WINDOW_TITLE_PATTERN" ] || [ "$WINDOW_TITLE_PATTERN" == "null" ]; then
    "$SCRIPTS_BIN_DIR/focus_specific_window.sh" "$APP_NAME" "" "$hotkey"
  else
    "$SCRIPTS_BIN_DIR/focus_specific_window.sh" "$APP_NAME" "$WINDOW_TITLE_PATTERN" "$hotkey"
  fi
  EXIT_CODE=$?
  set -e # Re-enable exit on error

  if [ $EXIT_CODE -eq 0 ]; then
    echo "Successfully focused window for $APP_NAME (Index: $CURRENT_ATTEMPT_INDEX)" >>"$LOG_FILE"
    # Save the new state only if focusing was successful
    echo "$CURRENT_ATTEMPT_INDEX $CURRENT_CONFIG_HASH" >"$STATE_FILE"
    FOCUSED_SUCCESSFULLY=true
    break # Exit loop on successful focus
  else
    echo "Failed to focus window for $APP_NAME (Index: $CURRENT_ATTEMPT_INDEX), trying next..." >>"$LOG_FILE"
    CURRENT_ATTEMPT_INDEX=$(((CURRENT_ATTEMPT_INDEX + 1) % ${#WINDOW_CONFIGS[@]}))
  fi
done

if [ "$FOCUSED_SUCCESSFULLY" == "false" ]; then
  echo "No configured application could be focused after trying all options." >&2
  exit 1
fi

exit 0
