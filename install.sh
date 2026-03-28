#!/bin/bash
# Dotfiles installer — symlinks configs to $HOME
# Usage: ./install.sh (called automatically by VS Code dotfiles feature)

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# Declarative: source (relative to repo) -> target (absolute)
declare -A LINKS=(
  [".editorconfig"]="$HOME/.editorconfig"
  [".gitmessage"]="$HOME/.gitmessage"
  [".config/Code/User/settings.json"]="$HOME/.config/Code/User/settings.json"
  [".config/Code/User/keybindings.json"]="$HOME/.config/Code/User/keybindings.json"
  [".config/rtk/config.toml"]="$HOME/.config/rtk/config.toml"
  [".claude/settings.json"]="$HOME/.claude/settings.json"
)

for src in "${!LINKS[@]}"; do
  target="${LINKS[$src]}"
  mkdir -p "$(dirname "$target")"
  ln -sf "$DOTFILES_DIR/$src" "$target"
done

# Copy (not symlink) — WakaTime extension writes to this file directly
cp -n "$DOTFILES_DIR/.wakatime.cfg" "$HOME/.wakatime.cfg" 2>/dev/null || true

git config --global commit.template ~/.gitmessage

echo "Dotfiles installed from $DOTFILES_DIR"
