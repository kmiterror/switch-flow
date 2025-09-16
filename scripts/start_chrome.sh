#!/bin/bash

# Function to start Chrome with a specific profile
start_chrome_profile() {
  profile_name=$1
  profile_path=$2

  # Check if Chrome is running
  if ! pgrep -x "Google Chrome" >/dev/null; then
    echo "Starting Google Chrome with profile: $profile_name"
    open -na "Google Chrome" --args --profile-directory="$profile_path"
  else
    echo "Google Chrome is already running."
  fi
}

# Usage: start_chrome_profile "Profile Name" "Profile Path"
start_chrome_profile "Work" "Profile 1"
