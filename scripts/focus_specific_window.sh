#!/bin/bash

CONFIG_DIR="$HOME/.config/switch-flow"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="$HOME/Library/Application Support/SwitchFlow"
mkdir -p "$STATE_DIR" # Ensure state directory exists

LOG_FILE="$HOME/Library/Logs/SwitchFlow/focus_window_script.log"
echo "--- Script Start: $(date) --- Args: $1 $2 ---" >>"$LOG_FILE"

# Function to toggle grayscale using the new AppleScript-based script
toggle_grayscale_filter() {
  local enable="$1" # "true" to enable grayscale, "false" to disable
  if [[ "$enable" == "true" ]]; then
    "$HOME/.local/switch-flow/scripts/set_grayscale_state.sh" "true" >/dev/null 2>&1
    echo "Grayscale: ON" >>"$LOG_FILE"
  else
    "$HOME/.local/switch-flow/scripts/set_grayscale_state.sh" "false" >/dev/null 2>&1
    echo "Grayscale: OFF" >>"$LOG_FILE"
  fi
}

# Cache and lock file paths
cache_file="/tmp/yabai_windows_cache.json" # This is still a global temp file, as yabai updates it.
focused_window_path="$STATE_DIR/yabai_focused_window"
SELECTION_FILE="$STATE_DIR/tmux_selected_name"                                # Stores the active context name like "wehiko"
ACTIVE_CONTEXT_STATE_FILE="$STATE_DIR/tmux_context_active_for_wezterm_switch" # Stores "true" or "false"

# Read from the cached data
if [[ ! -f "$cache_file" ]]; then
  echo "ERROR: Cache file $cache_file not found!" >>"$LOG_FILE"
  exit 1
fi
all_windows=$(cat "$cache_file")
if [[ -z "$all_windows" ]]; then
  echo "WARNING: Cache file $cache_file is empty." >>"$LOG_FILE"
fi

# Define the whitelist for contexts from config file
whitelist=()
if [[ -f "$CONFIG_DIR/whitelist.conf" ]]; then
  while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "${line#}" =~ ^# ]] && continue
    whitelist+=("$line")
  done <"$CONFIG_DIR/whitelist.conf"
fi

# Arguments
app_name="$1" # The application to target for focus
original_window_title_prefix_arg="$2"
hotkey_arg="$3" # The hotkey that triggered this script

# Get current focused window ID, App, and Title (window focused BEFORE this script acts)
current_window_id=""
current_window_app="" # App of the window focused *before* this script runs
current_window_title=""

_focused_id_from_file=""
if [[ -s "$focused_window_path" ]]; then
  _focused_id_from_file=$(cat "$focused_window_path")
fi

if [[ -n "$_focused_id_from_file" ]]; then
  _focused_win_details_json=$(echo "$all_windows" | jq --arg id_val "$_focused_id_from_file" '.[] | select(.id == ($id_val | tonumber // $id_val)) | {id: .id, app: .app, title: .title}')
  if [[ -n "$_focused_win_details_json" ]] && [[ "$_focused_win_details_json" != "null" ]]; then
    current_window_id="$_focused_id_from_file"
    current_window_app=$(echo "$_focused_win_details_json" | jq -r '.app')
    current_window_title=$(echo "$_focused_win_details_json" | jq -r '.title')
    echo "Current Focused Window (ID from $focused_window_path: $current_window_id): App='$current_window_app', Title='$current_window_title'" >>"$LOG_FILE"
  else
    echo "Warning: Could not find details for ID '$_focused_id_from_file' (from $focused_window_path) in cache." >>"$LOG_FILE"
  fi
else
  echo "Warning: $focused_window_path empty or not found." >>"$LOG_FILE"
fi

# --- Initialize accumulators for tmux/context actions for this script run ---
_new_selection_file_content=""      # Candidate for SELECTION_FILE
_new_active_state_content=""        # Candidate for ACTIVE_CONTEXT_STATE_FILE ("true" or "false")
_final_tmux_session_to_switch_to="" # Target tmux session for *this* run, if any

# --- Determine target prefix and initial context based on arguments ---
target_specific_prefix="$original_window_title_prefix_arg"
derived_context_from_prefix_arg="" # Context like "wehiko" if prefix is context-aware

is_context_aware_prefix_arg=false
if [[ "$original_window_title_prefix_arg" =~ -""$ ]]; then
  is_context_aware_prefix_arg=true
fi
echo "is_context_aware_prefix_arg: $is_context_aware_prefix_arg" >>"$LOG_FILE"

