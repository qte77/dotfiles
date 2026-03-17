# dotfiles

Personal development environment configuration for VS Code devcontainers and GitHub Codespaces.

## Contents

| File | Purpose |
|------|---------|
| `.config/Code/User/keybindings.json` | VS Code keybindings |
| `.config/Code/User/settings.json` | VS Code user-level settings |
| `.editorconfig` | Universal editor formatting |
| `.gitmessage` | Conventional Commits template |
| `install.sh` | Symlink installer (auto-run by VS Code) |

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
