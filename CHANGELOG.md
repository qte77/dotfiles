# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Types of changes**: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`

## [Unreleased]

### Fixed

- `install.sh` (non-Codespaces branch): stop individually symlinking `~/.claude/.claude.json` and
  `~/.claude/settings.json`. Claude Code rewrites config via temp+rename, which replaces a file
  symlink with a regular file and silently breaks the link on first write (see
  qte77/claude-code-plugins#199 failure mode 1). Now seeded once via no-clobber copy instead;
  `~/.claude/hooks` stays a symlink since directories aren't affected by this failure mode.
