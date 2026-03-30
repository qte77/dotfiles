#!/bin/bash
# Dotfiles installer — symlinks configs to $HOME
# Usage: ./install.sh (called automatically by VS Code dotfiles feature)

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# Declarative: source (relative to repo) -> target (absolute)
declare -A LINKS=(
  [".config/editorconfig"]="$HOME/.editorconfig"
  [".config/gitmessage"]="$HOME/.gitmessage"
  [".config/Code/User/settings.json"]="$HOME/.config/Code/User/settings.json"
  [".config/Code/User/keybindings.json"]="$HOME/.config/Code/User/keybindings.json"
  [".config/rtk/config.toml"]="$HOME/.config/rtk/config.toml"
)

for src in "${!LINKS[@]}"; do
  target="${LINKS[$src]}"
  mkdir -p "$(dirname "$target")"
  ln -sf "$DOTFILES_DIR/$src" "$target"
done

# Claude Code config — Codespace-aware persistence
# In Codespaces: /workspaces/ survives rebuilds, so persist ~/.claude there
# Outside: symlink individual config files from dotfiles
#
# Order safety: if Claude Code ran first and created a real ~/.claude dir,
# merge its contents into .claude-files before replacing with a symlink.
# cp -rn = no-clobber, so existing .claude-files content wins on conflict.
if [[ "${CODESPACES:-}" == "true" ]]; then
  mkdir -p /workspaces/.claude-files
  # Preserve any existing ~/.claude content (e.g. from Claude Code init)
  if [[ -d "$HOME/.claude" && ! -L "$HOME/.claude" ]]; then
    cp -rn "$HOME/.claude/." /workspaces/.claude-files/
  fi
  # Layer dotfiles defaults (no-clobber: won't overwrite runtime files)
  cp -rn "$DOTFILES_DIR/.claude/." /workspaces/.claude-files/
  rm -rf "$HOME/.claude" 2>/dev/null
  ln -sf /workspaces/.claude-files "$HOME/.claude"
else
  mkdir -p "$HOME/.claude"
  ln -sf "$DOTFILES_DIR/.claude/.claude.json" "$HOME/.claude/.claude.json"
  ln -sf "$DOTFILES_DIR/.claude/settings.json" "$HOME/.claude/settings.json"
fi

# Copy (not symlink) — WakaTime extension writes to this file directly
cp -n "$DOTFILES_DIR/.config/wakatime.cfg" "$HOME/.wakatime.cfg" 2>/dev/null || true

git config --global commit.template ~/.gitmessage

echo "Dotfiles installed from $DOTFILES_DIR"
