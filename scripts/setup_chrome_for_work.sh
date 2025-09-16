#!/bin/bash

CONFIG_DIR="$HOME/.config/switch-flow"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="$HOME/.local/share/switch-flow-state"
mkdir -p "$STATE_DIR" # Ensure state directory exists

LOG_FILE="$HOME/Library/Logs/SwitchFlow/setup_chrome_for_work.log"
echo "--- Script Start: $(date) ---" >>"$LOG_FILE"

# Load Chrome profile names from config file
personalProfile=$(jq -r '.profiles.personalProfile // empty' "$CONFIG_FILE")
workProfile=$(jq -r '.profiles.workProfile // empty' "$CONFIG_FILE")

echo "CONFIG_FILE: $CONFIG_FILE" >>"$LOG_FILE"
echo "personalProfile: $personalProfile" >>"$LOG_FILE"
echo "workProfile: $workProfile" >>"$LOG_FILE"

# Ensure profiles are set
if [[ -z "$personalProfile" || -z "$workProfile" ]]; then
  echo "ERROR: personalProfile or workProfile not defined in the 'profiles' section of $CONFIG_FILE." >&2
  exit 1
fi

# Read the JSON and open Chrome instances
CHROME_STARTUP_CONFIGS=$(jq -c '
  .window_focus | to_entries[] | .value[] | # Iterate through the hotkey arrays and then through each object in the hotkey array
  select(has("Google Chrome") and .startup != null) | # Select objects that have "Google Chrome" as a key and a startup sibling
  {name: .["Google Chrome"], url: .startup.url, folder: .startup.folder, profile_key: .startup.profile_key}
' "$CONFIG_FILE")

echo "Raw Chrome Startup Configs JSON: $CHROME_STARTUP_CONFIGS" >>"$LOG_FILE"

echo "$CHROME_STARTUP_CONFIGS" | while read -r i;
do
  name=$(echo "$i" | jq -r '.name // empty')
  url=$(echo "$i" | jq -r '.url // empty')
  folder=$(echo "$i" | jq -r '.folder // empty')
  profile_key=$(echo "$i" | jq -r '.profile_key // empty')

  profile_value=""
  if [[ "$profile_key" == "personalProfile" ]]; then
    profile_value="$personalProfile"
  elif [[ "$profile_key" == "workProfile" ]]; then
    profile_value="$workProfile"
  fi

  echo "Processing entry: name='$name', url='$url', profile_key='$profile_key', profile_value='$profile_value'" >>"$LOG_FILE"

  if [[ -z "$name" || -z "$profile_value" || ( "$url" == "null" && "$folder" == "null" ) ]]; then
    echo "Warning: Skipping an entry due to missing name, profile_value, or both url/folder. Condition: -z \"$name\" || -z \"$profile_value\" || ( \"$url\" == \"null\" && \"$folder\" == \"null\" )." >>"$LOG_FILE"
    continue
  fi

  OPEN_CHROME_ARGS="-n \"$name\" -p \"$profile_value\""
  if [[ "$url" != "null" && -n "$url" ]]; then
    OPEN_CHROME_ARGS+=" -u \"$url\""
  elif [[ "$folder" != "null" && -n "$folder" ]]; then
    OPEN_CHROME_ARGS+=" -f \"$folder\""
  fi

  COMMAND="\"$HOME/.local/switch-flow/scripts/open_chrome.sh\" $OPEN_CHROME_ARGS"
  echo "Executing command: $COMMAND" >>"$LOG_FILE"
  eval "\"$HOME/.local/switch-flow/scripts/open_chrome.sh\" $OPEN_CHROME_ARGS"
  EXIT_CODE=$?
  echo "Command exit code: $EXIT_CODE" >>"$LOG_FILE"
done

echo "--- Script End ---" >>"$LOG_FILE"
exit 0
