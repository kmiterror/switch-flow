#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/switch-flow/" # Or any other preferred location in PATH
CONFIG_DIR="$HOME/.config/switch-flow"

echo "Starting installation of SwitchFlow..."

# 1. Install Homebrew if not present
if ! command -v brew &>/dev/null; then
  echo "Homebrew not found. Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add Homebrew to PATH for this session
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  echo "Homebrew is already installed."
fi

# 2. Install dependencies
echo "Installing dependencies: yabai, skhd, jq, flock..."
brew install yabai skhd jq flock

# 3. Create target directories
echo "Creating target directories..."
mkdir -p "$HOME/.config/yabai"
mkdir -p "$HOME/.config/skhd"
mkdir -p "$CONFIG_DIR"
mkdir -p "$HOME/Library/Logs/SwitchFlow"

# 4. Symlink configuration files and scripts
echo "Symlinking configuration files and scripts..."

# yabai
if [ -e "$HOME/.yabairc" ] && [ "$(readlink "$HOME/.yabairc")" != "$REPO_DIR/yabai/.yabairc" ]; then
  echo "Warning: Existing ~/.yabairc found and is not a symlink to this repo. Skipping symlink. Please merge manually if needed."
elif [ -e "$HOME/.yabairc" ] && [ "$(readlink "$HOME/.yabairc")" == "$REPO_DIR/yabai/.yabairc" ]; then
  echo "~/.yabairc already symlinked to this repo. Skipping."
else
  ln -sf "$REPO_DIR/yabai/.yabairc" "$HOME/.yabairc"
  echo "Symlinked ~/.yabairc"
fi

# skhd
SKHD_DEFAULT_FILE="$REPO_DIR/skhd/.skhdrc"
SKHD_USER_FILE="$HOME/.skhdrc"

if [ ! -e "$SKHD_USER_FILE" ]; then
  # If ~/.skhdrc does not exist, create it with project defaults and a user customization section
  echo "Creating ~/.skhdrc with project defaults and user customization section..."
  cat "$SKHD_DEFAULT_FILE" >"$SKHD_USER_FILE"
  cat <<EOF >>"$SKHD_USER_FILE"

# --- User Customizations (add your personal keybindings below this line) ---
# Example:
# cmd + lshift - h : $HOME/.local/switch-flow/scripts/cycle_focus_window.sh "h" &
# cmd + lshift - n : $HOME/.local/switch-flow/scripts/cycle_focus_window.sh "n" &
EOF
else
  echo "Warning: ~/.skhdrc already exists. Skipping creation. Please ensure it contains project defaults if desired." >>/dev/stderr
fi

# scripts
ln -sf "$REPO_DIR/scripts" "$BIN_DIR"

# 6. Copy config templates for user customization
echo "Copying and renaming config templates for user customization to $CONFIG_DIR/..."
cp -n "$REPO_DIR/config_templates/config.json.example" "$CONFIG_DIR/config.json"

# 7. Start yabai and skhd services
echo "Starting yabai and skhd services..."
# yabai --install-service
yabai --start-service
skhd --start-service

# 8. Post-installation instructions
echo ""
echo "-------------------------------------------------------------------"
echo "Installation complete! Please follow these manual steps:"
echo "1. Grant Accessibility Permissions:"
echo "   Go to System Settings > Privacy & Security > Accessibility."
echo "   Add 'yabai' and 'skhd' to the list and ensure they are enabled."
echo "   You might need to restart your computer for changes to take effect."
echo ""
echo "2. Customize Configurations:"
echo "   - Edit the example configuration file copied to $CONFIG_DIR/config.json."
echo "   - Your personal skhd keybindings can be added directly to ~/.skhdrc"
echo "     below the '--- User Customizations ---' line. The project defaults"
echo "     are automatically included at the top of this file."
echo "   - Use 'list-chrome-profiles.sh' to find Chrome profile names for the \"profiles\" section."
echo "   These files will be used by the scripts."
echo ""
echo "3. Ensure '$BIN_DIR' is in your PATH:"
echo "   Add 'export PATH="$BIN_DIR:
$PATH"' to your shell configuration file (e.g., ~/.zshrc, ~/.bashrc)."
echo "-------------------------------------------------------------------"

