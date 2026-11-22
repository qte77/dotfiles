#!/usr/bin/env bash
# Regression matrix for rm-guard.py. Usage: bash ~/.claude/hooks/rm-guard-test.sh  (exit 1 on any mismatch)
set -uo pipefail
hook="$(dirname "$0")/rm-guard.py"
fail=0
check() {  # check <pass|ask> <command> [cwd]
  local want=$1 cmd=$2 cwd=${3:-} out got
  out=$(jq -cn --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c}} + (if $d == "" then {} else {cwd:$d} end)' | python3 -I "$hook")
  [ -n "$out" ] && got=ask || got=pass
  if [ "$got" != "$want" ]; then fail=1; printf 'FAIL want=%s got=%s: %s\n' "$want" "$got" "$(printf '%s' "$cmd" | tr '\n' '~')"; fi
}
nl=$'\n'
# --- scratch roots: free
check pass "rm -rf /tmp/claude-1000/proj/sess/scratchpad/x"
check pass "rm -f /home/vscode/cdpb/a /home/vscode/cdpb/b"
check pass "rm -rf /home/vscode/wt/old-worktree"
check pass "rm -rf /tmp/x 2>/dev/null"
check pass "rm -rf /tmp/x # cleanup"
check pass "rmdir /tmp/claude-1000/proj/sess/scratchpad/empty"
check pass "mv /tmp/a/b /tmp/a/c"
# --- mkdir: free in scratch roots and repos (creation only)
check pass "mkdir -p /home/vscode/wt/new"
check pass "mkdir -p .github/workflows"
check pass "mkdir -p src/new && touch-free-echo"
check pass "mkdir -p /workspaces/qte77/x/y"
# --- text that only mentions the commands
check pass "git commit -m \"fix; don't rm the thing\""
check pass 'grep -n "rm -rf" file'
check pass "git rm --cached a.pyc"
check pass "cat > /tmp/x.sh <<'EOF'${nl}mkdir -p out${nl}it's done${nl}EOF"
check pass "python3 - f <<'EOF'${nl}s='rm -rf /x'${nl}print(\"it's\")${nl}EOF"
# --- literal variables set earlier in the same command
check pass "D=/tmp/claude-1000/p/s/scratchpad/leap71; mkdir -p \$D; ls \$D"
check pass "D=/home/vscode/cdpb/x && rm -rf \"\$D\"/old"
check pass "B=/tmp/claude-1000/p/s; D=\$B/scratchpad/y; rm -rf \${D}"
# --- regenerable caches, anywhere under /workspaces or scratch
check pass "rm -rf tests/fixtures/__pycache__ && python3 -c 1"
check pass "rm -rf .pytest_cache .ruff_cache .mypy_cache"
check pass "rm -rf /workspaces/qte77/x/node_modules"
# --- globs inside a folder strictly below a scratch root (not the shared session tree)
check pass "S=/tmp/claude-1000/-ws/4fca/scratchpad; rm \$S/*.md; ls \$S"
check pass "rm -f /home/vscode/cdpb/briefs/*.bak"
check pass "rm -rf /home/vscode/wt/old/*"
check ask "rm -rf /home/vscode/wt/*"
check ask "rm -rf /tmp/x/.*"
check ask "rm -rf /tmp/x/.?/y"
check ask "rm -rf /tmp/x/../*"
check ask "rm -rf /tmp/claude-1000/*/scratchpad"
check ask "rm -rf /workspaces/qte77/x/*.md"
check ask "mv /tmp/a/* /tmp/b/"
# --- must ask
check ask "rm -rf tests/fixtures/__pycache__ src"
check ask "rm -rf ../other/__pycache__"
check ask "rm -rf /etc/__pycache__"
check ask "rm -rf */__pycache__"
check ask "D=/workspaces/qte77; rm -rf \$D/x"
check ask "D=\$(pwd); rm -rf \$D"
check ask "rm -rf \$UNSET/x"
check ask "D=/tmp; rm -rf \$D"
check ask "rm -rf /tmp"
check ask "rm -rf /tmp/*"
check ask "rm -rf /tmp/claude-1000"
check ask "rm -rf /tmp/claude-1000/*"
check ask "rm foo.txt"
check ask "rm -rf /workspaces/qte77/x"
check ask "rm -rf /tmp/a /workspaces/q"
check ask "rm -rf /tmp/../workspaces/q"
check ask "timeout 30 rm -rf /tmp/../workspaces/q"
check ask "nice -n 5 rm -rf /workspaces/q"
check ask "stdbuf -o0 rm -rf /workspaces/q"
check ask "find /tmp/x | xargs rm -rf"
check ask "(rm -rf /workspaces/q)"
check ask "if true; then rm -rf /workspaces/q; fi"
check ask "rm -rf \$HOME/x"
check ask "rm -rf ~/x"
check ask "/bin/rm -rf /workspaces/q"
check ask "x=1 rm -rf /workspaces/q"
check ask "cd /tmp${nl}rm -rf /workspaces/b"
check ask "rm -- -foo /tmp/x"
check ask "bash <<'EOF'${nl}rm -rf /workspaces/q${nl}EOF"
check ask "mkdir -p ../outside"
check ask "mkdir -p /etc/x"
check pass "mkdir -p /home/vscode/.claude/x"   # ~/.claude is a symlink into /workspaces/.claude-files; creation only
check pass "cd /home/vscode/wt 2>/dev/null || mkdir -p /home/vscode/wt && cd /home/vscode/wt"
check pass "mkdir -p /home/vscode/cdpb"
check ask "mkdir -p /home/vscode"
check ask "rmdir /home/vscode/wt"
check ask "mkdir \$X"
check ask "mkdir -p \$X/sub"
check ask "mkdir -p /\$X/sub"
check ask "mkdir -p /etc/\$r"
check ask "mkdir -p /workspaces/a/../\$r"
check ask "mkdir -p ~/\$r"
check pass "for s in a b; do r=\${s%%:*}; mkdir -p /workspaces/temp/t/\$r-src; done"
check pass "mkdir -p /tmp/x/\${r}/y"
check ask "mv /tmp/a /workspaces/qte77/x"
check ask "mv -t /workspaces /tmp/a"
check ask "rm -rf /workspaces/q 'unterminated"
# --- relative targets resolved against the session cwd plus literal cd (dirs must exist)
mkdir -p /tmp/rmg-test/work
check pass "rm -f work/PWNED" /tmp/rmg-test
check pass "cd work; rm -f x; cd ..; rm -f work/y" /tmp/rmg-test
check ask "rm -f work/PWNED" /workspaces/qte77
check ask "rm -f work/PWNED"
check ask "cd /workspaces/qte77 && rm -f x" /tmp/rmg-test
check ask "cd /tmp/rmg-test/missing; rm -f x" /workspaces/qte77
check ask "(cd /tmp/rmg-test); rm -f x" /workspaces/qte77
check ask "( true; cd /tmp/rmg-test ); rm -f x" /workspaces/qte77
check ask "cd \$D && rm x" /tmp/rmg-test
check ask "cd -; rm x" /tmp/rmg-test
check ask "pushd /tmp/rmg-test; rm x" /workspaces/qte77
check ask "rm -f ../x" /tmp/rmg-test/work
check ask "cd; rm -f x" /tmp/rmg-test
check pass "D=/tmp/rmg-test; cd \$D; rm -f work/a" /workspaces/qte77
rmdir /tmp/rmg-test/work /tmp/rmg-test
[ "$fail" -eq 0 ] && echo "rm-guard: all cases OK"
exit "$fail"
