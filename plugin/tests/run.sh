#!/usr/bin/env bash
# Tests for bin/relay-prompt and hooks/guard-commit.sh in a throwaway workspace.
# Usage: plugin/tests/run.sh

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(dirname "$here")
rp=$plugin/bin/relay-prompt
guard=$plugin/hooks/guard-commit.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
ko() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "     $2"; }

eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected [$2], got [$3]"; fi
}

# --- workspace layout ----------------------------------------------------

ws=$tmp/ws
mkdir -p "$ws"/docs/{plans,status} "$ws"/repos
echo "# WORKFLOW" >"$ws/docs/WORKFLOW.md"

prompt() { # prompt <name> <status> <mtime YYYYMMDDhhmm>
  cat >"$ws/docs/plans/$1" <<EOF
---
model: sonnet
status: $2        # pending | running | done | failed
repo: demo
branch: feat/x
---
# Body of $1

status: not front matter
EOF
  touch -t "$3" "$ws/docs/plans/$1"
}

prompt demo.prompt-1.md "done" 202601010000
prompt demo.prompt-2.md pending 202601020000
prompt other.prompt-2.md pending 202601030000
prompt demo.prompt-3.md failed 202601040000
echo "notes, not a prompt" >"$ws/docs/plans/demo.md"

# --- relay-prompt get ----------------------------------------------------

eq "get status strips comment" pending "$("$rp" get "$ws/docs/plans/demo.prompt-2.md" status)"
eq "get branch" feat/x "$("$rp" get "$ws/docs/plans/demo.prompt-2.md" branch)"
if "$rp" get "$ws/docs/plans/demo.prompt-2.md" worktree >/dev/null 2>&1; then
  ko "get missing key exits non-zero"
else
  ok "get missing key exits non-zero"
fi
if "$rp" get "$ws/docs/plans/demo.md" status >/dev/null 2>&1; then
  ko "get without front matter exits non-zero"
else
  ok "get without front matter exits non-zero"
fi

# --- relay-prompt next ---------------------------------------------------

eq "next: highest number, then newest mtime" \
  "$ws/docs/plans/other.prompt-2.md" "$("$rp" next "$ws")"

# --- relay-prompt set ----------------------------------------------------

f=$ws/docs/plans/other.prompt-2.md
before_body=$(sed -n '/^# Body/,$p' "$f")
"$rp" set "$f" status running
eq "set existing key" running "$("$rp" get "$f" status)"
eq "set keeps trailing comment" \
  "status: running        # pending | running | done | failed" "$(grep '^status:' "$f" | head -n 1)"
eq "set leaves body untouched" "$before_body" "$(sed -n '/^# Body/,$p' "$f")"
eq "set touches only front matter" "status: not front matter" "$(grep '^status: not' "$f")"

"$rp" set "$f" worktree plugin
eq "set adds missing key" plugin "$("$rp" get "$f" worktree)"
eq "added key stays inside front matter" 2 "$(grep -c '^---$' "$f")"

eq "next skips non-pending" "$ws/docs/plans/demo.prompt-2.md" "$("$rp" next "$ws")"

"$rp" set "$ws/docs/plans/demo.prompt-2.md" status "done"
if out=$("$rp" next "$ws"); then
  ko "next exits 1 when nothing is pending" "printed $out"
else
  eq "next exits 1 when nothing is pending" "" "$out"
fi

# --- guard-commit.sh -----------------------------------------------------

repo=$ws/repos/demo
git init -q -b main "$repo"

hook() { # hook <cwd> <command>; prints exit code
  local json
  json=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$2")
  "$guard" <<<"$json" 2>"$tmp/stderr" >/dev/null
  echo $?
}

echo "code" >"$repo/main.sh"
git -C "$repo" add main.sh
eq "guard allows a normal file" 0 "$(hook "$repo" "git commit -m test")"

mkdir -p "$repo/.claude"
echo "{}" >"$repo/.claude/settings.local.json"
git -C "$repo" add -f .claude/settings.local.json
eq "guard refuses settings.local.json" 2 "$(hook "$repo" "git commit -m test")"
if grep -q "settings.local.json" "$tmp/stderr"; then
  ok "guard names the offending path"
else
  ko "guard names the offending path" "$(cat "$tmp/stderr")"
fi
eq "guard handles cd <repo> && git commit" 2 "$(hook "$ws" "cd repos/demo && git commit -m test")"
eq "guard ignores non-commit commands" 0 "$(hook "$repo" "git status")"
git -C "$repo" rm -q --cached .claude/settings.local.json

mkdir -p "$repo/docs"
echo "x" >"$repo/docs/plan.md"
git -C "$repo" add docs/plan.md
eq "guard refuses docs/ inside a workspace repo" 2 "$(hook "$repo" "git commit -m test")"
if grep -q "docs/plan.md" "$tmp/stderr" && ! grep -q "settings.local.json" "$tmp/stderr"; then
  ok "guard reports only the docs/ path"
else
  ko "guard reports only the docs/ path" "$(cat "$tmp/stderr")"
fi
git -C "$repo" rm -q --cached docs/plan.md

plain=$tmp/plain
git init -q -b main "$plain"
mkdir -p "$plain/docs"
echo "x" >"$plain/docs/guide.md"
git -C "$plain" add docs/guide.md
eq "guard allows docs/ outside a workspace" 0 "$(hook "$plain" "git commit -m test")"

echo "x" >"$plain/notes.local.md"
git -C "$plain" add -f notes.local.md
eq "guard refuses *.local.md anywhere" 2 "$(hook "$plain" "git commit -m test")"

# --- summary -------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
