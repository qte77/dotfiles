# dotfiles

Dev environment configs for Codespaces and devcontainers.

## What's managed

| File | Target | Method |
|------|--------|--------|
| `.claude/` | `~/.claude/` | Codespace: copy to `/workspaces/.claude-files/`, symlink `~/.claude` → there. Otherwise: symlink individual files. |
| `.config/Code/User/settings.json` | VS Code user settings | symlink |
| `.config/Code/User/keybindings.json` | VS Code keybindings | symlink |
| `.config/rtk/config.toml` | RTK CLI config | symlink |
| `.config/editorconfig` | `~/.editorconfig` | symlink |
| `.config/gitmessage` | `~/.gitmessage` | symlink |
| `.config/wakatime.cfg` | `~/.wakatime.cfg` | copy (extension mutates it) |

### Claude Code in Codespaces

`~/.claude` is symlinked to `/workspaces/.claude-files/` for rebuild persistence. On install, existing content is merged with no-clobber priority:

1. **Existing `.claude-files/`** — preserved (previous rebuild state)
2. **`~/.claude/` real dir** — merged in (Claude Code may have initialized first)
3. **Dotfiles defaults** — layered last, never overwrites runtime files

This means Claude Code can run before or after dotfiles — credentials, sessions, and hooks are preserved either way.

### Project scaffolding

These files are not deployed to `~/` — they exist as templates for copying into new projects (manually or via CC workspace plugins):

| File | Purpose |
|------|---------|
| `.gitmessage` | Conventional commits template (`git config commit.template`) |
| `.github/ISSUE_TEMPLATE/` | Bug report, question, feature request |
| `.github/PULL_REQUEST_TEMPLATE.md` | PR checklist with conventional commit types |
| `CONTRIBUTING.md` | Generic dev workflow and code standards |
| `CHANGELOG.md` | Keep a Changelog scaffold |

Agent governance files (`AGENTS.md`, `AGENT_LEARNINGS.md`, `AGENT_REQUESTS.md`) are **not** managed here — they belong in the [CC plugins](https://github.com/qte77/claude-code-plugins) repo and are deployed by its workspace plugins.

### Codespaces dotfiles behavior

Per [GitHub docs](https://docs.github.com/codespaces/setting-your-user-preferences/personalizing-github-codespaces-for-your-account#dotfiles): Codespaces clones the configured dotfiles repo and auto-detects `install.sh` (highest priority). If no install script is found, files starting with `.` are symlinked to `~/` automatically. Since this repo has `install.sh`, the fallback never triggers — all deployment is explicit.

Changes only apply to **new** codespaces, not existing ones.

## Setup

**Codespaces** — [Settings > Codespaces > Dotfiles](https://github.com/settings/codespaces): set repo to `qte77/dotfiles`.

**Devcontainers** — add to VS Code user settings:

```json
"dotfiles.repository": "qte77/dotfiles",
"dotfiles.installCommand": "install.sh",
"dotfiles.targetPath": "~/dotfiles"
```bash

**Manual** — `git clone https://github.com/qte77/dotfiles ~/dotfiles && ~/dotfiles/install.sh`

## Notes

`.wakatime.cfg` is copied, not symlinked — the WakaTime extension writes `api_key` directly to the file. Set `WAKATIME_API_KEY` as a Codespaces secret instead.
