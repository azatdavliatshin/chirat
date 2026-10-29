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

# --- after: ----------------------------------------------------------------

aws=$tmp/aws
mkdir -p "$aws"/docs/plans "$aws"/repos
ar=$aws/repos/demo
git init -q -b main "$ar"
git -C "$ar" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$ar" branch merged-b
git -C "$ar" checkout -q -b open-b
git -C "$ar" -c user.name=t -c user.email=t@t commit -q --allow-empty -m open
git -C "$ar" checkout -q main
aprompt() { # aprompt <name> <after>
  printf -- '---\nmodel: sonnet\nstatus: pending\nrepo: demo\nbranch: feat/y\nafter: %s\n---\n# %s\n' "$2" "$1" >"$aws/docs/plans/$1"
}
ap=$aws/docs/plans/a.prompt-1.md
aprompt a.prompt-1.md open-b
if out=$("$rp" next "$aws" 2>/dev/null); then ko "after: unmerged branch is skipped" "picked $out"; else ok "after: unmerged branch is skipped"; fi
eq "waiting lists the unmerged branch" "$ap	after=open-b	branch open-b is not merged into main" "$("$rp" waiting "$aws")"
eq "check exits 1 on an unmerged branch" 1 "$("$rp" check "$aws" "$ap" >/dev/null; echo $?)"
aprompt a.prompt-1.md merged-b
eq "after: merged branch is picked" "$ap" "$("$rp" next "$aws")"
eq "waiting is empty when satisfied" "" "$("$rp" waiting "$aws")"
eq "check exits 0 when merged" 0 "$("$rp" check "$aws" "$ap" >/dev/null; echo $?)"
git -C "$ar" branch -q -D merged-b
printf -- '---\nmodel: sonnet\nstatus: done\nrepo: demo\nbranch: merged-b\n---\n' >"$aws/docs/plans/b.prompt-0.md"
eq "after: deleted branch is picked" "$ap" "$("$rp" next "$aws")"
aprompt a.prompt-1.md never-b
if out=$("$rp" next "$aws" 2>"$tmp/stderr"); then ko "after: never-existing branch is skipped" "picked $out"; else ok "after: never-existing branch is skipped"; fi
if grep -q "never-b does not exist" "$tmp/stderr"; then ok "after: never-existing branch warns"; else ko "after: never-existing branch warns" "$(cat "$tmp/stderr")"; fi
printf -- '---\nmodel: sonnet\nstatus: pending\nrepo: demo\nbranch: feat/z\n---\n' >"$aws/docs/plans/c.prompt-2.md"
eq "next skips a waiting prompt for a later free one" "$aws/docs/plans/c.prompt-2.md" "$("$rp" next "$aws" 2>/dev/null)"

# --- suffixed prompt numbers, lint -----------------------------------------

sws=$tmp/sws
mkdir -p "$sws/docs/plans"
sprompt() { # sprompt <name> <status>
  printf -- '---\nmodel: sonnet\nstatus: %s\nrepo: demo\nbranch: feat/x\n---\n' "$2" >"$sws/docs/plans/$1"
}
eq "lint exits 0 on a clean workspace" 0 "$("$rp" lint "$sws" >/dev/null; echo $?)"
sprompt s.prompt-6.md pending
sprompt s.prompt-5b.md pending
sprompt s.prompt-5-fix.md pending
sprompt s.prompt-5.md pending
echo "just notes" >"$sws/docs/plans/s.md"
order=""
for _ in 1 2 3 4; do
  f=$("$rp" next "$sws") || break
  order="$order ${f##*.prompt-}"
  "$rp" set "$f" status "done"
done
eq "next order: N, plain N, suffixes in byte order" " 5.md 5-fix.md 5b.md 6.md" "$order"
eq "lint ignores files without front matter and valid names" 0 "$("$rp" lint "$sws" >/dev/null; echo $?)"
sprompt s.prompt-x.md pending
sprompt "s.prompt-5 draft.md" pending
sprompt s.prompt-7.md "done"
eq "next never returns misnamed files" 1 "$("$rp" next "$sws" >/dev/null; echo $?)"
lint_out=$("$rp" lint "$sws"); lint_rc=$?
eq "lint exits 1 when files are misnamed" 1 "$lint_rc"
eq "lint lists exactly the misnamed pending files" \
  "$(printf '%s\n' "$sws/docs/plans/s.prompt-5 draft.md" "$sws/docs/plans/s.prompt-x.md")" \
  "$(printf '%s\n' "$lint_out" | cut -f1)"
eq "lint line carries the reason" "name does not match <topic>.prompt-<N><suffix>.md" "$(printf '%s\n' "$lint_out" | head -n 1 | cut -f2)"
sprompt s.prompt-05b.md pending
eq "leading zero with suffix is valid" "$sws/docs/plans/s.prompt-05b.md" "$("$rp" next "$sws")"

# --- relay-prompt set: status.log ---------------------------------------

