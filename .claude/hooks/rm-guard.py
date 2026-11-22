#!/usr/bin/env python3
"""PreToolUse guard for Bash rm, rmdir, mkdir and mv: force a prompt unless every target sits inside a root.

Pairs with the user-level allow rules for rm/rmdir/mkdir under the same roots. Text-matching allow rules
can be fooled by `..`, wrappers, extra operands or variables; this hook resolves each target with realpath
and asks whenever any target is outside the roots or cannot be resolved statically. It never allows on its
own, and it is not a boundary (find -delete, git clean, python3 -c and redirects bypass it); it restores the
prompt that the removed blanket ask rules used to give. Policy and design: rm-guard.md next to this file.
"""

import json
import os
import re
import shlex
import sys

# Policy (documented in rm-guard.md next to this file):
# - SCRATCH roots: rm, rmdir, mkdir (and mv, still behind its ask rule) run without a prompt.
# - CREATE roots: mkdir only (creation cannot destroy data), relative paths included;
#   plus rm/rmdir of regenerable tool caches (CACHE_NAMES).
# - Anything else, and every rm/rmdir/mv in a repo: ask.
ROOTS = ("/tmp", "/home/vscode/wt", "/home/vscode/cdpb")  # nosec B108 - policy roots, not temp-file creation
CREATE_ROOTS = ROOTS + ("/workspaces",)
# Regenerable tool caches: rm/rmdir of these is allowed anywhere under CREATE_ROOTS, relative paths included.
CACHE_NAMES = {"__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache", "node_modules", "htmlcov", ".coverage"}
COMMANDS = {"rm", "rmdir", "mkdir", "mv"}
# Reason: Claude Code strips these before matching allow rules, so the guard must look past them too.
WRAPPERS = {"command", "builtin", "nice", "nohup", "time", "timeout", "stdbuf", "noglob", "sudo", "env", "xargs"}
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!"}
WRAPPER_ARG = re.compile(r"^[+-]?\d+(\.\d+)?[smhd]?$")
FD_REDIRECT = re.compile(r"(?<![\w/&|>])(?:\d*>>?&\d+-?|&>>?\s*/dev/null|\d*>>?\s*/dev/null)(?![\w/])")
NULL_REDIRECT = re.compile(r"^\d*>>?(/dev/null|&\d)$")
UNSAFE = re.compile(r"[$`~{}()<>*?\[\]]")
GLOB_ONLY = re.compile(r"[*?\[\]]")
# Reason: the session scratch tree is shared by every live session; only paths below a session dir pass.
SHARED = re.compile(r"^/tmp/claude-\d+(/[^/]+){0,2}$")
SEPARATORS = re.compile(r"&&|\|\||\|&|[;|&\n]")
CMD_AT_START = re.compile(
    r"^(?:\w+=\S*\s+|(?:command|builtin|nice|nohup|time|timeout|stdbuf|xargs|noglob|sudo|env)\s+(?:-\S+\s+)*)*"
    r"(?:\S*/)?(?:rm|rmdir|mkdir|mv)(?:\s|$)"
)
OPERATORS = {"&&", "||", ";", "|", "|&", "&", ";;", "\n"}


def inside_roots(path: str, roots: tuple[str, ...] = ROOTS) -> bool:
    """True only for paths strictly below a root, so a root itself is never touched without a prompt."""
    real = os.path.realpath(path)
    return any(real.startswith(root + "/") for root in roots)


HEREDOC = re.compile(r"(\S*)[ \t]*<<-?[ \t]*(['\"]?)(\w+)\2[^\n]*\n(.*?)\n[ \t]*\3[ \t]*(?=\n|$)", re.S)
SHELLS = {"bash", "sh", "zsh", "dash"}


def strip_heredocs(command: str) -> str:
    """Drop heredoc bodies (data, often with stray quotes), except bodies fed to a shell, which are commands."""
    def keep_or_drop(match: re.Match) -> str:
        line_start = command.rfind("\n", 0, match.start()) + 1
        line = command[line_start:match.start()] + match.group(1)
        fed_to_shell = any(os.path.basename(w) in SHELLS for w in line.split())
        head = match.group(0).split("\n", 1)[0]
        return match.group(0) if fed_to_shell else head + "\n"
    return HEREDOC.sub(keep_or_drop, command)


