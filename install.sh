#!/bin/bash
# Dotfiles installer — symlinks configs to $HOME
# Usage: ./install.sh (called automatically by VS Code dotfiles feature)

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# VS Code keybindings & user settings
mkdir -p ~/.config/Code/User
ln -sf "$DOTFILES_DIR/.config/Code/User/keybindings.json" ~/.config/Code/User/keybindings.json
ln -sf "$DOTFILES_DIR/.config/Code/User/settings.json" ~/.config/Code/User/settings.json

# EditorConfig
ln -sf "$DOTFILES_DIR/.editorconfig" ~/.editorconfig

# Git commit template
ln -sf "$DOTFILES_DIR/.gitmessage" ~/.gitmessage
git config --global commit.template ~/.gitmessage

echo "Dotfiles installed from $DOTFILES_DIR"
