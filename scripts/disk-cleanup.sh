#!/usr/bin/env bash
#
# disk-cleanup.sh - disk relief for the /workspaces overlay, in two stages
#
# The overlay (/dev/loop4, 32G) backs both / and /workspaces, so freeing space
# anywhere on it - including ~/.cache - relieves the same device.
#
# STAGE 1: purge   deletes regenerable data. Idempotent, repeatable, leaves no
#                  state behind. This is the emergency path - keep it fast.
# STAGE 2: offload MOVES caches to /tmp (a different physical disk) and leaves
#                  symlinks behind. A one-time structural change with lasting
#                  state, needing `repair` on every codespace start.
#
# They are separate stages on purpose. A purge is something you run whenever you
# are short of space; an offload is something you do once and then maintain.
# Bundling them meant an urgent purge sat behind a slow cache copy.
#
#   purge tiers
#     Tier 1 (default): regenerable caches. Zero risk.
#     Tier 2 (opt-in):  tool data and downloaded models. Re-download cost.
#     Tier 3 (opt-in):  build artifacts (.venv/node_modules/target/caches).
#     Tier 4 (opt-in):  abandoned git pack files. Zero risk - git itself calls
#                       them garbage. Needs a tree scan, so not in the fast path.
#
#   Pruning unreachable git objects is deliberately NOT a tier: it is the only
#   thing here that can destroy unrecoverable work, so it sits behind
#   `git --gc`, outside `all`.
#
# WHY THE ORIGINAL VERSION APPEARED TO HANG
# -----------------------------------------
# /workspaces is ext4 inside a loop file that sits near 100% full. Metadata
# reads there run under 1 MB/s and block in uninterruptible (D) state, so the
# process ignores Ctrl-C for seconds at a time. Measured on this box:
#   one whole-tree `find`      = 3m03s wall / 2.4s CPU  (98% iowait)
#   one `du -sh ~/.cache`      = 49s    wall / 0.6s CPU
# The original multiplied that:
#   * purge_path ran `du -sh` before every delete - a full walk to print a
#     number, then a second full walk to unlink. Tier 1 (the DEFAULT) paid this
#     on every cache path and emitted nothing for minutes.
#   * Tier 3 ran seven separate whole-tree finds, one per artifact name (~21min).
#   * find had no -xdev, so it also walked /workspaces/.codespaces/shared -
#     a different device (/dev/root) holding the VS Code server, where deleting
#     frees nothing on loop4.
# Sizing is now opt-in, the seven traversals are one, the traversal stays
# on-device, and every phase prints an elapsed-time heartbeat.
#
# Usage:
#   ./disk-cleanup.sh                  # purge, Tier 1 only (default stage)
#   ./disk-cleanup.sh 2                # purge, Tier 1 + Tier 2
#   ./disk-cleanup.sh 2 3              # purge, Tiers 1 + 2 + 3
#   ./disk-cleanup.sh all              # purge, all tiers
#   ./disk-cleanup.sh --defer 3        # rename into trash, rm in background
#   ./disk-cleanup.sh --dry-run 2 3    # show what would go, delete nothing
#   ./disk-cleanup.sh --sizes          # measure each path with du (SLOW here)
#
#   ./disk-cleanup.sh 4                # purge, Tier 1 + stale git pack files
#
#   ./disk-cleanup.sh git              # survey repos: pack / garbage / loose
#   ./disk-cleanup.sh git --gc         # repack, keeping 2 weeks of unreachable
#   ./disk-cleanup.sh git --aggressive # --prune=now: DISCARDS unreachable NOW
#
#   ./disk-cleanup.sh offload          # move caches to /tmp, leave symlinks
#   ./disk-cleanup.sh repair           # re-point links after /tmp is wiped
#   ./disk-cleanup.sh restore          # move caches back, remove symlinks
#   ./disk-cleanup.sh status           # what is linked, local, or dangling
#   ./disk-cleanup.sh --help
#
# Run `offload` BEFORE `purge` to keep a cache's contents (they get moved);
# run it AFTER to discard them and just point future downloads at /tmp.
#
# /tmp is wiped when the codespace stops. That is fine for caches, but a
# dangling symlink makes writes FAIL ("File exists"), so add to ~/.bashrc:
#   /workspaces/disk-cleanup.sh repair >/dev/null 2>&1 || true

