# dotfiles

Dev environment configs for Codespaces and devcontainers.

## What's managed

| File | Target | Method |
|------|--------|--------|
| `.claude/.claude.json` | `~/.claude/.claude.json` | symlink |
| `.claude/settings.json` | `~/.claude/settings.json` | symlink |
| `.config/Code/User/settings.json` | VS Code user settings | symlink |
| `.config/Code/User/keybindings.json` | VS Code keybindings | symlink |
| `.config/rtk/config.toml` | RTK CLI config | symlink |
| `.editorconfig` | `~/.editorconfig` | symlink |
| `.gitmessage` | `~/.gitmessage` | symlink |
| `.wakatime.cfg` | `~/.wakatime.cfg` | copy (extension mutates it) |

## Setup

**Codespaces** — [Settings > Codespaces > Dotfiles](https://github.com/settings/codespaces): set repo to `qte77/dotfiles`.

**Devcontainers** — add to VS Code user settings:

```json
"dotfiles.repository": "qte77/dotfiles",
"dotfiles.installCommand": "install.sh",
"dotfiles.targetPath": "~/dotfiles"
```

**Manual** — `git clone https://github.com/qte77/dotfiles ~/dotfiles && ~/dotfiles/install.sh`

## Notes

`.wakatime.cfg` is copied, not symlinked — the WakaTime extension writes `api_key` directly to the file. Set `WAKATIME_API_KEY` as a Codespaces secret instead.
