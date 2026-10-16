#!/usr/bin/env bash
# Tests for bin/relay-init in a throwaway parent directory.
# Usage: tests/relay-init.sh

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
init=$root/bin/relay-init

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
ko() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "     $2"; }

eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected [$2], got [$3]"; fi
}

has() { # has <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then ok "$1"; else ko "$1" "no [$3] in $2"; fi
}

exists() { # exists <name> <test flag> <path>
  if test "$2" "$3"; then ok "$1"; else ko "$1" "test $2 $3 is false"; fi
}

absent() { # absent <name> <path>
  if [ -e "$2" ]; then ko "$1" "$2 exists"; else ok "$1"; fi
}

# --- usage ---------------------------------------------------------------

if "$init" demo "$tmp" --name "Demo User" >/dev/null 2>&1; then
  ko "usage: missing --email exits non-zero"
else
  ok "usage: missing --email exits non-zero"
fi
absent "usage: nothing created on usage error" "$tmp/demo"

# --- happy path ----------------------------------------------------------

key=$tmp/id_demo
echo "fake key" >"$key"
out=$("$init" demo "$tmp" --name "Demo User" --email demo@example.com \
  --ssh-key "$key" --description "A & B, \\1 backrefs, {{not a placeholder}}" 2>"$tmp/stderr")
eq "init exits 0" 0 $?
ws=$tmp/demo

exists "CLAUDE.md.in renamed to CLAUDE.md" -f "$ws/CLAUDE.md"
absent "no CLAUDE.md.in left behind" "$ws/CLAUDE.md.in"
has "{{NAME}} filled" "$ws/CLAUDE.md" "# demo — AI workspace"
has "{{DESCRIPTION}} filled verbatim" "$ws/CLAUDE.md" 'A & B, \1 backrefs, {{not a placeholder}}'
if grep -rqF '{{NAME}}' "$ws" || grep -rqF '{{DESCRIPTION}}' "$ws"; then
  ko "no placeholder left anywhere" "$(grep -rlF '{{NAME}}' "$ws"; grep -rlF '{{DESCRIPTION}}' "$ws")"
else
  ok "no placeholder left anywhere"
fi

exists "settings moved to .claude/settings.local.json" -f "$ws/.claude/settings.local.json"
absent "dot-claude removed" "$ws/dot-claude"
for d in docs/plans docs/status docs/scope repos; do
  exists "layout has $d" -d "$ws/$d"
done
exists "layout has docs/WORKFLOW.md" -f "$ws/docs/WORKFLOW.md"

# --- .gitconfig ----------------------------------------------------------

eq ".gitconfig user.name" "Demo User" "$(git config -f "$ws/.gitconfig" user.name)"
eq ".gitconfig user.email" demo@example.com "$(git config -f "$ws/.gitconfig" user.email)"
eq ".gitconfig core.sshCommand" "ssh -i '$key'" "$(git config -f "$ws/.gitconfig" core.sshCommand)"
eq ".gitconfig has no other keys" 3 "$(git config -f "$ws/.gitconfig" --list | wc -l | tr -d ' ')"

# --- workspace git repository -------------------------------------------

eq "git rev-parse works in the workspace" "true" "$(git -C "$ws" rev-parse --is-inside-work-tree 2>/dev/null)"
eq "workspace branch is main" main "$(git -C "$ws" symbolic-ref --short HEAD 2>/dev/null)"
eq "workspace has no commits" "" "$(git -C "$ws" log --oneline 2>/dev/null)"
eq ".gitignore content" "$(printf 'repos/\n.DS_Store')" "$(cat "$ws/.gitignore")"
mkdir -p "$ws/repos/x"
echo "y" >"$ws/repos/x/file"
touch "$ws/.DS_Store"
if git -C "$ws" status --porcelain --ignored | grep -q '^!! repos/'; then
  ok "repos/ is ignored by the workspace repo"
else
  ko "repos/ is ignored by the workspace repo" "$(git -C "$ws" status --porcelain --ignored)"
fi
if git -C "$ws" status --porcelain | grep -q 'DS_Store'; then
  ko ".DS_Store is ignored by the workspace repo"
else
  ok ".DS_Store is ignored by the workspace repo"
fi

# --- output --------------------------------------------------------------

case $out in *"[includeIf \"gitdir:$ws/\"]"*) ok "prints includeIf block" ;; *) ko "prints includeIf block" "$out" ;; esac
case $out in *"remote add origin"*) ok "prints how to add a private remote" ;; *) ko "prints how to add a private remote" "$out" ;; esac
case $out in *"push -u origin main"*) ok "remote hint ends with a manual push" ;; *) ko "remote hint ends with a manual push" "$out" ;; esac

# --- no ssh key, default description ------------------------------------

"$init" plain "$tmp" --name "P" --email p@example.com >/dev/null 2>&1
eq "init without --ssh-key exits 0" 0 $?
if git config -f "$tmp/plain/.gitconfig" core.sshCommand >/dev/null 2>&1; then
  ko "no core.sshCommand without --ssh-key"
else
  ok "no core.sshCommand without --ssh-key"
fi
has "default description is a TODO" "$tmp/plain/CLAUDE.md" "TODO: one paragraph on what plain is."

# --- refuses overwrite ---------------------------------------------------

echo "keep" >"$ws/marker"
if "$init" demo "$tmp" --name "Demo User" --email demo@example.com >/dev/null 2>"$tmp/stderr"; then
  ko "refuses to overwrite an existing workspace"
else
  ok "refuses to overwrite an existing workspace"
fi
has "overwrite refusal names the path" "$tmp/stderr" "already exists, not overwriting: $ws"
eq "existing workspace untouched" keep "$(cat "$ws/marker")"

# --- invalid names -------------------------------------------------------

for bad in "a/b" ".hidden" "two words"; do
  if "$init" "$bad" "$tmp" --name "P" --email p@example.com >/dev/null 2>&1; then
    ko "rejects name [$bad]"
  else
    ok "rejects name [$bad]"
  fi
done

# --- summary -------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
