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
status: $2        # pending | running | blocked | done | failed
repo: demo
branch: feat/x
---
# Body of $1

status: not front matter
EOF
  touch -t "$3" "$ws/docs/plans/$1"
}

prompt demo.prompt-1.md "done" 202601010000
prompt demo.prompt-2.md pending 202601030000
prompt other.prompt-2.md pending 202601020000
prompt demo.prompt-3.md failed 202601040000
prompt other.prompt-4.md blocked 202601050000
prompt other.prompt-5.md pending 202601060000
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

eq "next: lowest number, then oldest mtime" \
  "$ws/docs/plans/other.prompt-2.md" "$("$rp" next "$ws")"

# --- relay-prompt set ----------------------------------------------------

f=$ws/docs/plans/other.prompt-2.md
before_body=$(sed -n '/^# Body/,$p' "$f")
"$rp" set "$f" status running
eq "set existing key" running "$("$rp" get "$f" status)"
eq "set keeps trailing comment" \
  "status: running        # pending | running | blocked | done | failed" "$(grep '^status:' "$f" | head -n 1)"
eq "set leaves body untouched" "$before_body" "$(sed -n '/^# Body/,$p' "$f")"
eq "set touches only front matter" "status: not front matter" "$(grep '^status: not' "$f")"

"$rp" set "$f" worktree plugin
eq "set adds missing key" plugin "$("$rp" get "$f" worktree)"
eq "added key stays inside front matter" 2 "$(grep -c '^---$' "$f")"

eq "next skips running" "$ws/docs/plans/demo.prompt-2.md" "$("$rp" next "$ws")"

"$rp" set "$ws/docs/plans/demo.prompt-2.md" status "done"
eq "next skips done, failed and blocked" "$ws/docs/plans/other.prompt-5.md" "$("$rp" next "$ws")"

"$rp" set "$ws/docs/plans/other.prompt-5.md" status blocked
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

git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m init
mkdir -p "$repo/docs/scope" "$repo/docs/plans"
echo "x" >"$repo/docs/README.md"
git -C "$repo" add docs/README.md
eq "guard allows a plain docs/README.md" 0 "$(hook "$repo" "git commit -m test")"

echo "x" >"$repo/docs/plans/demo.prompt-1.md"
git -C "$repo" add docs/plans/demo.prompt-1.md
eq "guard refuses docs/**/*.prompt-*.md" 2 "$(hook "$repo" "git commit -m test")"
if grep -q "docs/plans/demo.prompt-1.md" "$tmp/stderr" && ! grep -q "docs/README.md" "$tmp/stderr"; then
  ok "guard reports only the prompt path"
else
  ko "guard reports only the prompt path" "$(cat "$tmp/stderr")"
fi
git -C "$repo" rm -q --cached docs/plans/demo.prompt-1.md

for wsfile in docs/WORKFLOW.md docs/PARKED.md docs/scope/BASELINE_2026-01-01.md; do
  echo "x" >"$repo/$wsfile"
  git -C "$repo" add "$wsfile"
  eq "guard refuses $wsfile" 2 "$(hook "$repo" "git commit -m test")"
  git -C "$repo" rm -q --cached "$wsfile"
done
eq "guard allows docs/README.md alone again" 0 "$(hook "$repo" "git commit -m test")"
git -C "$repo" rm -q --cached docs/README.md

plain=$tmp/plain
git init -q -b main "$plain"
mkdir -p "$plain/docs"
echo "x" >"$plain/docs/guide.md"
git -C "$plain" add docs/guide.md
eq "guard allows docs/ outside a workspace" 0 "$(hook "$plain" "git commit -m test")"
echo "x" >"$plain/docs/x.prompt-2.md"
git -C "$plain" add docs/x.prompt-2.md
eq "guard refuses prompt files outside a workspace too" 2 "$(hook "$plain" "git commit -m test")"
git -C "$plain" rm -q --cached docs/x.prompt-2.md

echo "x" >"$plain/notes.local.md"
git -C "$plain" add -f notes.local.md
eq "guard refuses *.local.md anywhere" 2 "$(hook "$plain" "git commit -m test")"

# A workspace repo (top level has docs/WORKFLOW.md) may commit its own docs.
wsrepo=$tmp/wsrepo
git init -q -b main "$wsrepo"
mkdir -p "$wsrepo/docs/plans"
echo "x" >"$wsrepo/docs/WORKFLOW.md"
echo "x" >"$wsrepo/docs/plans/x.prompt-1.md"
echo "x" >"$wsrepo/docs/PARKED.md"
git -C "$wsrepo" add docs
git -C "$wsrepo" -c user.name=t -c user.email=t@t commit -q -m init
echo "y" >>"$wsrepo/docs/WORKFLOW.md"
echo "y" >"$wsrepo/docs/plans/x.prompt-2.md"
git -C "$wsrepo" add docs
eq "guard lets a workspace repo commit docs/ planning files" 0 "$(hook "$wsrepo" "git commit -m test")"
mkdir -p "$wsrepo/.claude"
echo "{}" >"$wsrepo/.claude/settings.local.json"
echo "x" >"$wsrepo/.DS_Store"
git -C "$wsrepo" add -f .claude/settings.local.json .DS_Store
eq "guard still refuses .claude and .DS_Store in a workspace repo" 2 "$(hook "$wsrepo" "git commit -m test")"
if grep -q "settings.local.json" "$tmp/stderr" && grep -q ".DS_Store" "$tmp/stderr" && ! grep -q "docs/" "$tmp/stderr"; then
  ok "guard reports only the non-docs paths in a workspace repo"
else
  ko "guard reports only the non-docs paths in a workspace repo" "$(cat "$tmp/stderr")"
fi

# --- summary -------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
