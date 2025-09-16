#!/bin/bash

# Usage function to guide how to use the script
usage() {
  echo "Usage: $0 [-n <window-name-prefix>] [-u <url>] -p <profile-directory> [-f <bookmark-folder>]"
  echo "  -n   Window name prefix (optional if -f is provided)"
  echo "  -u   URL to open (optional, ignored if -f is provided)"
  echo "  -p   Chrome profile directory (e.g., 'Profile 1' or 'Default')"
  echo "  -f   Bookmark folder name (e.g., 'Work' or 'Projects')"
  exit 1
}

# Parse options
while getopts "n:u:p:f:" opt; do
  case $opt in
  n) window_name_prefix="$OPTARG" ;;
  u) url="$OPTARG" ;;
  p) profile_directory="$OPTARG" ;;
  f) bookmark_folder="$OPTARG" ;;
  *) usage ;;
  esac
done

# Ensure mandatory arguments are provided
if [ -z "$profile_directory" ]; then
  usage
fi

# If -f is provided and -n is not, set the folder name as the window prefix
if [ -n "$bookmark_folder" ] && [ -z "$window_name_prefix" ]; then
  window_name_prefix="$bookmark_folder"
fi

# Ensure we have a window name prefix
if [ -z "$window_name_prefix" ]; then
  echo "You must specify a window name prefix with -n or a bookmark folder with -f."
  usage
fi

# Function to extract bookmark URLs from Chrome's Bookmarks file
extract_bookmarks() {
  local folder_name="$1"
  local profile_dir="$2"
  local bookmarks_file="$HOME/Library/Application Support/Google/Chrome/$profile_dir/Bookmarks"

  if [ ! -f "$bookmarks_file" ]; then
    echo "Bookmarks file not found for profile: $profile_dir"
    exit 1
  fi

  # Extract bookmarks using jq
  jq -r --arg folder "$folder_name" '
  def findFolder(obj; folder):
    obj | select(.name == $folder and .type == "folder");
  def extractUrls(obj):
    obj | select(.type == "url") | .url;

  .roots |
    ( .. | objects | findFolder(.; $folder) ) |
    .children[]? | extractUrls(.)
' "$bookmarks_file"
}

# Check if a window with the title beginning with the specified prefix already exists
window_exists=$(yabai -m query --windows | jq -r ".[] | select(.title | startswith(\"$window_name_prefix\")) | .id")

# If the window does not exist, open a new one
if [ -z "$window_exists" ]; then
  echo "Opening Chrome with window name '$window_name_prefix'"

  if [ -n "$bookmark_folder" ]; then
    # Extract URLs from the specified bookmark folder
    urls=$(extract_bookmarks "$bookmark_folder" "$profile_directory")

    if [ -z "$urls" ]; then
      echo "No bookmarks found in folder '$bookmark_folder'"
      exit 1
    fi

    # Open Chrome with the extracted URLs in separate tabs
    open -na 'Google Chrome' --args --window-name="$window_name_prefix" --new-window $(echo "$urls" | xargs) --profile-directory="$profile_directory"
  elif [ -n "$url" ]; then
    # Open Chrome with the specified URL
    open -na 'Google Chrome' --args --window-name="$window_name_prefix" --new-window "$url" --profile-directory="$profile_directory"
  else
    echo "No URL or bookmark folder specified."
    exit 1
  fi
else
  echo "A window with the name prefix '$window_name_prefix' already exists. Skipping."
fi
