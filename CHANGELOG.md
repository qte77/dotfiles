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
- `scripts/disk-cleanup.sh`: Tier 1 now also runs `pnpm store prune`, removes superseded Claude
  CLI binaries (`~/.local/share/claude/versions/*` except the current one, plus
  `.claude-files/downloads/`) and abandoned git `tmp_pack_*` files; Tier 2 adds Codex CLI downloads
  and a pnpm store no longer in use; Tier 3 adds `.next` / `.turbo`.
- `scripts/disk-cleanup.sh`: live-session guard — Tiers 3/4 skip any repo a running process works
  in or whose artifact / git index changed in the last 24h; pnpm is left alone while pnpm runs;
  `.claude/worktrees` is never scanned.
- `scripts/disk-cleanup.sh top`: read-only list of the 20 largest dirs, 3 levels deep.
- `scripts/disk-cleanup.sh sessions [N]`: read-only list of the N (default 10) most recently used
  Claude session transcripts, with date, size and project.
- `scripts/disk-cleanup.sh` Tier 2: strips base64 screenshots from Claude session transcripts
  under `.claude-files/projects` via the new `scripts/strip-session-images.py`. Text, reasoning
  and tool calls are kept; each image becomes a one-line placeholder and is not recoverable.
  Transcripts modified in the last 2h are skipped, as a live session may still be appending.
- `tests/test_strip_session_images.py`: first tests in this repo, for the screenshot strip
  (`uv run --no-project --with pytest pytest tests`).

### Changed

- `scripts/disk-cleanup.sh --help`: now a ~40-line summary of commands, tiers and flags (was the
  88-line header with design notes). `--defer` now says space frees after the script exits.
  "Stage" is renamed "command" (`STAGE` → `CMD`); behaviour is unchanged.
- `scripts/disk-cleanup.sh`: tiers re-ordered by risk. Tier 3 no longer deletes `.venv`; Tier 4 is
  now "Python envs" (every `.venv` + `~/.local/share/uv`, moved from Tier 2). Git garbage moved
  from Tier 4 to Tier 1, found by a 1–3-level glob (~30s) instead of a whole-tree `find` (~3min).
  `./disk-cleanup.sh 4` now deletes venvs, not git garbage.

### Fixed

- `scripts/strip-session-images.py` (Tier 2 screenshot strip) looked stuck and could fail on a
  full disk. It printed nothing until exit (one summary line, buffered through a pipe),
  JSON-parsed every line of every transcript, held whole files in memory, and wrote each
  rewritten copy next to the original, which fails with too little free space. Now:
  - one progress line per file with images, largest files first, run unbuffered (`python3 -u`)
  - lines without image data are passed through without parsing
  - stripped copies are streamed to `--stage-dir` (default `$TMPDIR`, i.e. `/tmp`, another
    disk), checked there, then written back over the original in place, so the full disk
    needs no extra room
  - a file that changed during processing is left untouched
  - one failing file no longer stops the run (exit 1 at the end)
- `scripts/disk-cleanup.sh` Tier 1: no longer deletes a Claude CLI download in
  `.claude-files/downloads/` that is less than 30 min old, since the updater may still be
  writing it.
- `scripts/disk-cleanup.sh --defer`: queued trees were never deleted — `trash_for` ran in a
  `$(...)` subshell, so the trash dir it registered was lost and `flush_trash` never removed it.
- `scripts/disk-cleanup.sh --defer`: no longer prints a "Reclaimed" figure or the low-space hint
  while background deletes are still pending — that before/after `df` measured concurrent writers,
  not the run, and could come out negative. It now says to re-check `df` later.
- `scripts/disk-cleanup.sh`: Tier 3 no longer descends into `site-packages`, so a venv not named
  `.venv` keeps its `__pycache__` dirs (Tier 3 is "except venvs").
- `scripts/disk-cleanup.sh`: a busy repo is reported once ("active session, all artifacts")
  instead of one `keep` line per artifact; an artifact kept only for its own recent change says so.

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