set -euo pipefail

HOME_DIR="${HOME:-/home/vscode}"
WORKSPACES="${WORKSPACES:-/workspaces}"   # overridable so the tree scans are testable
OFFLOAD_ROOT="${OFFLOAD_ROOT:-/tmp/devcache}"

STAGE=purge
DRY_RUN=0
RUN_T2=0
RUN_T3=0
RUN_T4=0
GIT_GC=0
GIT_AGGRESSIVE=0
DEFER=0
GIT_TMP_AGE_H=24  # leave tmp packs younger than this alone; a git op may own them
SIZES=-1          # -1 = auto (on for --dry-run, off otherwise)
TOOL_TIMEOUT=600  # seconds before a cache-clean subcommand is given up on

# Print the leading comment block, whatever length it grows to.
usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit 0
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    purge|offload|repair|restore|status|git) STAGE="$1"; shift ;;
  esac
fi

for arg in "$@"; do
  case "$arg" in
    -h|--help)     usage ;;
    -n|--dry-run)  DRY_RUN=1 ;;
    --defer)       DEFER=1 ;;
    --gc)          GIT_GC=1 ;;
    --aggressive)  GIT_GC=1; GIT_AGGRESSIVE=1 ;;
    --sizes)       SIZES=1 ;;
    --no-sizes)    SIZES=0 ;;
    2|tier2|--tier2) RUN_T2=1 ;;
    3|tier3|--tier3) RUN_T3=1 ;;
    4|tier4|--tier4) RUN_T4=1 ;;
    all|--all)     RUN_T2=1; RUN_T3=1; RUN_T4=1 ;;
    *) printf 'Unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

(( SIZES == -1 )) && SIZES=$DRY_RUN

T0=$SECONDS
log() { printf '[%4ds] %s\n' "$(( SECONDS - T0 ))" "$*"; }

avail_bytes() {
  local v=''
  v=$(df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' ') || v=''
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s' "$v"
}

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }

