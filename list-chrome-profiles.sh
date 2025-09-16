#!/bin/bash

CHROME_USER_DATA_DIR="$HOME/Library/Application Support/Google/Chrome"

echo "Listing Chrome profiles found in: $CHROME_USER_DATA_DIR"
echo "----------------------------------------------------"

# Array to store found profile names for example configuration
PROFILE_NAMES=()

if [ -d "$CHROME_USER_DATA_DIR" ]; then
  find "$CHROME_USER_DATA_DIR" -maxdepth 1 -type d -name "Profile*" -o -name "Default" | while read -r profile_path; do
    profile_name=$(basename "$profile_path")
    display_info="N/A"

    # Add profile name to array
    PROFILE_NAMES+=("$profile_name")

    # Attempt to extract email/custodian info from Preferences file
    PREFERENCES_FILE="$profile_path/Preferences"
    if [ -f "$PREFERENCES_FILE" ]; then
      # Try to extract managed profile info first
      custodian_email=$(jq -r '.managed.custodian_email // empty' "$PREFERENCES_FILE" 2>/dev/null)
      custodian_name=$(jq -r '.managed.custodian_name // empty' "$PREFERENCES_FILE" 2>/dev/null)

      if [ -n "$custodian_email" ]; then
        if [ -n "$custodian_name" ]; then
          display_info="Managed Account: $custodian_name ($custodian_email)"
        else
          display_info="Managed Account: $custodian_email"
        fi
      else
        # Fallback to account_info array
        account_email=$(jq -r '.account_info[0].email // empty' "$PREFERENCES_FILE" 2>/dev/null)
        account_full_name=$(jq -r '.account_info[0].full_name // empty' "$PREFERENCES_FILE" 2>/dev/null)

        if [ -n "$account_email" ]; then
          if [ -n "$account_full_name" ]; then
            display_info="Account: $account_full_name ($account_email)"
          else
            display_info="Account: $account_email"
          fi
        else
          # Final fallback to profile.info.email (less common for primary accounts now)
          extracted_email=$(jq -r '.profile.info.email // empty' "$PREFERENCES_FILE" 2>/dev/null)
          if [ -n "$extracted_email" ]; then
            display_info="Account: $extracted_email"
          fi
        fi
      fi
    fi
    echo "$profile_name ($display_info)"
  done
else
  echo "Chrome user data directory not found at $CHROME_USER_DATA_DIR."
  echo "Please ensure Chrome is installed and has been run at least once."
fi

echo "----------------------------------------------------"
echo "Suggested 'profiles' configuration for config.json:"
echo "  \"profiles\": {"

# Generate example mappings based on found profiles
if [ ${#PROFILE_NAMES[@]} -ge 1 ]; then
  echo "    \"personalProfile\": \"${PROFILE_NAMES[0]}\","
else
  echo "    \"personalProfile\": \"Profile 1\"," # Placeholder if no profiles found
fi

if [ ${#PROFILE_NAMES[@]} -ge 2 ]; then
  echo "    \"workProfile\": \"${PROFILE_NAMES[1]}\","
elif [ ${#PROFILE_NAMES[@]} -eq 1 ]; then
  echo "    \"workProfile\": \"Default\"," # Placeholder if only one profile found
else
  echo "    \"workProfile\": \"Default\"," # Placeholder if no profiles found
fi

echo "    // ... other profiles as needed"
echo "  }"
echo "Note: Adjust 'personalProfile' and 'workProfile' to match your preferred profiles."
echo "Account info extraction relies on common Chrome preferences structure and might not always be accurate."
