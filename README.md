# dotfiles

Personal development environment configuration for VS Code devcontainers and GitHub Codespaces.

## Contents

| File | Purpose |
|------|---------|
| `.config/Code/User/keybindings.json` | VS Code keybindings |
| `.config/Code/User/settings.json` | VS Code user-level settings |
| `.editorconfig` | Universal editor formatting |
| `.gitmessage` | Conventional Commits template |
| `.config/rtk/config.toml` | RTK CLI config (telemetry disabled) |
| `.claude/settings.json` | Claude Code user-level settings |
| `.wakatime.cfg` | WakaTime CLI config (no API key) |
| `install.sh` | Installer (auto-run by VS Code) |

## Setup

### GitHub Codespaces (automatic)

In [GitHub settings > Codespaces > Dotfiles](https://github.com/settings/codespaces):

- **Repository**: `qte77/dotfiles`
- **Install command**: `install.sh`

### VS Code Dev Containers (automatic)

Add to your VS Code user settings (`settings.json`):

```json
{
  "dotfiles.repository": "qte77/dotfiles",
  "dotfiles.installCommand": "install.sh",
  "dotfiles.targetPath": "~/dotfiles"
}
```

### Manual

```bash
git clone https://github.com/qte77/dotfiles ~/dotfiles
cd ~/dotfiles && ./install.sh
```

## Notes

### WakaTime API key handling

The `.wakatime.cfg` template contains **no API key**.
The key is resolved from the `WAKATIME_API_KEY` env var
(set via Codespaces secrets / `containerEnv`).

**Known issue (2026-03, extension v30.0.0):**
The VS Code WakaTime extension
([wakatime/vscode-wakatime](https://github.com/wakatime/vscode-wakatime))
ignores `api_key_vault_cmd` in `~/.wakatime.cfg` and
appends a hardcoded `api_key` on first prompt. This is
why `.wakatime.cfg` is **copied** (not symlinked) by
`install.sh` — prevents the extension from corrupting
the dotfiles source.

**Mitigations:**

- Set `WAKATIME_API_KEY` as a Codespaces secret — both
  CLI and extension read it from `process.env`
  ([docs](https://github.com/wakatime/wakatime-cli/blob/develop/USAGE.md))
- If prompted, enter the key once — extension writes
  it to the local `~/.wakatime.cfg` copy
- Do not symlink `.wakatime.cfg` (extension will
  mutate it)
