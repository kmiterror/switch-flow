#!/bin/bash

# Argument: "true" to enable grayscale, "false" to disable
ENABLE_GRAYSCALE="$1"

LOG_FILE="$HOME/Library/Logs/SwitchFlow/set_grayscale_state.log"

# Path to the Python interpreter
PYTHON_CMD=$(command -v python3)

# --- Embedded Python Script ---
# This Python script directly interacts with the UniversalAccess.framework
# to set the grayscale state. It also checks the current state to avoid
# unnecessary changes.
PYTHON_SCRIPT=$(cat << 'EOF'
import sys
from ctypes import cdll

def get_grayscale_status():
    lib = cdll.LoadLibrary("/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess")
    # UAGrayscaleIsEnabled() returns 1 if grayscale is enabled, 0 otherwise
    return lib.UAGrayscaleIsEnabled()

def set_grayscale_state(enable):
    lib = cdll.LoadLibrary("/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess")
    # UAGrayscaleSetEnabled(1) to enable, UAGrayscaleSetEnabled(0) to disable
    lib.UAGrayscaleSetEnabled(1 if enable else 0)

if __name__ == "__main__":
    print(f"[Python Debug] Script started with arg: {sys.argv[1]}", file=sys.stderr)
    if len(sys.argv) > 1:
        action = sys.argv[1]
        desired_state = (action == "true")
        
        current_state = get_grayscale_status()
        print(f"[Python Debug] Desired state: {'ON' if desired_state else 'OFF'}, Current state: {'ON' if current_state == 1 else 'OFF'}", file=sys.stderr)
        
        # Only change if the desired state is different from the current state
        if (desired_state and current_state == 0) or (not desired_state and current_state == 1):
            set_grayscale_state(desired_state)
            print(f"[Python Debug] Grayscale state changed to {'ON' if desired_state else 'OFF'}", file=sys.stderr)
        else:
            print(f"[Python Debug] Grayscale already in desired state. No change needed.", file=sys.stderr)
    else:
        print("[Python Debug] No argument provided.", file=sys.stderr)
        sys.exit(1) # Indicate error if no argument
EOF
)

# --- Grayscale Logic ---

# Execute the Python script
echo "[Bash Debug] Attempting to execute Python script." >> "$LOG_FILE"
if [ -n "$PYTHON_CMD" ]; then
    echo "$PYTHON_SCRIPT" | "$PYTHON_CMD" - "$ENABLE_GRAYSCALE" 2>> "$LOG_FILE"
    PYTHON_EXIT_CODE=$?
    echo "[Bash Debug] Python script exited with code: $PYTHON_EXIT_CODE." >> "$LOG_FILE"
    if [ $PYTHON_EXIT_CODE -ne 0 ]; then
        echo "ERROR: Python script failed with exit code $PYTHON_EXIT_CODE." >> "$LOG_FILE"
        exit 1
    fi
else
    echo "ERROR: python3 not found. Cannot control grayscale." >> "$LOG_FILE"
    exit 1
fi

exit 0