def strip_comments(command: str) -> str:
    """Drop shell comments: an unquoted '#' at the start of a word up to the newline (bash semantics).

    Reason: shlex cannot tell a quoted "#" operand from a comment, and a quoted '#' must stay an operand.
    """
    out, quote, i, n = [], "", 0, len(command)
    while i < n:
        ch = command[i]
        if quote:
            if ch == "\\" and quote == '"' and i + 1 < n:
                out.append(command[i:i + 2])
                i += 2
                continue
            out.append(ch)
            if ch == quote:
                quote = ""
        elif ch == "\\" and i + 1 < n:
            out.append(command[i:i + 2])
            i += 2
            continue
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "#" and (i == 0 or command[i - 1] in " \t\n;&|()"):
            while i < n and command[i] != "\n":
                i += 1
            continue
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def segments(command: str) -> list[list[str]] | None:
    """Split into command word lists on shell operators, respecting quotes; None when unparseable."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        tokens = list(lexer)
    except ValueError:
        return None
    out: list[list[str]] = [[]]
    for token in tokens:
        if token in OPERATORS or set(token) <= set(";&|\n"):
            out.append([])
        else:
            out[-1].append(token)
    return [words for words in out if words]


VAR_REF = re.compile(r"\$(?:\{(\w+)\}|(\w+))")
ASSIGN = re.compile(r"^([A-Za-z_]\w*)=(.*)$", re.S)


def expand(target: str, env: dict[str, str]) -> str:
    """Substitute $NAME / ${NAME} set literally earlier in the same command; unknown names stay and later ask."""
    return VAR_REF.sub(lambda m: env.get(m.group(1) or m.group(2), m.group(0)), target)


def record_assignments(words: list[str], env: dict[str, str]) -> bool:
    """For a segment made only of NAME=value words, remember literal values; return True if it was such a segment."""
    if not words or not all(ASSIGN.match(w) for w in words):
        return False
    for word in words:
        name, value = ASSIGN.match(word).groups()
        value = expand(value, env)
        if UNSAFE.search(value):
            env.pop(name, None)
        else:
            env[name] = value
    return True


def track_cd(words: list[str], cwd: str | None, env: dict[str, str], subshells: bool) -> str | None:
    """Return the working directory after a literal `cd`; None (unknown) for anything not statically certain."""
    if subshells:
        return None  # Reason: a cd inside ( ... ) does not outlive the subshell; we cannot see where it ends.
    if len(words) == 1:
        return os.path.expanduser("~")
    dest = expand(words[1], env)
    if len(words) > 2 or dest == "-" or UNSAFE.search(dest) or cwd is None and not os.path.isabs(dest):
        return None
    dest = os.path.realpath(os.path.join(cwd or "/", dest))
    # Reason: "cd /missing; rm x" would run rm in the old directory; only trust a cd that will succeed.
    return dest if os.path.isdir(dest) else None


def command_word(words: list[str]) -> tuple[str, list[str], bool, bool]:
    """Skip wrappers, keywords, assignments and wrapper arguments; return (cmd, operands, via_xargs, saw_wrapper)."""
    words = list(words)
    via_xargs = saw_wrapper = False
    while words:
        word = words[0].lstrip("({")
        if word and not (word in WRAPPERS or word in KEYWORDS or "=" in word
                         or word.startswith("-") or WRAPPER_ARG.match(word)):
            words[0] = word
            break
        via_xargs = via_xargs or word == "xargs"
        saw_wrapper = saw_wrapper or word in WRAPPERS
        words.pop(0)
    cmd = os.path.basename(words[0]) if words else ""
    return cmd, words[1:], via_xargs, saw_wrapper


def collect_targets(cmd: str, operands: list[str], env: dict[str, str]) -> tuple[list[str], str | None]:
    """Return the expanded non-option operands, or a reason when an operand cannot be judged."""
    targets, options_done = [], False
    for word in operands:
        if any(ord(c) < 32 for c in word):
            return [], f"{cmd} operand contains a control character"
        if NULL_REDIRECT.match(word):
            continue
        if not options_done and word == "--":
            options_done = True
            continue
        if not options_done and word.startswith("-"):
            # Reason: mv -t/--target-directory names a destination inside an option, where operand checks miss it.
            if cmd == "mv" and re.match(r"^(-[a-zA-Z]*t|--t)", word):
                return [], f"mv option '{word}' names a target directory"
            continue
        targets.append(expand(word, env))
    return targets, None


def check_mkdir(target: str) -> str | None:
    """Creating a directory cannot destroy data; relative paths land in the session's repo or scratch dir."""
    if ".." in target.split("/"):
        return f"mkdir target '{target}' contains '..'"
    if UNSAFE.search(target):
        # Reason: loop variables ("for r in ...; mkdir -p /workspaces/x/$r-src") cannot be resolved statically;
        # creation is harmless when the literal part before the first expansion already sits inside a root.
        prefix = os.path.dirname(target[:UNSAFE.search(target).start()])
        if not (os.path.isabs(prefix) and inside_roots(prefix + "/x", CREATE_ROOTS) and "~" not in target):
            return f"mkdir target '{target}' uses expansion or a glob outside a literal root prefix"
        return None
    # Reason: "mkdir -p /home/vscode/wt" (the root itself) is harmless; only rm/rmdir must stay strictly below.
    if os.path.isabs(target) and not (inside_roots(target, CREATE_ROOTS) or os.path.realpath(target) in CREATE_ROOTS):
        return f"mkdir target '{target}' is outside {', '.join(CREATE_ROOTS)}"
    return None