slog=$ws/.relay/status.log
rm -f "$slog"
prompt log.prompt-1.md pending 202601010000
lf=$ws/docs/plans/log.prompt-1.md
"$rp" set "$lf" status running
eq "status.log: one line after a status change" 1 "$(wc -l <"$slog" | tr -d ' ')"
IFS=$'\t' read -r l_ts l_file l_old l_new l_pid l_ppid l_parent <"$slog"
case $l_ts in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ok "status.log: iso time" ;; *) ko "status.log: iso time" "$l_ts" ;; esac
eq "status.log: file relative to the workspace" docs/plans/log.prompt-1.md "$l_file"
eq "status.log: old and new" "pending running" "$l_old $l_new"
case $l_pid$l_ppid in *[!0-9]* | '') ko "status.log: pid and ppid are numbers" "$l_pid $l_ppid" ;; *) ok "status.log: pid and ppid are numbers" ;; esac
case $l_parent in '' | -) ko "status.log: parent command named" "$l_parent" ;; *) ok "status.log: parent command named" ;; esac
"$rp" set "$lf" status running
eq "status.log: same value twice adds nothing" 1 "$(wc -l <"$slog" | tr -d ' ')"
"$rp" set "$lf" worktree plugin
eq "status.log: other keys add nothing" 1 "$(wc -l <"$slog" | tr -d ' ')"
mkdir -p "$tmp/loose"
cp "$lf" "$tmp/loose/p.md"
"$rp" set "$tmp/loose/p.md" status "done" 2>"$tmp/err"
eq "set outside docs/plans succeeds" "done" "$("$rp" get "$tmp/loose/p.md" status)"
if grep -q "not logged" "$tmp/err"; then ok "set outside docs/plans warns"; else ko "set outside docs/plans warns" "$(cat "$tmp/err")"; fi
eq "status.log: untouched by the loose file" 1 "$(wc -l <"$slog" | tr -d ' ')"

# --- .relay/config in relay-prompt; guard and .relay/ -----------------------

cws=$tmp/cws
mkdir -p "$cws"/work/queue "$cws"/.relay "$cws"/repos
printf '%s\n' 'plans_dir=work/queue' 'default_branch=trunk' >"$cws/.relay/config"
cr=$cws/repos/demo
git init -q -b trunk "$cr"
git -C "$cr" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$cr" checkout -q -b open-t
git -C "$cr" -c user.name=t -c user.email=t@t commit -q --allow-empty -m open
git -C "$cr" checkout -q trunk
cprompt() { # cprompt <name> <status> [after]
  {
    printf '%s\n' '---' 'model: sonnet' "status: $2" 'repo: demo' 'branch: feat/z'
    [ -z "${3:-}" ] || printf 'after: %s\n' "$3"
    printf '%s\n' '---' "# $1"
  } >"$cws/work/queue/$1"
}
cprompt c.prompt-1.md pending
eq "plans_dir: next reads the configured directory" "$cws/work/queue/c.prompt-1.md" "$("$rp" next "$cws")"
cprompt c.prompt-1.md pending open-t
if "$rp" next "$cws" >/dev/null 2>&1; then ko "default_branch: unmerged branch is skipped" "picked one"; else ok "default_branch: unmerged branch is skipped"; fi
eq "default_branch: waiting names trunk" "$cws/work/queue/c.prompt-1.md	after=open-t	branch open-t is not merged into trunk" "$("$rp" waiting "$cws")"
git -C "$cr" merge -q --no-edit open-t
eq "default_branch: merged into trunk is picked" "$cws/work/queue/c.prompt-1.md" "$("$rp" next "$cws")"
"$rp" set "$cws/work/queue/c.prompt-1.md" status running
eq "status.log lands in .relay/" "work/queue/c.prompt-1.md	pending	running" "$(cut -f2-4 "$cws/.relay/status.log")"
absent_log=$cws/work/queue/status.log
if [ -e "$absent_log" ] || [ -e "$cws/docs" ]; then ko "status.log: nothing under docs/ or the plans dir"; else ok "status.log: nothing under docs/ or the plans dir"; fi

# .relay/ in a code repo is refused; in a workspace repo only the lock is.
mkdir -p "$repo/.relay/runs"
echo "{}" >"$repo/.relay/runs/x.json"
git -C "$repo" add -f .relay/runs/x.json
eq "guard refuses .relay/runs/x.json in a code repo" 2 "$(hook "$repo" "git commit -m test")"
git -C "$repo" rm -q --cached .relay/runs/x.json
mkdir -p "$wsrepo/.relay/lock"
echo 1 >"$wsrepo/.relay/lock/pid"
git -C "$wsrepo" reset -q
git -C "$wsrepo" add -f .relay/lock/pid
eq "guard refuses .relay/lock/pid in a workspace repo" 2 "$(hook "$wsrepo" "git commit -m test")"
git -C "$wsrepo" reset -q
echo "t" >"$wsrepo/.relay/LATEST"
git -C "$wsrepo" add .relay/LATEST
eq "guard allows .relay/LATEST in a workspace repo" 0 "$(hook "$wsrepo" "git commit -m test")"

# --- summary -------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
