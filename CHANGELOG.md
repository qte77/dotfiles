# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Types of changes**: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`

## [Unreleased]

### Added

- `scripts/disk-cleanup.sh`: tracked the `/workspaces` overlay-relief tool in git — it previously
  lived only at `/workspaces/disk-cleanup.sh`, outside any repo, at risk of being lost entirely on
  a full codespace rebuild (not just a resume).

### Fixed

- `install.sh`: symlinks `scripts/disk-cleanup.sh` to `/workspaces/disk-cleanup.sh` (tracked copy
  is now the source of truth) and appends its `repair` hook to `~/.bashrc` / `~/.zshrc`
  idempotently. The script offloads 11 cache dirs to `/tmp/devcache/...` via symlinks that go
  dangling every time the codespace stops (`/tmp` is wiped); the fix was already documented in the
  script's own header comment but was never actually wired into shell startup, so every session
  had to rediscover and re-run `repair` by hand.

- `install.sh` (non-Codespaces branch): stop individually symlinking `~/.claude/.claude.json` and
  `~/.claude/settings.json`. Claude Code rewrites config via temp+rename, which replaces a file
  symlink with a regular file and silently breaks the link on first write (see
  qte77/claude-code-plugins#199 failure mode 1). Now seeded once via no-clobber copy instead;
  `~/.claude/hooks` stays a symlink since directories aren't affected by this failure mode.