def check_cache(cmd: str, target: str, cwd: str | None) -> str | None:
    """Tool caches are regenerated by the next run; deleting one cannot lose work."""
    if UNSAFE.search(target) or ".." in target.split("/"):
        return f"{cmd} cache target '{target}' uses expansion, a glob or '..'"
    if os.path.isabs(target) and not inside_roots(target, CREATE_ROOTS):
        return f"{cmd} cache target '{target}' is outside {', '.join(CREATE_ROOTS)}"
    # Reason: "rm -rf node_modules/" through a symlink deletes the link's target tree.
    if os.path.islink(os.path.join(cwd or os.getcwd(), target).rstrip("/")):
        return f"{cmd} cache target '{target}' is a symlink"
    return None


def check_glob(cmd: str, target: str) -> str | None:
    """A glob cannot climb above its literal prefix: pass when that prefix sits strictly below a scratch root.

    Reason: "rm $S/*.md" in a session scratchpad is routine. The prefix must be outside the shared tree, and no
    glob part may start with '.' (which could match '..' where globskipdots is off).
    """
    literal = target[:GLOB_ONLY.search(target).start()]
    prefix = os.path.dirname(literal) if not literal.endswith("/") else literal.rstrip("/")
    rest = target[len(prefix):]
    if (os.path.isabs(prefix) and ".." not in target.split("/") and inside_roots(prefix)
            and not SHARED.match(os.path.realpath(prefix))
            and not any(part.startswith(".") and GLOB_ONLY.search(part) for part in rest.split("/"))):
        return None
    return f"{cmd} target '{target}' uses a glob outside a session or scratch folder"


def check_plain(cmd: str, target: str, cwd: str | None) -> str | None:
    """A plain rm/rmdir/mv target must resolve strictly below a scratch root, outside the shared tree."""
    if UNSAFE.search(target):
        return f"{cmd} target '{target}' uses shell expansion or a glob"
    if not os.path.isabs(target):
        if cwd is None or ".." in target.split("/"):
            return f"{cmd} target '{target}' is relative and the working directory is not certain"
        # Reason: a relative target is judged where it will land: the session cwd plus any literal cd before it.
        target = os.path.join(cwd, target)
    if ".." in target.split("/"):
        return f"{cmd} target '{target}' contains '..'"
    if not inside_roots(target):
        return f"{cmd} target '{target}' resolves outside {', '.join(ROOTS)}"
    if SHARED.match(os.path.realpath(target)):
        return f"{cmd} target '{target}' is a shared session scratch directory"
    return None