# True when $1 is a symlink this script planted into the offload root.
is_offload_link() {
  [[ -L "$1" ]] || return 1
  [[ "$(readlink -- "$1")" == "$OFFLOAD_ROOT"/* ]]
}

# ---- caches eligible for /tmp ---------------------------------------------
# Not every cache is safe to move. uv, pnpm and bun populate .venv/node_modules
# with HARDLINKS into their store, and a hardlink cannot cross a filesystem
# boundary. Move those stores to /tmp and every install silently downgrades to
# a full copy - consuming MORE space on the near-full device, not less. So these
# deliberately stay put: ~/.cache/uv, ~/.local/share/pnpm/store,
# /workspaces/.pnpm-store, ~/.bun. The purge tiers shrink them instead.
#
# One list, not two: offload_path moves a directory that exists and plants a
# forward-looking symlink for one that does not, so the same entry covers both
# "carry my cache over" and "send future downloads to /tmp".
OFFLOAD_PATHS=(
  "${HOME_DIR}/.npm"
  "${HOME_DIR}/.cargo/registry"
  "${HOME_DIR}/.cache/gh"
  "${HOME_DIR}/.cache/huggingface"
  "${HOME_DIR}/.cache/ms-playwright"
  "${HOME_DIR}/.cache/pip"
  "${HOME_DIR}/.cache/puppeteer"
  "${HOME_DIR}/.cache/go-build"
  "${HOME_DIR}/.cache/typescript"
  "${HOME_DIR}/.cache/node-gyp"
  "${HOME_DIR}/.cache/mesa_shader_cache"
)

# ---- deferred deletion ----------------------------------------------------
# rm -rf on this disk is the slow part. With --defer we instead rename the tree
# into a trash dir ON THE SAME DEVICE (a rename is O(1)) and unlink it in a
# detached background process, so the script returns immediately. Space is
# reclaimed shortly after the script exits, not before it.
declare -A TRASH_BY_DEV=()

trash_for() { # $1=path -> echoes a trash dir on the same device, or fails
  local p="$1" dev root t
  dev=$(stat -c %d -- "$p" 2>/dev/null) || return 1
  if [[ -n "${TRASH_BY_DEV[$dev]:-}" ]]; then
    printf '%s' "${TRASH_BY_DEV[$dev]}"; return 0
  fi
  for root in "$WORKSPACES" "$HOME_DIR" "$(dirname -- "$p")"; do
    [[ -d "$root" ]] || continue
    [[ "$(stat -c %d -- "$root" 2>/dev/null)" == "$dev" ]] || continue
    t="${root}/.disk-cleanup-trash.$$"
    mkdir -p "$t" 2>/dev/null || continue
    TRASH_BY_DEV[$dev]="$t"
    printf '%s' "$t"; return 0
  done
  return 1
}

# A --defer run killed before flush_trash leaves its trash dir behind forever
# (the tier-3 find prunes it, so nothing else would ever notice). Sweep any
# that are not ours on startup.
sweep_stale_trash() {
  local d
  for d in "${WORKSPACES}"/.disk-cleanup-trash.* "${HOME_DIR}"/.disk-cleanup-trash.*; do
    [[ -d "$d" ]] || continue
    [[ "$d" == *".$$" ]] && continue
    if (( DRY_RUN )); then
      printf '  [dry-run] would sweep stale trash %s\n' "$d"
    else
      log "sweeping stale trash $d (background)"
      setsid rm -rf -- "$d" </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
  done
}

flush_trash() {
  local t
  for t in ${TRASH_BY_DEV[@]+"${TRASH_BY_DEV[@]}"}; do
    log "background rm started for $t (space frees after this script exits)"
    setsid rm -rf -- "$t" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  done
}

# Remove a path (file or directory). Sizing is opt-in because `du` costs a full
# extra tree walk on this device.
purge_path() {
  local p="$1" sz='' t
  # Never delete an offload symlink: rm removes the LINK, orphaning the copy on
  # /tmp and silently undoing the offload. Purging it would free /tmp anyway,
  # not the device we are trying to relieve.
  if is_offload_link "$p"; then
    printf '  keep    %-54s (offload link)\n' "$p"
    return 0
  fi
  if [[ ! -e "$p" && ! -L "$p" ]]; then
    (( DRY_RUN )) && printf '  absent  %s\n' "$p"
    return 0
  fi
  if (( SIZES )); then
    sz=$(du -sh -- "$p" 2>/dev/null | cut -f1) || sz='?'
    [[ -n "$sz" ]] || sz='?'
  fi
  if (( DRY_RUN )); then
    printf '  [dry-run] would remove %-52s %s\n' "$p" "$sz"
  elif (( DEFER )) && t=$(trash_for "$p"); then
    mv -- "$p" "$t/$(basename -- "$p").$RANDOM" 2>/dev/null \
      && printf '  queued  %-54s %s\n' "$p" "$sz" \
      || { rm -rf -- "$p"; printf '  removed %-54s %s\n' "$p" "$sz"; }
  else
    rm -rf -- "$p"
    printf '  removed %-54s %s\n' "$p" "$sz"
  fi
}

# Run a tool's own cache-clean command, skipping if the tool is absent.
# stdin is closed and a timeout applied: the original discarded stdout and
# stderr, so a tool that prompted or wedged hung the script with zero output.
purge_cmd() {
  local label="$1" guard="$2"; shift 2
  if is_offload_link "$guard"; then
    printf '  keep    %-54s (offload link, skip %s)\n' "$guard" "$label"
    return 0
  fi
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '  skip %-20s (%s not on PATH)\n' "$label" "$1"
    return 0
  fi
  if (( DRY_RUN )); then
    printf '  [dry-run] would run: %s\n' "$*"
    return 0
  fi
  local rc=0
  timeout -k 10 "$TOOL_TIMEOUT" "$@" </dev/null >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0)   printf '  cleaned %s (%s)\n' "$label" "$*" ;;
    124) printf '  warn: %s timed out after %ss (%s)\n' "$label" "$TOOL_TIMEOUT" "$*" ;;
    *)   printf '  warn: %s failed rc=%s (%s)\n' "$label" "$rc" "$*" ;;
  esac
}

# ---- offload / repair / restore / status ----------------------------------
offload_path() {
  local src="$1" dest parent t
  dest="${OFFLOAD_ROOT}${src}"

  if [[ -L "$src" ]]; then
    if is_offload_link "$src"; then
      if [[ -d "$dest" ]]; then
        printf '  ok      %-52s -> %s\n' "$src" "$dest"
      elif (( DRY_RUN )); then
        printf '  [dry-run] would re-create wiped target %s\n' "$dest"
      else
        mkdir -p "$dest" && printf '  relinked %-51s (target was wiped)\n' "$src"
      fi
    else
      printf '  skip    %-52s (symlink elsewhere)\n' "$src"
    fi
    return 0
  fi

  if [[ ! -e "$src" ]]; then
    if (( DRY_RUN )); then
      printf '  [dry-run] would pre-create %s -> %s\n' "$src" "$dest"
    else
      parent=$(dirname -- "$src")
      mkdir -p "$dest" "$parent" && ln -sfn "$dest" "$src" \
        && printf '  created %-52s -> %s\n' "$src" "$dest"
    fi
    return 0
  fi

  [[ -d "$src" ]] || { printf '  skip    %-52s (not a directory)\n' "$src"; return 0; }

  if (( DRY_RUN )); then
    printf '  [dry-run] would move %-46s -> %s\n' "$src" "$dest"
    return 0
  fi

  # copy first, swap second: an interrupted move must never lose the cache
  log "  copying $src -> $dest (copies in full; may take minutes)"
  mkdir -p "$(dirname -- "$dest")"
  rm -rf -- "${dest}.partial"
  if ! cp -a -- "$src" "${dest}.partial" 2>/dev/null; then
    rm -rf -- "${dest}.partial"
    printf '  warn: copy failed, left in place: %s\n' "$src"
    return 0
  fi
  rm -rf -- "$dest"
  if ! mv -- "${dest}.partial" "$dest" 2>/dev/null; then
    printf '  warn: swap failed, left in place: %s\n' "$src"
    return 0
  fi
  # The source must be gone before ln -sfn, so remove it directly rather than
  # through purge_path (which now refuses to touch offload paths).
  if (( DEFER )) && t=$(trash_for "$src"); then
    mv -- "$src" "$t/$(basename -- "$src").$RANDOM" 2>/dev/null || rm -rf -- "$src"
  else
    rm -rf -- "$src"
  fi
  ln -sfn "$dest" "$src"
  printf '  offloaded %-50s -> %s\n' "$src" "$dest"
}

# Repair only re-points existing links; it never moves a real directory. That
# is what makes it safe to run unattended from a shell rc file.
repair_path() {
  local p="$1" t
  is_offload_link "$p" || return 0
  t=$(readlink -- "$p")
  [[ -d "$t" ]] && return 0
  if (( DRY_RUN )); then
    printf '  [dry-run] would re-create wiped target %s\n' "$t"
    return 0
  fi
  mkdir -p "$t" && printf '  relinked %-51s -> %s\n' "$p" "$t"
}

restore_path() {
  local src="$1" dest
  is_offload_link "$src" || { printf '  skip    %-52s (not offloaded)\n' "$src"; return 0; }
  dest=$(readlink -- "$src")
  if (( DRY_RUN )); then
    printf '  [dry-run] would restore %-45s <- %s\n' "$src" "$dest"
    return 0
  fi
  if [[ ! -d "$dest" ]]; then
    rm -f -- "$src"
    printf '  cleared %-52s (target wiped; dangling link removed)\n' "$src"
    return 0
  fi
  log "  copying back $dest -> $src"
  rm -rf -- "${src}.restore"
  if ! cp -a -- "$dest" "${src}.restore" 2>/dev/null; then
    rm -rf -- "${src}.restore"
    printf '  warn: restore failed (out of space?), link left intact: %s\n' "$src"
    return 0
  fi
  rm -f -- "$src"
  mv -- "${src}.restore" "$src"
  rm -rf -- "$dest"
  printf '  restored %-51s\n' "$src"
}

status_path() {
  local p="$1" t
  if [[ -L "$p" ]]; then
    t=$(readlink -- "$p")
    if [[ "$t" != "$OFFLOAD_ROOT"/* ]]; then
      printf '  %-46s symlink elsewhere -> %s\n' "$p" "$t"
    elif [[ -d "$t" ]]; then
      printf '  %-46s offloaded\n' "$p"
    else
      printf '  %-46s DANGLING (run: %s repair)\n' "$p" "$0"
    fi
  elif [[ -d "$p" ]]; then
    printf '  %-46s local\n' "$p"
  else
    printf '  %-46s absent\n' "$p"
  fi
}

# ---- tier 3 traversal ------------------------------------------------------
# One traversal for all artifact names instead of seven. -xdev keeps it on the
# loop4 device, and .codespaces / .git / stale trash are pruned outright:
# .codespaces/shared is the VS Code server on another device, and .git holds
# no build artifacts but plenty of inodes to stat.
ARTIFACT_NAMES=(node_modules .venv __pycache__ .pytest_cache .mypy_cache .ruff_cache target)

find_artifacts() {
  local name_expr=() n
  for n in "${ARTIFACT_NAMES[@]}"; do name_expr+=( -o -name "$n" ); done
  name_expr=( "${name_expr[@]:1}" )   # drop the leading -o
  find "$WORKSPACES" -xdev \
    \( -path "${WORKSPACES}/.codespaces" -o -name .git -o -name '.disk-cleanup-trash.*' \) -prune -o \
    -type d \( "${name_expr[@]}" \) -prune -print0 2>/dev/null
}

# ---- git repositories ------------------------------------------------------
# Repo bloat is invisible to the purge tiers: Tier 3 prunes .git outright (it
# holds no build artifacts, only inodes to stat). Yet one repo here carried
# 2.0G against a 105M real repository - bigger than every cache combined.
#
# That 2.0G was two different things, and they belong in different places:
#
#   abandoned tmp_pack_*   git's own `count-objects` calls this "garbage". It
#                          is a half-written pack from a clone/fetch/gc that
#                          died (often BECAUSE the disk filled - a failure that
#                          feeds itself). Nothing references it. Zero risk, so
#                          Tier 4 removes it.
#
#   unreachable objects    reachable from no ref, but possibly a bad `reset
#                          --hard`, a dropped stash, or an interrupted rebase.
#                          Plain `git gc` keeps these for two weeks on purpose.
#                          NOT a tier: this is the only operation in the script
#                          that can destroy work you cannot regenerate, so it
#                          lives in the opt-in `git` stage behind --gc.
find_git_repos() {
  find "$WORKSPACES" -xdev \
    \( -path "${WORKSPACES}/.codespaces" -o -name '.disk-cleanup-trash.*' \) -prune -o \
    -type d -name .git -prune -print0 2>/dev/null
}

# Never touch a repo mid-operation: gc during a rebase, or racing a running
# git, is how you turn a space problem into a data problem.
git_repo_busy() {
  local g="$1/.git"
  [[ -e "$g/index.lock" ]] && return 0
  [[ -d "$g/rebase-merge" || -d "$g/rebase-apply" ]] && return 0
  [[ -e "$g/MERGE_HEAD" || -e "$g/BISECT_LOG" || -e "$g/CHERRY_PICK_HEAD" ]] && return 0
  return 1
}

# echoes "<pack_kib> <garbage_kib> <loose_kib>"; KiB, as count-objects reports
git_sizes() {
  local out
  out=$(git -C "$1" count-objects -v 2>/dev/null) || return 1
  awk '/^size:/{l=$2} /^size-pack:/{p=$2} /^size-garbage:/{g=$2}
       END{printf "%d %d %d", p+0, g+0, l+0}' <<<"$out"
}

# Tier 4: delete only what git itself classifies as garbage - stale tmp_pack_*
# / tmp_idx_* left by a dead process. The age guard keeps us off a pack that a
# currently-running git is still writing.
drop_git_garbage() {
  local repo="$1" f n=0
  if git_repo_busy "$repo"; then
    printf '  skip    %-52s (git operation in progress)\n' "$repo"
    return 0
  fi
  while IFS= read -r -d '' f; do
    purge_path "$f"
    n=$((n+1))
  done < <(find "$repo/.git/objects/pack" -maxdepth 1 -type f \
             \( -name 'tmp_pack_*' -o -name 'tmp_idx_*' \) \
             -mmin "+$(( GIT_TMP_AGE_H * 60 ))" -print0 2>/dev/null)
  return 0
}

# ---- status is read-only, so handle it before any of the reporting ---------
if [[ "$STAGE" == status ]]; then
  printf '== disk-cleanup status ==  offload root: %s\n\n' "$OFFLOAD_ROOT"
  for p in "${OFFLOAD_PATHS[@]}"; do status_path "$p"; done
  printf '\n'
  df -h "$WORKSPACES" /tmp 2>/dev/null | tail -n +1
  exit 0
fi

# ---- run -------------------------------------------------------------------
START_AVAIL=$(avail_bytes "$WORKSPACES")
printf '== disk-cleanup: %s ==  dry-run=%s defer=%s sizes=%s\n' \
  "$STAGE" "$DRY_RUN" "$DEFER" "$SIZES"
df -h "$WORKSPACES" | tail -1
if (( SIZES )); then log 'note: --sizes runs du per path; expect minutes on this disk'; fi
printf '\n'

case "$STAGE" in

purge)
  sweep_stale_trash
  log 'Tier 1: caches (zero risk)'
  purge_cmd "uv cache"  "${HOME_DIR}/.cache/uv" uv cache clean
  purge_cmd "npm cache" "${HOME_DIR}/.npm"      npm cache clean --force
  purge_path "${HOME_DIR}/.cache/ms-playwright"
  purge_path "${HOME_DIR}/.cache/pip"
  purge_path "${HOME_DIR}/.cache/pip-audit"
  purge_path "${HOME_DIR}/.cache/node-gyp"
  purge_path "${HOME_DIR}/.cache/codeburn"
  purge_path "${HOME_DIR}/.cache/typescript"
  purge_path "${HOME_DIR}/.cache/puppeteer"
  purge_path "${HOME_DIR}/.cache/yarn"
  purge_path "${HOME_DIR}/.cache/go-build"
  log 'Tier 1 done'
  printf '\n'

  if (( RUN_T2 )); then
    log 'Tier 2: tool data and downloaded models (re-download cost)'
    # uv-managed Python interpreters and tools; venvs created via `uv python`
    # will need to re-fetch their interpreter after this.
    purge_path "${HOME_DIR}/.local/share/uv"
    purge_path "${HOME_DIR}/.local/share/kokoro-models"
    purge_path "${HOME_DIR}/.local/share/piper-models"
    purge_path "${HOME_DIR}/.local/share/powershell"
    purge_path "${HOME_DIR}/.cache/powershell"
    # NOTE: ~/.local/share/claude (Claude CLI data, ~925M) is intentionally NOT
    # touched - it may hold wanted session history. Remove it by hand if needed.
    log 'Tier 2 done'
    printf '\n'
  fi

  if (( RUN_T3 )); then
    log "Tier 3: scanning ${WORKSPACES} for build artifacts (single pass, ~3min)"
    candidates=()
    while IFS= read -r -d '' dir; do
      # Rust target dirs only when a sibling Cargo.toml confirms it is a build dir.
      if [[ "$(basename -- "$dir")" == target && ! -f "$(dirname -- "$dir")/Cargo.toml" ]]; then
        continue
      fi
      candidates+=( "$dir" )
    done < <(find_artifacts)
    log "Tier 3: scan complete, ${#candidates[@]} directories to remove"
    for dir in ${candidates[@]+"${candidates[@]}"}; do
      purge_path "$dir"
    done
    log 'Tier 3 done'
    printf '\n'
  fi

  if (( RUN_T4 )); then
    log "Tier 4: abandoned git pack files across ${WORKSPACES} (zero risk)"
    grepos=()
    while IFS= read -r -d '' g; do grepos+=( "$(dirname -- "$g")" ); done < <(find_git_repos)
    log "Tier 4: ${#grepos[@]} repositories to check"
    for r in ${grepos[@]+"${grepos[@]}"}; do drop_git_garbage "$r"; done
    log 'Tier 4 done'
    printf '\n'
  fi

  if (( DEFER )); then flush_trash; fi
  ;;

git)
  log "Scanning ${WORKSPACES} for git repositories (single pass, ~3min)"
  grepos=()
  while IFS= read -r -d '' g; do grepos+=( "$(dirname -- "$g")" ); done < <(find_git_repos)
  log "found ${#grepos[@]} repositories"
  printf '\n'
  printf '  %9s %9s %9s  %s\n' PACK GARBAGE LOOSE REPOSITORY
  rows=(); tot_g=0; tot_p=0
  for r in ${grepos[@]+"${grepos[@]}"}; do
    s=$(git_sizes "$r") || continue
    read -r pk gb ls <<<"$s"
    tot_g=$(( tot_g + gb )); tot_p=$(( tot_p + pk ))
    rows+=( "$(printf '%012d %s %s %s %s' "$(( pk + gb ))" "$pk" "$gb" "$ls" "$r")" )
  done
  while read -r _ pk gb ls r; do
    printf '  %9s %9s %9s  %s\n' "$(human $(( pk * 1024 )))" \
      "$(human $(( gb * 1024 )))" "$(human $(( ls * 1024 )))" "$r"
  done < <(printf '%s\n' ${rows[@]+"${rows[@]}"} | sort -rn)
  printf '\n'
  log "total packed $(human $(( tot_p * 1024 ))), of which garbage $(human $(( tot_g * 1024 )))"

  if (( ! GIT_GC )); then
    log 'survey only. --gc repacks (keeps 2 weeks of unreachable objects);'
    log '--aggressive adds --prune=now, which DISCARDS them immediately.'
  else
    printf '\n'
    if (( GIT_AGGRESSIVE )); then
      log 'WARNING: --prune=now discards unreachable objects with no grace period.'
      log 'A bad reset --hard, a dropped stash or an aborted rebase is lost.'
    fi
    for r in ${grepos[@]+"${grepos[@]}"}; do
      if git_repo_busy "$r"; then
        printf '  skip    %-52s (git operation in progress)\n' "$r"; continue
      fi
      if (( DRY_RUN )); then
        printf '  [dry-run] would gc %s\n' "$r"; continue
      fi
      before=$(git_sizes "$r") || continue; read -r bp bg _ <<<"$before"
      if (( GIT_AGGRESSIVE )); then
        git -C "$r" gc --prune=now --quiet 2>/dev/null || { printf '  warn: gc failed %s\n' "$r"; continue; }
      else
        git -C "$r" gc --quiet 2>/dev/null || { printf '  warn: gc failed %s\n' "$r"; continue; }
      fi
      after=$(git_sizes "$r") || continue; read -r ap ag _ <<<"$after"
      printf '  gc      %-52s %s -> %s\n' "$r" \
        "$(human $(( (bp + bg) * 1024 )))" "$(human $(( (ap + ag) * 1024 )))"
    done
  fi
  ;;

offload)
  log "Offload: /tmp has $(human "$(avail_bytes /tmp)") free; target ${OFFLOAD_ROOT}"
  for p in "${OFFLOAD_PATHS[@]}"; do offload_path "$p"; done
  printf '\n'
  log '/tmp is wiped on codespace stop, and a dangling link makes writes FAIL'
  log '("File exists"). Add to ~/.bashrc:'
  log "  ${BASH_SOURCE[0]} repair >/dev/null 2>&1 || true"
  if (( DEFER )); then flush_trash; fi
  ;;

repair)
  log "Repair: re-pointing offload links under ${OFFLOAD_ROOT}"
  for p in "${OFFLOAD_PATHS[@]}"; do repair_path "$p"; done
  log 'Repair done'
  ;;

restore)
  log "Restore: moving caches back off ${OFFLOAD_ROOT} onto $(df -h "$HOME_DIR" | tail -1 | awk '{print $1}')"
  log "note: this CONSUMES space on the near-full device ($(human "$(avail_bytes "$WORKSPACES")") free)"
  for p in "${OFFLOAD_PATHS[@]}"; do restore_path "$p"; done
  log 'Restore done'
  ;;

esac

printf '\n'

# ---- Summary --------------------------------------------------------------
END_AVAIL=$(avail_bytes "$WORKSPACES")
df -h "$WORKSPACES" | tail -1
if (( DRY_RUN )); then
  log 'Dry run: nothing was changed.'
elif [[ "$STAGE" == git ]] && (( ! GIT_GC )); then
  log 'Survey only: nothing was changed.'
else
  freed=$(( END_AVAIL - START_AVAIL ))
  log "Reclaimed: $(human "$freed")"
  if (( DEFER )); then log 'more will free as the background rm drains'; fi
fi
