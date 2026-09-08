#!/bin/bash
# Dotfiles installer — symlinks configs to $HOME
# Usage: ./install.sh (called automatically by VS Code dotfiles feature)

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACES_DIR="${WORKSPACES_DIR:-/workspaces}"

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
    mv "$HOME/.claude" /workspaces/.claude-files/.claude.bak
  fi
  # Layer dotfiles defaults (no-clobber: won't overwrite runtime files)
  cp -rn "$DOTFILES_DIR/.claude/." /workspaces/.claude-files/
  # -n: don't dereference an existing ~/.claude dir-symlink — without it a
  # re-run plants a self-referential .claude-files/.claude-files loop inside
  ln -sfn /workspaces/.claude-files "$HOME/.claude"
else
  mkdir -p "$HOME/.claude"
  # Copy (not symlink) — Claude Code rewrites these via temp+rename, which
  # replaces a file symlink with a regular file and silently breaks the link
  # on first write. Seed once as defaults; directories aren't affected by
  # this failure mode, so hooks/ stays a symlink.
  cp -n "$DOTFILES_DIR/.claude/.claude.json" "$HOME/.claude/.claude.json" 2>/dev/null || true
  cp -n "$DOTFILES_DIR/.claude/settings.json" "$HOME/.claude/settings.json" 2>/dev/null || true
  ln -sfn "$DOTFILES_DIR/.claude/hooks" "$HOME/.claude/hooks"
fi

# Copy (not symlink) — WakaTime extension writes to this file directly
cp -n "$DOTFILES_DIR/.config/wakatime.cfg" "$HOME/.wakatime.cfg" 2>/dev/null || true

git config --global commit.template ~/.gitmessage

# disk-cleanup.sh — /workspaces overlay relief tool. Symlinked (not copied) so
# the tracked version in dotfiles is always the one that runs; source of truth
# stays here, not on the ephemeral overlay.
if [[ -d "$WORKSPACES_DIR" ]]; then
  chmod +x "$DOTFILES_DIR/scripts/disk-cleanup.sh"
  ln -sf "$DOTFILES_DIR/scripts/disk-cleanup.sh" "$WORKSPACES_DIR/disk-cleanup.sh"
fi

# Repair the offload symlinks disk-cleanup.sh plants (~/.cache/ms-playwright,
# ~/.npm, etc. -> /tmp/devcache/...) on every new shell — /tmp is wiped when
# the codespace stops, which otherwise leaves those dangling ("File exists" on
# writes) until someone happens to notice and run `repair` by hand. Appended
# idempotently so re-running install.sh never duplicates the line.
REPAIR_HOOK='/workspaces/disk-cleanup.sh repair >/dev/null 2>&1 || true'
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [[ -f "$rc" ]] || continue
  grep -qF "$REPAIR_HOOK" "$rc" 2>/dev/null || printf '\n# disk-cleanup: repair offload symlinks after /tmp wipe\n%s\n' "$REPAIR_HOOK" >> "$rc"
done

echo "Dotfiles installed from $DOTFILES_DIR"