def check_target(cmd: str, target: str, cwd: str | None) -> str | None:
    """Route one target to the rule for its kind."""
    if cmd == "mkdir":
        return check_mkdir(target)
    if cmd in ("rm", "rmdir") and os.path.basename(target.rstrip("/")) in CACHE_NAMES:
        return check_cache(cmd, target, cwd)
    if GLOB_ONLY.search(target) and not re.search(r"[$`~{}()<>]", target) and cmd != "mv":
        return check_glob(cmd, target)
    return check_plain(cmd, target, cwd)


def outside_target(words: list[str], env: dict[str, str] | None = None, cwd: str | None = None) -> str | None:
    """Return a reason when this rm/rmdir/mkdir/mv touches something outside ROOTS, else None."""
    cmd, operands, via_xargs, saw_wrapper = command_word(words)
    if cmd not in COMMANDS:
        # Reason: wrapper options that take a value ("timeout -s KILL rm", "env -u X rm") shift the command word;
        # if a guarded name still follows a wrapper, the parse is not certain, so ask.
        if saw_wrapper and any(os.path.basename(w) in COMMANDS for w in words):
            return "a wrapper with options precedes a guarded command and could not be parsed with certainty"
        return None
    if via_xargs:
        return f"{cmd} takes its targets from xargs input"
    targets, reason = collect_targets(cmd, operands, env or {})
    if reason:
        return reason
    for target in targets:
        reason = check_target(cmd, target, cwd)
        if reason:
            return reason
    return None


def makes_symlink(words: list[str]) -> bool:
    """True for ln, or cp with -s/--symbolic-link."""
    names = {os.path.basename(w) for w in words}
    if "ln" in names:
        return True
    return "cp" in names and any(w in ("-s", "--symbolic-link") or re.match(r"^-[a-zA-Z]*s", w) for w in words)


def segment_reasons(parsed: list[list[str]], command: str, cwd: str | None) -> list[str]:
    """Walk the segments in order, tracking literal assignments, cd and symlink creation; collect ask reasons."""
    env: dict[str, str] = {}
    reasons = []
    subshells = bool(any(w.startswith("(") for words in parsed for w in words)
                     or re.search(r"\b(pushd|popd)\b", command))
    symlinked = False
    for words in parsed:
        # Reason: "D=/tmp/x; mkdir -p $D" is a common agent idiom; literal assignments are resolved, not guessed.
        if record_assignments(words, env):
            continue
        if words[0].lstrip("({") == "cd":
            cwd = track_cd([w.lstrip("({") for w in words], cwd, env, subshells)
            continue
        # Reason: a symlink made earlier in the same command does not exist yet when realpath runs.
        if makes_symlink(words):
            symlinked = True
        elif symlinked and any(os.path.basename(w) in ("rm", "rmdir") for w in words):
            reasons.append("a symlink is created earlier in the same command")
            continue
        reason = outside_target(words, env, cwd)
        if reason:
            reasons.append(reason)
    return reasons


def main() -> None:
    data = json.load(sys.stdin)
    command = (data.get("tool_input") or {}).get("command", "")
    if not re.search(r"\b(rm|rmdir|mkdir|mv)\b", command):
        return
    command = strip_heredocs(command)
    # Reason: bash joins backslash-newline continuations before splitting words; do the same.
    command = strip_comments(command.replace("\\\n", ""))
    # Reason: shlex splits "2>&1" on '&' into a fake operator and operand; fd duplications and /dev/null
    # redirects never name a target, so remove them before lexing.
    command = FD_REDIRECT.sub(" ", command)
    parsed = segments(command)
    if parsed is None:
        # Reason: only an unparseable command that visibly starts a guarded segment is suspicious;
        # quotes or heredocs that merely mention the commands (commit messages, greps) pass through.
        lines = (part.strip() for part in SEPARATORS.split(command))
        reasons = ["command could not be parsed"] if any(CMD_AT_START.match(p) for p in lines) else []
    else:
        cwd = data.get("cwd")
        reasons = segment_reasons(parsed, command, cwd if isinstance(cwd, str) and os.path.isabs(cwd) else None)
    if reasons:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": f"rm-guard: {reasons[0]}",
        }}))


if __name__ == "__main__":
    main()