if $is_context_aware_prefix_arg; then
  echo "Prefix '$original_window_title_prefix_arg' IS context-aware." >>"$LOG_FILE"
  selected_name_from_file=""
  if [[ -f "$SELECTION_FILE" ]]; then
    selected_name_from_file=$(cat "$SELECTION_FILE")
    echo "Read '$selected_name_from_file' from $SELECTION_FILE for prefix logic." >>"$LOG_FILE"
  fi

  found_in_whitelist=false
  if [[ -n "$selected_name_from_file" ]]; then
    for allowed in "${whitelist[@]}"; do
      if [[ "$selected_name_from_file" == "$allowed" ]]; then
        target_specific_prefix="${original_window_title_prefix_arg}${selected_name_from_file}"
        derived_context_from_prefix_arg="$selected_name_from_file"
        found_in_whitelist=true
        break
      fi
    done
  fi

  if ! $found_in_whitelist; then
    if [ ${#whitelist[@]} -gt 0 ]; then
      echo "Warning: Selected name '$selected_name_from_file' from $SELECTION_FILE not in whitelist or file empty/not found. Defaulting to first context '${whitelist[0]}'." >>"$LOG_FILE"
      target_specific_prefix="${original_window_title_prefix_arg}${whitelist[0]}"
      derived_context_from_prefix_arg="${whitelist[0]}"
    else
      echo "Warning: Whitelist empty, cannot default context for loose prefix. Using prefix as-is." >>"$LOG_FILE"
      # target_specific_prefix remains original_window_title_prefix_arg
      derived_context_from_prefix_arg="" # No valid context
    fi
  fi

  if [[ -n "$derived_context_from_prefix_arg" ]]; then
    _new_selection_file_content="$derived_context_from_prefix_arg"
    _new_active_state_content="true"
    echo "TMUX_CONTEXT_PREP (Context-Aware Prefix): SELECTION_FILE candidate '$_new_selection_file_content', ACTIVE_STATE candidate 'true'" >>"$LOG_FILE"
  fi
else # Prefix is NOT context-aware (or no prefix)
  echo "Prefix '$original_window_title_prefix_arg' is NOT context-aware." >>"$LOG_FILE"
  if [[ "$app_name" != "WezTerm" ]] && [[ -n "$original_window_title_prefix_arg" ]]; then
    # This is a non-WezTerm app with a specific non-context-aware title, e.g., "Google Chrome" "personal"
    # This action should make the global context "inactive" for subsequent generic WezTerm switches.
    _new_active_state_content="false"
    echo "TMUX_CONTEXT_PREP (Non-Context-Aware Specific Window): ACTIVE_STATE candidate 'false'" >>"$LOG_FILE"
  fi
fi
echo "Initial derived_context_from_prefix_arg: '$derived_context_from_prefix_arg'" >>"$LOG_FILE"
echo "target_specific_prefix set to: '$target_specific_prefix'" >>"$LOG_FILE"

if [[ -z "$app_name" ]]; then
  echo "Usage: $0 <app_name> [<window_title_prefix> optional]" >>"$LOG_FILE"
  exit 1
fi

unique_id_suffix="$original_window_title_prefix_arg" # Use original for cycle groups
unique_id=$(echo "$app_name|$unique_id_suffix" | md5sum | awk '{print $1}')
LAST_FOCUS_FILE="$STATE_DIR/last_focused_window_$unique_id.txt"
echo "Target appName: $app_name, cyclePrefix: $original_window_title_prefix_arg, effectiveSearchPrefix: $target_specific_prefix, LAST_FOCUS_FILE: $LAST_FOCUS_FILE" >>"$LOG_FILE"

last_focused_window_id=""
if [[ -f "$LAST_FOCUS_FILE" ]]; then last_focused_window_id=$(<"$LAST_FOCUS_FILE"); fi
echo "Read last_focused_window_id: '$last_focused_window_id' from $LAST_FOCUS_FILE" >>"$LOG_FILE"

start_time=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')

app_windows_count=$(echo "$all_windows" | jq --arg app_name "$app_name" '[.[] | select(.app == $app_name)] | length')
# Ensure config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Unified config file not found at $CONFIG_FILE." >>"$LOG_FILE"
  echo "Please create and configure it based on config.json.example." >>"$LOG_FILE"
  exit 1
fi

# Read the entire config file
CONFIG_CONTENT=$(cat "$CONFIG_FILE")

# Get profiles and window_focus for startup logic
PROFILES_JSON=$(echo "$CONFIG_CONTENT" | jq -r ".profiles // {}")
WINDOW_FOCUS_JSON=$(echo "$CONFIG_CONTENT" | jq -r ".window_focus // {}")

if [[ "$app_windows_count" -eq 0 ]]; then
  echo "$app_name not running or no windows, attempting to open..." >>"$LOG_FILE"

  # Check for startup configuration in window_focus
  STARTUP_CONFIG=$(
    echo "$WINDOW_FOCUS_JSON" | jq -r \
      --arg app "$app_name" \
      --arg identifier "$original_window_title_prefix_arg" \
      '
    .[] | # Iterate through the hotkey arrays
    .[] | # Iterate through each object in the hotkey array
    select(has($app) and .[$app] == $identifier) | # Select the object where app_name matches key and its value matches identifier
    .startup // empty # Extract startup, or empty string if not present
    '
  )

  # If the above didn't find it, try matching just the app name if identifier is empty
  if [[ -z "$STARTUP_CONFIG" && -z "$original_window_title_prefix_arg" ]]; then
    STARTUP_CONFIG=$(
      echo "$WINDOW_FOCUS_JSON" | jq -r \
        --arg app "$app_name" \
        '
      .[] | # Iterate through the hotkey arrays
      .[] | # Iterate through each object in the hotkey array
      select(has($app) and .startup != null) | # Select objects that have app_name as a key and a startup sibling
      .startup // empty # Extract startup, or empty string if not present
      '
    )
  fi

  if [[ -n "$STARTUP_CONFIG" && "$app_name" == "Google Chrome" ]]; then
    URL=$(echo "$STARTUP_CONFIG" | jq -r '.url // empty')
    PROFILE_KEY=$(echo "$STARTUP_CONFIG" | jq -r '.profile_key // empty')
    CHROME_PROFILE=""

    if [[ -n "$PROFILE_KEY" ]]; then
      CHROME_PROFILE=$(echo "$PROFILES_JSON" | jq -r ".profiles[\"$PROFILE_KEY\"] // empty")
    fi

    if [[ -n "$URL" && -n "$CHROME_PROFILE" ]]; then
      echo "Opening Chrome with URL: $URL and profile: $CHROME_PROFILE" >>"$LOG_FILE"
      open -na "Google Chrome" --args --profile-directory="$CHROME_PROFILE" "$URL"
    elif [[ -n "$URL" ]]; then
      echo "Opening Chrome with URL: $URL (no specific profile)" >>"$LOG_FILE"
      open -na "Google Chrome" --args "$URL"
    else
      echo "Startup config found for Chrome but missing URL or profile. Falling back to generic open." >>"$LOG_FILE"
      open -a "$app_name"
    fi
  else
    open -a "$app_name"
  fi

  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to open application '$app_name'." >>"$LOG_FILE"
    exit 1
  fi
  # If open was successful, we assume the app will eventually appear and exit successfully for now.
  # A subsequent cycle will pick it up.
  exit 0
fi

# Windows to cycle should use the original_window_title_prefix_arg for grouping,
# but focusing might use the target_specific_prefix for initial selection.
if [[ -n "$original_window_title_prefix_arg" ]]; then
  windows_to_cycle=($(echo "$all_windows" | jq -r --arg app "$app_name" --arg prefix "$original_window_title_prefix_arg" \
    '.[] | select(.app == $app and (.title // "" | tostring | contains($prefix))) | .id' | sort -n))
else # No prefix means cycle all windows of the app

  windows_to_cycle=($(echo "$all_windows" | jq -r --arg app "$app_name" \
    '.[] | select(.app == $app) | .id' | sort -n))
fi
echo "Windows to cycle for '$app_name' with original prefix '$original_window_title_prefix_arg' (${#windows_to_cycle[@]}): ${windows_to_cycle[*]}" >>"$LOG_FILE"

if [[ ${#windows_to_cycle[@]} -eq 0 ]]; then
  echo "ERROR: No window for app: $app_name, original prefix: ${original_window_title_prefix_arg:-<any>}." >>"$LOG_FILE"
  exit 1
fi

valid_last_focused_id=""
last_focused_window_title=""
if [[ -n "$last_focused_window_id" ]]; then
  last_focused_window_json=$(echo "$all_windows" | jq --argjson id "$last_focused_window_id" '.[] | select(.id == ($id | tonumber // $id))')
  if [[ -n "$last_focused_window_json" ]] && [[ "$last_focused_window_json" != "null" ]]; then
    last_focused_window_app=$(echo "$last_focused_window_json" | jq -r '.app')
    fetched_title=$(echo "$last_focused_window_json" | jq -r '.title')
    # Check if last focused belongs to the current cycle group
    if [[ "$last_focused_window_app" == "$app_name" ]] &&
      ([[ -z "$original_window_title_prefix_arg" ]] || [[ "$fetched_title" == *"$original_window_title_prefix_arg"* ]]); then
      valid_last_focused_id="$last_focused_window_id"
      last_focused_window_title="$fetched_title"
      echo "Validated last_focused_window_id: $valid_last_focused_id ('$last_focused_window_title')" >>"$LOG_FILE"
    else
      echo "Invalidated last_focused_window_id '$last_focused_window_id': app/title mismatch for cycle group. App: '$last_focused_window_app', Title: '$fetched_title'." >>"$LOG_FILE"
      last_focused_window_id="" # Clear it so it's not used for P2/P3 initial focus if invalid for cycle group
    fi
  else
    echo "Invalidated last_focused_window_id '$last_focused_window_id': not in all_windows." >>"$LOG_FILE"
    last_focused_window_id=""
  fi
fi

next_window_to_focus=""
current_window_is_in_cycle=false
if [[ -n "$current_window_id" ]] && [[ "$current_window_app" == "$app_name" ]]; then
  for win_id in "${windows_to_cycle[@]}"; do if [[ "$win_id" == "$current_window_id" ]]; then
    current_window_is_in_cycle=true
    break
  fi; done
fi
echo "current_window_is_in_cycle (for $app_name, original_prefix '$original_window_title_prefix_arg'): $current_window_is_in_cycle" >>"$LOG_FILE"

if [[ "$current_window_is_in_cycle" == true ]]; then
  echo "--- CYCLING LOGIC for $app_name --- " >>"$LOG_FILE"
  found_current_in_cycle=false
  for i in "${!windows_to_cycle[@]}"; do
    if [[ "${windows_to_cycle[$i]}" == "$current_window_id" ]]; then
      next_index=$(((i + 1) % ${#windows_to_cycle[@]}))
      next_window_to_focus=${windows_to_cycle[$next_index]}
      found_current_in_cycle=true
      echo "Cycling: Current $current_window_id ('$current_window_title') in cycle. Next is $next_window_to_focus." >>"$LOG_FILE"

      if $is_context_aware_prefix_arg; then # Only update context if original prefix was context-aware
        echo "CONTEXT UPDATE (Window Cycle): Prefix '$original_window_title_prefix_arg' is context-aware." >>"$LOG_FILE"
        next_window_title_to_focus_val=$(echo "$all_windows" | jq -r --argjson id "$next_window_to_focus" '.[] | select(.id == ($id | tonumber // $id)) | .title')
        current_selected_context_from_file=""
        if [[ -f "$SELECTION_FILE" ]]; then current_selected_context_from_file=$(cat "$SELECTION_FILE"); fi
        echo "CONTEXT UPDATE (Window Cycle): Next title '$next_window_title_to_focus_val'. Current SELECTION_FILE: '$current_selected_context_from_file'." >>"$LOG_FILE"

        _found_ctx_update=false
        for allowed_ctx in "${whitelist[@]}"; do
          expected_title_start="${original_window_title_prefix_arg}${allowed_ctx}" # e.g. "docs-wehiko"
          if [[ "$next_window_title_to_focus_val" == "$expected_title_start"* ]]; then
            potential_new_context="$allowed_ctx"
            echo "CONTEXT UPDATE (Window Cycle): Matched! potential_new_context '$potential_new_context'." >>"$LOG_FILE"
            if [[ "$potential_new_context" != "$current_selected_context_from_file" ]]; then
              _new_selection_file_content="$potential_new_context"     # Update candidate
              _new_active_state_content="true"                         # This action makes context active
              derived_context_from_prefix_arg="$potential_new_context" # Update for this run
              echo "TMUX_CONTEXT_PREP (Window Cycle Update): SELECTION_FILE candidate '$_new_selection_file_content', ACTIVE_STATE candidate 'true'" >>"$LOG_FILE"
            elif [[ "$_new_active_state_content" != "true" ]]; then
              # If context matches but was not active, make it active
              _new_active_state_content="true"
              echo "TMUX_CONTEXT_PREP (Window Cycle Affirm Active): ACTIVE_STATE candidate 'true'" >>"$LOG_FILE"
            fi
            _found_ctx_update=true
            break
          fi
        done
        if ! $_found_ctx_update; then echo "CONTEXT UPDATE (Window Cycle): No context derived from next title. Active state may remain as per initial prefix logic." >>"$LOG_FILE"; fi
      fi # end if is_context_aware_prefix_arg for CONTEXT UPDATE
      break
    fi                               # end if current window found in cycle
  done                               # end for loop windows_to_cycle
  if ! $found_current_in_cycle; then # Should not happen if current_window_is_in_cycle is true
    next_window_to_focus=${windows_to_cycle[0]}
    echo "Cycling fallback (current window not found in its own cycle list - unexpected). Focusing first in list." >>"$LOG_FILE"
  fi
else # Not cycling, this is an initial focus for this app/prefix group
  echo "--- INITIAL FOCUS LOGIC for $app_name --- " >>"$LOG_FILE"
  # P1: Try to find a window matching the target_specific_prefix (which might be context-resolved like "docs-wehiko")
  if [[ -n "$target_specific_prefix" ]] && [[ "$target_specific_prefix" != "$original_window_title_prefix_arg" || $is_context_aware_prefix_arg ]]; then # Search if prefix was resolved or is context aware (even if default)
    for win_id_candidate in "${windows_to_cycle[@]}"; do
      candidate_title=$(echo "$all_windows" | jq -r --argjson id "$win_id_candidate" '.[] | select(.id == ($id | tonumber // $id)) | .title')
      if [[ "$candidate_title" == *"$target_specific_prefix"* ]]; then
        next_window_to_focus="$win_id_candidate"
        echo "P1: Found window '$candidate_title' (ID $next_window_to_focus) matching target_specific_prefix '$target_specific_prefix'." >>"$LOG_FILE"
        break
      fi
    done
  fi

  # P2: If P1 failed, and if last_focused_window_id is valid for this cycle group AND its title matches target_specific_prefix
  if [[ -z "$next_window_to_focus" ]] && [[ -n "$last_focused_window_id" ]] && [[ -n "$last_focused_window_title" ]]; then
    if [[ -n "$target_specific_prefix" ]] && [[ "$last_focused_window_title" == *"$target_specific_prefix"* ]]; then
      # Check if last_focused_window_id is actually in windows_to_cycle
      for win_id_check in "${windows_to_cycle[@]}"; do
        if [[ "$win_id_check" == "$last_focused_window_id" ]]; then
          next_window_to_focus="$last_focused_id"
          echo "P2: Using last focused window ID $last_focused_window_id ('$last_focused_window_title') as it matches target_specific_prefix '$target_specific_prefix' and is in cycle group." >>"$LOG_FILE"
          break
        fi
      done
    fi
  fi

  # P3: If P1/P2 failed, and if last_focused_window_id is valid for this cycle group AND its title matches original_window_title_prefix_arg (less specific)
  if [[ -z "$next_window_to_focus" ]] && [[ -n "$last_focused_window_id" ]] && [[ -n "$last_focused_window_title" ]]; then
    if [[ -n "$original_window_title_prefix_arg" ]] && [[ "$last_focused_window_title" == *"$original_window_title_prefix_arg"* ]]; then
      for win_id_check in "${windows_to_cycle[@]}"; do
        if [[ "$win_id_check" == "$last_focused_window_id" ]]; then
          next_window_to_focus="$last_focused_window_id"
          echo "P3: Using last focused window ID $last_focused_window_id ('$last_focused_window_title') as it matches original_window_title_prefix_arg '$original_window_title_prefix_arg' and is in cycle group." >>"$LOG_FILE"
          break
        fi
      done
    fi
  fi

  # P4: Fallback to the first window in the cycle list that matches target_specific_prefix (if not already chosen by P1 which is similar)
  if [[ -z "$next_window_to_focus" ]] && [[ -n "$target_specific_prefix" ]] && [[ "$target_specific_prefix" != "$original_window_title_prefix_arg" || $is_context_aware_prefix_arg ]]; then
    for win_id_candidate in "${windows_to_cycle[@]}"; do # Redundant with P1 but as a fallback
      candidate_title=$(echo "$all_windows" | jq -r --argjson id "$win_id_candidate" '.[] | select(.id == ($id | tonumber // $id)) | .title')
      if [[ "$candidate_title" == *"$target_specific_prefix"* ]]; then
        next_window_to_focus="$win_id_candidate"
        echo "P4: Found first window '$candidate_title' (ID $next_window_to_focus) in cycle list matching target_specific_prefix '$target_specific_prefix'." >>"$LOG_FILE"
        break
      fi
    done
  fi

  # P5: Final fallback: first window in the cycle list for the original prefix.
  if [[ -z "$next_window_to_focus" ]] && [[ ${#windows_to_cycle[@]} -gt 0 ]]; then
    next_window_to_focus=${windows_to_cycle[0]}
    first_win_title=$(echo "$all_windows" | jq -r --argjson id "$next_window_to_focus" '.[] | select(.id == ($id|tonumber//$id)) | .title')
    echo "P5: Using first window ID $next_window_to_focus ('$first_win_title') from the cycle list for original prefix '$original_window_title_prefix_arg'." >>"$LOG_FILE"
  fi
fi # End of current_window_is_in_cycle / initial focus logic

# --- TMUX Operations ---
if [[ -n "$next_window_to_focus" ]]; then # Proceed only if a window was determined

  # Case A: WezTerm call with a context-aware prefix (e.g., focus_specific_window.sh "WezTerm" "projectname-")
  # derived_context_from_prefix_arg would have been set earlier.
  if [[ "$app_name" == "WezTerm" ]]; then
    if $is_context_aware_prefix_arg && [[ -n "$derived_context_from_prefix_arg" ]]; then
      _final_tmux_session_to_switch_to="$derived_context_from_prefix_arg"
      # _new_selection_file_content and _new_active_state_content already set by prefix logic
      echo "TMUX_FINAL (WezTerm with Context Prefix): Will switch to '$_final_tmux_session_to_switch_to'." >>"$LOG_FILE"

    # Case B: Generic call to WezTerm (e.g. cmd+lshift+1, no prefix arg: original_window_title_prefix_arg is empty)
    elif ! $is_context_aware_prefix_arg && [[ -z "$original_window_title_prefix_arg" ]]; then
      current_tmux_session_name=$(tmux display-message -p '#S' 2>/dev/null)

      # B1. Cycling WezTerm tmux sessions (if current_window_app was WezTerm)
      if [[ "$current_window_app" == "WezTerm" ]]; then
        echo "TMUX_FINAL (Generic WezTerm - Cycling Tmux Sessions): Current app is WezTerm." >>"$LOG_FILE"
        cycled_target=""
        if [[ ${#whitelist[@]} -gt 0 ]]; then
          current_idx=-1
          if [[ -n "$current_tmux_session_name" ]]; then
            for i in "${!whitelist[@]}"; do if [[ "${whitelist[$i]}" == "$current_tmux_session_name" ]]; then
              current_idx=$i
              break
            fi; done
          fi

          num_whitelist_items=${#whitelist[@]}
          start_idx=0
          if [[ "$current_idx" -ne -1 ]]; then
            start_idx=$(((current_idx + 1) % num_whitelist_items))
          else
            if [[ -n "$current_tmux_session_name" ]]; then
              echo "TMUX_FINAL (Generic WezTerm - Cycling Tmux): Current session '$current_tmux_session_name' not in whitelist or invalid. Starting search from first whitelist item." >>"$LOG_FILE"
            else
              echo "TMUX_FINAL (Generic WezTerm - Cycling Tmux): No current tmux session. Starting search from first whitelist item." >>"$LOG_FILE"
            fi
          fi

          for i in $(seq 0 $((num_whitelist_items - 1))); do
            check_idx=$(((start_idx + i) % num_whitelist_items))
            potential_target=${whitelist[$check_idx]}
            if tmux has-session -t "$potential_target" 2>/dev/null; then
              cycled_target="$potential_target"
              echo "TMUX_FINAL (Generic WezTerm - Cycling Tmux): Found running session '$cycled_target' to switch to." >>"$LOG_FILE"
              break
            else
              echo "TMUX_FINAL (Generic WezTerm - Cycling Tmux): Skipping non-running session '${potential_target}'." >>"$LOG_FILE"
            fi
          done

          if [[ -z "$cycled_target" ]]; then
            echo "TMUX_FINAL (Generic WezTerm - Cycling Tmux): No running whitelisted tmux sessions found. No tmux switch will occur." >>"$LOG_FILE"
          fi
        fi # end if whitelist not empty

        if [[ -n "$cycled_target" ]]; then
          _final_tmux_session_to_switch_to="$cycled_target"
          _new_selection_file_content="$cycled_target" # Update SELECTION_FILE
          _new_active_state_content="true"             # This action makes context active
          echo "TMUX_FINAL (Generic WezTerm - Cycling Tmux): Cycled to '$cycled_target'. SELECTION_FILE candidate '$_new_selection_file_content', ACTIVE_STATE candidate '$_new_active_state_content'." >>"$LOG_FILE"
        else
          echo "TMUX_FINAL (Generic WezTerm - Cycling Tmux): No cycle target (whitelist empty?). No tmux change." >>"$LOG_FILE"
        fi
      # B2. Switching TO WezTerm from another app
      else
        echo "TMUX_FINAL (Generic WezTerm - Switching To): Current app ($current_window_app) not WezTerm." >>"$LOG_FILE"
        _current_active_state_from_file="false" # Default to false if file doesn't exist
        if [[ -f "$SELECTION_FILE" ]]; then _current_active_state_from_file=$(cat "$SELECTION_FILE"); fi

        if [[ "$_current_active_state_from_file" == "true" ]]; then
          _saved_context_for_switch=""
          if [[ -f "$SELECTION_FILE" ]]; then _saved_context_for_switch=$(cat "$SELECTION_FILE"); fi

          is_valid_saved_context=false
          if [[ -n "$_saved_context_for_switch" ]]; then
            for allowed in "${whitelist[@]}"; do if [[ "$_saved_context_for_switch" == "$allowed" ]]; then
              is_valid_saved_context=true
              break
            fi; done
          fi

          if $is_valid_saved_context; then
            _final_tmux_session_to_switch_to="$_saved_context_for_switch"
            # _new_selection_file_content and _new_active_state_content are NOT changed here by this specific path,
            # they rely on the values set by previous context-setting actions.
            echo "TMUX_FINAL (Generic WezTerm - Switching To): Context is active. Switching to saved context '$_saved_context_for_switch'." >>"$LOG_FILE"
          else
            echo "TMUX_FINAL (Generic WezTerm - Switching To): Context active, but SELECTION_FILE ('$_saved_context_for_switch') invalid/empty. No tmux switch." >>"$LOG_FILE"
          fi
        else # Context is NOT active
          echo "TMUX_FINAL (Generic WezTerm - Switching To): Context NOT active per $ACTIVE_CONTEXT_STATE_FILE. No tmux switch (tmux session will stay unchanged)." >>"$LOG_FILE"
        fi
      fi # End if current_window_app == WezTerm
    fi   # End Case B (Generic WezTerm call)
  fi     # End if app_name == WezTerm

  # --- Apply state file changes (SELECTION_FILE, ACTIVE_CONTEXT_STATE_FILE) ---
  if [[ -n "$_new_selection_file_content" ]]; then
    _is_valid_new_sel=false
    for allowed in "${whitelist[@]}"; do if [[ "$_new_selection_file_content" == "$allowed" ]]; then
      _is_valid_new_sel=true
      break
    fi; done
    if $_is_valid_new_sel; then
      # Only write if file doesn't exist or content is different
      if [[ ! -f "$SELECTION_FILE" ]] || [[ "$(cat "$SELECTION_FILE" 2>/dev/null)" != "$_new_selection_file_content" ]]; then
        echo "$_new_selection_file_content" >"$SELECTION_FILE"
        echo "STATE_UPDATE: $SELECTION_FILE updated to '$_new_selection_file_content'." >>"$LOG_FILE"
      else
        echo "STATE_UPDATE: $SELECTION_FILE already '$_new_selection_file_content'. No change." >>"$LOG_FILE"
      fi
    else
      echo "STATE_UPDATE_ERROR: Attempted to set $SELECTION_FILE to invalid context '$_new_selection_file_content' (not in whitelist)." >>"$LOG_FILE"
    fi
  fi

  if [[ -n "$_new_active_state_content" ]]; then
    # Only write if file doesn't exist or content is different
    if [[ ! -f "$ACTIVE_CONTEXT_STATE_FILE" ]] || [[ "$(cat "$ACTIVE_CONTEXT_STATE_FILE" 2>/dev/null)" != "$_new_active_state_content" ]]; then
      echo "$_new_active_state_content" >"$ACTIVE_CONTEXT_STATE_FILE"
      echo "STATE_UPDATE: $ACTIVE_CONTEXT_STATE_FILE updated to '$_new_active_state_content'." >>"$LOG_FILE"
    else
      echo "STATE_UPDATE: $ACTIVE_CONTEXT_STATE_FILE already '$_new_active_state_content'. No change." >>"$LOG_FILE"
    fi
  fi

  # --- Perform actual tmux switch using _final_tmux_session_to_switch_to ---
  if [[ -n "$_final_tmux_session_to_switch_to" ]]; then
    _is_valid_final_target=false
    for allowed in "${whitelist[@]}"; do if [[ "$_final_tmux_session_to_switch_to" == "$allowed" ]]; then
      _is_valid_final_target=true
      break
    fi; done
    if $_is_valid_final_target; then
      current_tmux_session_for_check=$(tmux display-message -p '#S' 2>/dev/null)
      if [[ "$current_tmux_session_for_check" != "$_final_tmux_session_to_switch_to" ]]; then
        echo "TMUX_ACTION: Switching tmux to '$_final_tmux_session_to_switch_to'." >>"$LOG_FILE"
        if tmux switch-client -t "$_final_tmux_session_to_switch_to"; then
          echo "TMUX_ACTION: Successfully switched to '$_final_tmux_session_to_switch_to'." >>"$LOG_FILE"
        else
          echo "TMUX_ACTION: FAILED to switch tmux to '$_final_tmux_session_to_switch_to'. Exit code: $?." >>"$LOG_FILE"
        fi
      else
        echo "TMUX_ACTION: Already on target tmux session ('$_final_tmux_session_to_switch_to'). No switch." >>"$LOG_FILE"
      fi
    else
      echo "TMUX_ACTION_ERROR: Invalid final target '$_final_tmux_session_to_switch_to' for tmux switch (not in whitelist)." >>"$LOG_FILE"
    fi
  else
    echo "TMUX_ACTION: No specific tmux session switch determined for this run." >>"$LOG_FILE"
  fi

  # --- Focus the determined window ---
  echo "Trying to focus window id: $next_window_to_focus, app name: $app_name" >>"$LOG_FILE"
  yabai -m window --focus "$next_window_to_focus" 2>&1
  YABAI_EXIT_CODE=$?

    # Read the entire config file
    CONFIG_CONTENT=$(cat "$CONFIG_FILE")
  
      # Check if grayscale toggling is enabled in config.json
      ENABLE_GRAYSCALE_TOGGLE=$(echo "$CONFIG_CONTENT" | jq -r '.enable_grayscale_toggle // false')  
    # Grayscale logic: Only apply if enabled in config
    if [[ "$ENABLE_GRAYSCALE_TOGGLE" == "true" ]]; then
      # Grayscale logic: Turn off if hotkey '1' is used and the app is configured for hotkey '1'
      if [[ "$hotkey_arg" == "1" ]]; then
        # Get the list of app names configured for hotkey '1'
        CONFIGURED_APPS_FOR_HOTKEY_1=$(echo "$WINDOW_FOCUS_JSON" | jq -r ".\"1\" // [] | .[] | keys[]")
        
        IS_APP_CONFIGURED_FOR_HOTKEY_1=false
        for configured_app in $CONFIGURED_APPS_FOR_HOTKEY_1; do
          if [[ "$app_name" == "$configured_app" ]]; then
            IS_APP_CONFIGURED_FOR_HOTKEY_1=true
            break
          fi
        done
  
        if $IS_APP_CONFIGURED_FOR_HOTKEY_1; then
          toggle_grayscale_filter "false" # Disable grayscale
        else
          toggle_grayscale_filter "true" # Enable grayscale
        fi
      else
        toggle_grayscale_filter "true" # Enable grayscale for other hotkeys
      fi
    else
      echo "[Debug] Grayscale toggling is disabled in config.json. Skipping." >> "$LOG_FILE"
    fi
  
    # Suppress "no such window" error message if focusing the only window after one was closed,  # as yabai might take a moment to update its internal state. Focus usually still works.
  if [ $YABAI_EXIT_CODE -ne 0 ]; then
    echo "ERROR: yabai failed to focus window ID $next_window_to_focus. Exit code: $YABAI_EXIT_CODE." >>"$LOG_FILE"
    exit 1
  fi

  end_time=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')
  elapsed_seconds=$(perl -e "printf \"%.3f\", $end_time - $start_time")
  echo "Focus took ${elapsed_seconds}s at $(date)" >>"$LOG_FILE"

  echo "Writing '$next_window_to_focus' to $LAST_FOCUS_FILE for cycle group '$app_name|$original_window_title_prefix_arg'" >>"$LOG_FILE"
  echo "$next_window_to_focus" >"$LAST_FOCUS_FILE"
else
  echo "Error: Could not determine next window to focus for app '$app_name' and prefix '$original_window_title_prefix_arg'." >>"$LOG_FILE"
  exit 1
fi

echo "--- Script End --- " >>"$LOG_FILE"
exit 0
