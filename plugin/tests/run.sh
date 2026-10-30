#!/usr/bin/env bash
# Tests for bin/chirat-prompt and hooks/guard-commit.sh in a throwaway workspace.
# Usage: plugin/tests/run.sh

set -uo pipefail
unset CDPATH

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(dirname "$here")
rp=$plugin/bin/chirat-prompt
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

# --- chirat-prompt get ----------------------------------------------------

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

# --- chirat-prompt next ---------------------------------------------------

eq "next: lowest number, then oldest mtime" \
  "$ws/docs/plans/other.prompt-2.md" "$("$rp" next "$ws")"

# --- chirat-prompt set ----------------------------------------------------

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

# --- chirat-prompt set keeps the file mode (GNU/BSD stat) ---------------------

mf=$ws/docs/plans/mode.prompt-1.md
prompt mode.prompt-1.md pending 202601070000
chmod 0640 "$mf"
"$rp" set "$mf" status running
mode=$(stat -c %a "$mf" 2>/dev/null || stat -f %Lp "$mf")
eq "set keeps file mode 0640" 640 "$mode"
eq "set leaves a single front matter" 2 "$(grep -c '^---$' "$mf")"
eq "set writes no stat output" 0 "$(grep -c -i -e 'File:' -e 'Device' "$mf")"
eq "set status after mode test" running "$("$rp" get "$mf" status)"

# --- chirat-prompt next --as-pending --------------------------------------
# The named files count as pending for one call, nothing is written, and the
# usual ordering decides between them and the really pending ones.

nws=$tmp/np
mkdir -p "$nws/docs/plans" "$nws/repos"
nprompt() { # nprompt <name> <status> <mtime YYYYMMDDhhmm>
  printf -- '---\nstatus: %s\nrepo: demo\nbranch: feat/x\n---\n# %s\n' "$2" "$1" >"$nws/docs/plans/$1"
  touch -t "$3" "$nws/docs/plans/$1"
}
nprompt a.prompt-1.md running 202601010000
nprompt a.prompt-2.md pending 202601010000
nprompt a.prompt-3.md running 202601010000
nprompt b.prompt-2.md running 202601010000
nprompt notes.md running 202601010000
nsnap() { # names, mtimes and contents of the plans dir
  local f
  for f in "$nws"/docs/plans/*; do printf '%s %s %s\n' "$f" "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")" "$(cksum <"$f")"; done
}
nbefore=$(nsnap)
eq "as-pending: without it, the pending one" "$nws/docs/plans/a.prompt-2.md" "$("$rp" next "$nws")"
eq "as-pending: a relative path counts as pending" "$nws/docs/plans/a.prompt-1.md" "$("$rp" next "$nws" --as-pending docs/plans/a.prompt-1.md)"
eq "as-pending: an absolute path too" "$nws/docs/plans/a.prompt-1.md" "$("$rp" next "$nws" --as-pending "$nws/docs/plans/a.prompt-1.md")"
eq "as-pending: ./ is dropped" "$nws/docs/plans/a.prompt-1.md" "$("$rp" next "$nws" --as-pending ./docs/plans/a.prompt-1.md)"
eq "as-pending: a really pending lower number wins" "$nws/docs/plans/a.prompt-2.md" "$("$rp" next "$nws" --as-pending docs/plans/a.prompt-3.md)"
eq "as-pending: several files, the lowest wins" "$nws/docs/plans/a.prompt-1.md" "$("$rp" next "$nws" --as-pending docs/plans/a.prompt-3.md docs/plans/a.prompt-1.md)"
eq "as-pending: same number — counts as rewritten now, the older pending one wins" "$nws/docs/plans/a.prompt-2.md" "$("$rp" next "$nws" --as-pending docs/plans/b.prompt-2.md)"
eq "as-pending: a file outside the name pattern is ignored" "$nws/docs/plans/a.prompt-2.md" "$("$rp" next "$nws" --as-pending docs/plans/notes.md)"
eq "as-pending: status on disk untouched" running "$("$rp" get "$nws/docs/plans/a.prompt-1.md" status)"
eq "as-pending: nothing written (names, mtimes, contents)" "$nbefore" "$(nsnap)"
"$rp" set "$nws/docs/plans/a.prompt-1.md" after dep
eq "as-pending: an unmet after: still holds it back" "$nws/docs/plans/a.prompt-2.md" "$("$rp" next "$nws" --as-pending docs/plans/a.prompt-1.md 2>/dev/null)"
"$rp" set "$nws/docs/plans/a.prompt-2.md" status "done"
if out=$("$rp" next "$nws" --as-pending docs/plans/a.prompt-1.md 2>/dev/null); then ko "as-pending: only held-back candidates → exit 1" "picked $out"; else ok "as-pending: only held-back candidates → exit 1"; fi
"$rp" next "$nws" --bogus >/dev/null 2>&1
eq "as-pending: an unknown flag is a usage error" 64 $?

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
init_sha=$(git -C "$ar" rev-parse main)
open_sha=$(git -C "$ar" rev-parse open-b)
bp=$aws/docs/plans/b.prompt-0.md
no_commit_reason="branch merged-b is gone and no result commit is recorded; merge it or set \`after_mode: done\`"
check_reason() { "$rp" check "$aws" "$ap" 2>/dev/null; }
printf -- '---\nmodel: sonnet\nstatus: done\nrepo: demo\nbranch: merged-b\n---\n' >"$bp"
if out=$("$rp" next "$aws" 2>/dev/null); then ko "after: deleted branch without a recorded commit is unmet" "picked $out"; else ok "after: deleted branch without a recorded commit is unmet"; fi
eq "after: waiting gives the reason" "$ap	after=merged-b	$no_commit_reason" "$("$rp" waiting "$aws" 2>/dev/null)"
"$rp" set "$bp" commit "$init_sha"
eq "after: deleted branch whose recorded commit is in main is met" "$ap" "$("$rp" next "$aws")"
eq "check exits 0 on a recorded, merged commit" 0 "$("$rp" check "$aws" "$ap" >/dev/null; echo $?)"
"$rp" set "$bp" commit "$open_sha"
eq "after: recorded commit not in main is unmet" "branch merged-b is gone and its result commit ${open_sha:0:7} is not merged into main" "$(check_reason)"
"$rp" set "$bp" commit 0123456789abcdef0123456789abcdef01234567
eq "after: recorded commit unknown to the repo is unmet" "branch merged-b is gone and its result commit 0123456789abcdef0123456789abcdef01234567 is not in repos/demo" "$(check_reason)"
"$rp" unset "$bp" commit
eq "unset removes the key" 1 "$("$rp" get "$bp" commit >/dev/null 2>&1; echo $?)"
eq "unset keeps the front matter intact" "---
model: sonnet
status: done
repo: demo
branch: merged-b
---" "$(cat "$bp")"
eq "after: after unset the reason is back" "$no_commit_reason" "$(check_reason)"
# A done prompt of another repository is never the result, even with the same branch name.
git init -q -b main "$aws/repos/other"
git -C "$aws/repos/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf -- '---\nmodel: sonnet\nstatus: done\nrepo: other\nbranch: merged-b\ncommit: %s\n---\n' "$(git -C "$aws/repos/other" rev-parse main)" >"$aws/docs/plans/o.prompt-0.md"
eq "after: a done prompt of another repo is not the result" "$no_commit_reason" "$(check_reason)"
rm -f "$aws/docs/plans/o.prompt-0.md"
# Several results on one branch: the last in queue order decides.
"$rp" set "$bp" commit "$init_sha"
printf -- '---\nmodel: sonnet\nstatus: done\nrepo: demo\nbranch: merged-b\ncommit: %s\n---\n' "$open_sha" >"$aws/docs/plans/b.prompt-7.md"
eq "after: with several results the last in queue order decides" "branch merged-b is gone and its result commit ${open_sha:0:7} is not merged into main" "$(check_reason)"
rm -f "$aws/docs/plans/b.prompt-7.md"
# after_mode: done — satisfied by a done prompt, with a warning; never silent.
amprompt() { # amprompt <after> <after_mode>
  printf -- '---\nmodel: sonnet\nstatus: pending\nrepo: demo\nbranch: feat/y\nafter: %s\nafter_mode: %s\n---\n' "$1" "$2" >"$ap"
}
"$rp" unset "$bp" commit
amprompt merged-b "done"
eq "after_mode: done — deleted branch with a done prompt is met" "$ap" "$("$rp" next "$aws" 2>"$tmp/stderr")"
if grep -q "after_mode: done — merged-b counts as satisfied because docs/plans/b.prompt-0.md is done; this does not prove a merge into main" "$tmp/stderr"; then ok "after_mode: done — next warns"; else ko "after_mode: done — next warns" "$(cat "$tmp/stderr")"; fi
eq "after_mode: done — check exits 0" 0 "$("$rp" check "$aws" "$ap" 2>"$tmp/stderr" >/dev/null; echo $?)"
if grep -q "does not prove a merge" "$tmp/stderr"; then ok "after_mode: done — check warns"; else ko "after_mode: done — check warns" "$(cat "$tmp/stderr")"; fi
eq "after_mode: done — waiting lists nothing" "" "$("$rp" waiting "$aws" 2>"$tmp/stderr")"
if grep -q "does not prove a merge" "$tmp/stderr"; then ok "after_mode: done — waiting warns"; else ko "after_mode: done — waiting warns" "$(cat "$tmp/stderr")"; fi
printf -- '---\nmodel: sonnet\nstatus: done\nrepo: demo\nbranch: open-b\n---\n' >"$aws/docs/plans/d.prompt-0.md"
amprompt open-b "done"
eq "after_mode: done — an existing, unmerged branch (squash merge) is met" "$ap" "$("$rp" next "$aws" 2>/dev/null)"
amprompt open-b merged
eq "after_mode: merged — the same branch stays unmet" "branch open-b is not merged into main" "$(check_reason)"
"$rp" set "$aws/docs/plans/d.prompt-0.md" status failed
amprompt open-b "done"
eq "after_mode: done — a failed prompt does not satisfy it" "branch open-b: no done prompt with repo: demo and branch: open-b (after_mode: done)" "$(check_reason)"
rm -f "$aws/docs/plans/d.prompt-0.md"
amprompt merged-b squashed
eq "after_mode: unknown value is unmet" "after_mode: unknown value 'squashed' (merged | done)" "$(check_reason)"
if out=$("$rp" next "$aws" 2>/dev/null); then ko "after_mode: unknown value is never picked" "picked $out"; else ok "after_mode: unknown value is never picked"; fi
aprompt a.prompt-1.md never-b
if out=$("$rp" next "$aws" 2>"$tmp/stderr"); then ko "after: never-existing branch is skipped" "picked $out"; else ok "after: never-existing branch is skipped"; fi
if grep -q "never-b does not exist" "$tmp/stderr"; then ok "after: never-existing branch warns"; else ko "after: never-existing branch warns" "$(cat "$tmp/stderr")"; fi
eq "after: never-existing branch gives the result-commit reason" "branch never-b is gone and no result commit is recorded; merge it or set \`after_mode: done\`" "$(check_reason)"
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

# --- chirat-prompt set: status.log ---------------------------------------

slog=$ws/.chirat/status.log
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
# The parent's name comes from `ps -o comm= -p <ppid>`; a sandbox that denies
# looking at other processes leaves it empty — skipped there, not failed.
if ps -o comm= -p "$$" >/dev/null 2>&1; then
  case $l_parent in '' | -) ko "status.log: parent command named" "$l_parent" ;; *) ok "status.log: parent command named" ;; esac
else
  echo "skip status.log: parent command named (ps -o comm= -p is denied in this sandbox)"
fi
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

# --- .chirat/config in chirat-prompt; guard and .chirat/ -----------------------

cws=$tmp/cws
mkdir -p "$cws"/work/queue "$cws"/.chirat "$cws"/repos
printf '%s\n' 'plans_dir=work/queue' 'default_branch=trunk' >"$cws/.chirat/config"
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
eq "status.log lands in .chirat/" "work/queue/c.prompt-1.md	pending	running" "$(cut -f2-4 "$cws/.chirat/status.log")"
absent_log=$cws/work/queue/status.log
if [ -e "$absent_log" ] || [ -e "$cws/docs" ]; then ko "status.log: nothing under docs/ or the plans dir"; else ok "status.log: nothing under docs/ or the plans dir"; fi

# .chirat/ in a code repo is refused; in a workspace repo only the lock is.
mkdir -p "$repo/.chirat/runs"
echo "{}" >"$repo/.chirat/runs/x.json"
git -C "$repo" add -f .chirat/runs/x.json
eq "guard refuses .chirat/runs/x.json in a code repo" 2 "$(hook "$repo" "git commit -m test")"
git -C "$repo" rm -q --cached .chirat/runs/x.json
mkdir -p "$wsrepo/.chirat/lock"
echo 1 >"$wsrepo/.chirat/lock/pid"
git -C "$wsrepo" reset -q
git -C "$wsrepo" add -f .chirat/lock/pid
eq "guard refuses .chirat/lock/pid in a workspace repo" 2 "$(hook "$wsrepo" "git commit -m test")"
git -C "$wsrepo" reset -q
echo "t" >"$wsrepo/.chirat/LATEST"
git -C "$wsrepo" add .chirat/LATEST
eq "guard allows .chirat/LATEST in a workspace repo" 0 "$(hook "$wsrepo" "git commit -m test")"

# --- guard: push, publish, every commit in the chain -------------------------

jhook() { # jhook <cwd> <command>; like hook, but JSON-escapes the command
  local c=$2 json
  c=${c//\\/\\\\}
  c=${c//\"/\\\"}
  c=${c//$'\n'/\\n}
  json=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$c")
  "${guard_shell[@]}" "$guard" <<<"$json" 2>"$tmp/stderr" >/dev/null
  echo $?
}
guard_shell=(bash)

gp="git push"
blocked=(
  "$gp" "$gp origin main" "$gp --help" "git -C repos/x push" "git -C a -C b push"
  "cd repos/x && $gp" "git status; $gp" "true || $gp" "echo \$($gp)" "echo \`$gp\`"
  "FOO=1 $gp" "env A=1 $gp" "command $gp" "/usr/bin/$gp" "git -c http.x=y push --force"
  "git --no-pager push" "(cd x; $gp)" "bash -c '$gp'" "sudo -u me $gp" "nice -n 5 $gp"
  "timeout 5 $gp" "git status
$gp"
  "npm publish" "pnpm publish" "yarn publish" "yarn npm publish" "npm --tag next publish"
)
allowed=(
  "git stash push" "git log --grep push" "echo $gp" "grep -r \"$gp\" docs/"
  "git remote -v" "git -C repos/x status" "npm run publish-docs" "npx publish"
  "git status 2>&1 | head" "bash repos/x/tests/run.sh"
)
for c in "${blocked[@]}"; do eq "guard blocks: $c" 2 "$(jhook "$ws" "$c")"; done
eq "guard push message" "chirat: git push is the human's step — commit on the branch and stop; the human reviews, merges and pushes." \
  "$(jhook "$ws" "git -C repos/x push" >/dev/null; cat "$tmp/stderr")"
if jhook "$ws" "npm publish" >/dev/null && grep -q "publish" "$tmp/stderr"; then
  ok "guard publish message names publishing"
else
  ko "guard publish message names publishing" "$(cat "$tmp/stderr")"
fi
for c in "${allowed[@]}"; do eq "guard allows: $c" 0 "$(jhook "$ws" "$c")"; done

# Commits seen through -C, a cd anywhere in the chain, and later in a chain.
git -C "$repo" reset -q
echo "code" >"$repo/ok.sh"
git -C "$repo" add ok.sh
eq "guard allows: git commit -m \"push later\"" 0 "$(jhook "$repo" "git commit -m \"push later\"")"
eq "guard allows: git -C <repo> commit, clean" 0 "$(jhook "$ws" "git -C repos/demo commit -m x")"
mkdir -p "$repo/.claude"
echo "{}" >"$repo/.claude/settings.local.json"
git -C "$repo" add -f .claude/settings.local.json
eq "guard checks git -C <repo> commit" 2 "$(jhook "$ws" "git -C repos/demo commit -m x")"
eq "guard checks git -C <abs repo> commit" 2 "$(jhook "$tmp" "git -C $repo commit -m x")"
eq "guard checks a commit second in a chain" 2 "$(jhook "$ws" "git status && git -C repos/demo commit -m x")"
eq "guard checks cd later in the chain" 2 "$(jhook "$ws" "git status; cd repos && git -C demo commit -m x")"
eq "guard checks a commit after cd ... ; " 2 "$(jhook "$ws" "cd repos/demo; git add -A; git commit -m x")"
eq "guard checks every commit, not just the first" 2 "$(jhook "$ws" "git -C $plain commit -m a; git -C repos/demo commit -m b")"
if grep -q "settings.local.json" "$tmp/stderr"; then
  ok "guard names the path from the second commit"
else
  ko "guard names the path from the second commit" "$(cat "$tmp/stderr")"
fi
eq "guard ignores a commit in another, clean repo" 0 "$(jhook "$ws" "git -C $tmp/aws/repos/demo commit -m x")"
git -C "$repo" rm -q --cached .claude/settings.local.json

# Without jq and python3: push/publish fail closed, the commit check fails open.
nobin=$tmp/nobin
mkdir -p "$nobin"
for t in bash cat git grep; do ln -s "$(command -v "$t")" "$nobin/$t"; done
guard_shell=(env PATH="$nobin" "$(command -v bash)")
eq "no parser: git -C x push is blocked" 2 "$(jhook "$ws" "git -C x push")"
if grep -q "false positive" "$tmp/stderr"; then ok "no parser: message admits false positives"; else ko "no parser: message admits false positives" "$(cat "$tmp/stderr")"; fi
eq "no parser: npm publish is blocked" 2 "$(jhook "$ws" "npm publish")"
eq "no parser: git commit is allowed" 0 "$(jhook "$repo" "git commit -m x")"
eq "no parser: npm run publish-docs is allowed" 0 "$(jhook "$ws" "npm run publish-docs")"
guard_shell=(bash)

# --- guard: shell words, quoted paths, fail closed ---------------------------

reason() { # reason <name> <fixed string>: the last refusal's stderr holds it
  if grep -qF -- "$2" "$tmp/stderr"; then ok "$1"; else ko "$1" "$(cat "$tmp/stderr")"; fi
}
unres_msg="chirat: cannot tell which repository this commits to; run git from the repository directory"

sp="$tmp/code with spaces"
git init -q -b main "$sp"
echo "code" >"$sp/main.sh"
git -C "$sp" add main.sh
git -C "$sp" -c user.name=t -c user.email=t@t commit -q -m init
echo "more" >>"$sp/main.sh"
git -C "$sp" add main.sh
eq "spaces: clean repo, double-quoted -C is allowed" 0 "$(jhook "$tmp" "git -C \"$sp\" commit -m x")"
eq "spaces: clean repo, cd \"dir with spaces\" is allowed" 0 "$(jhook "$tmp" "cd \"code with spaces\" && git commit -m x")"
mkdir -p "$sp/.claude"
echo "{}" >"$sp/.claude/settings.local.json"
git -C "$sp" add -f .claude/settings.local.json
eq "spaces: from inside the dir" 2 "$(jhook "$sp" "git commit -m x")"
eq "spaces: double-quoted -C is checked" 2 "$(jhook "$tmp" "git -C \"$sp\" commit -m x")"
reason "spaces: the refusal names the leaked file" "settings.local.json"
eq "spaces: single-quoted -C is checked" 2 "$(jhook "$tmp" "git -C '$sp' commit -m x")"
eq "spaces: backslash-escaped -C is checked" 2 "$(jhook "$tmp" "git -C ${sp// /\\ } commit -m x")"
eq "spaces: -C attached to its value is checked" 2 "$(jhook "$tmp" "git -C\"$sp\" commit -m x")"
eq "spaces: -C relative, quoted" 2 "$(jhook "$tmp" "git -C 'code with spaces' commit -m x")"
eq "spaces: cd \"dir with spaces\" && git commit is checked" 2 "$(jhook "$tmp" "cd \"code with spaces\" && git commit -m x")"
eq "spaces: cd dir\\ with\\ spaces; git commit is checked" 2 "$(jhook "$tmp" "cd code\\ with\\ spaces; git commit -m x")"
eq "spaces: -C with spaces, second in a chain" 2 "$(jhook "$tmp" "git status && git -C \"$sp\" commit -m x")"
eq "spaces: partly quoted word" 2 "$(jhook "$tmp" "git -C \"$tmp\"/code\\ with\\ spaces commit -m x")"
eq "spaces: \$'…' quoting" 2 "$(jhook "$tmp" "git -C \$'$sp' commit -m x")"
eq "spaces: bash -c with a quoted -C inside" 2 "$(jhook "$tmp" "bash -c 'git -C \"$sp\" commit -m x'")"
eq "spaces: eval with a quoted -C inside" 2 "$(jhook "$tmp" "eval \"git -C '$sp' commit -m x\"")"
eq "spaces: env -C <dir> git commit" 2 "$(jhook "$tmp" "env -C \"$sp\" git commit -m x")"
eq "spaces: pushd then commit" 2 "$(jhook "$tmp" "pushd 'code with spaces' && git commit -m x")"

# Quotes are parsed: a separator inside a string is text.
eq "quotes: git commit -m \"a; $gp\" is a commit, not a push" 2 "$(jhook "$sp" "git commit -m \"a; $gp\"")"
reason "quotes: …and is refused for the leaked file, not as a push" "settings.local.json"
eq "quotes: echo '$gp' is allowed" 0 "$(jhook "$ws" "echo '$gp; cd x && git -C y push'")"
eq "quotes: push inside \$(…) in a string is still seen" 2 "$(jhook "$ws" "echo \"today: \$($gp)\"")"
eq "quotes: push inside backticks in a string is still seen" 2 "$(jhook "$ws" "echo \"today: \`$gp\`\"")"
eq "quotes: push inside \${x:-\$(…)} is still seen" 2 "$(jhook "$ws" "echo \${x:-\$($gp)}")"
eq "quotes: commit message from a quoted heredoc" 2 "$(jhook "$sp" "git commit -m \"\$(cat <<'EOF'
Subject line

Body with 'quotes' and \"double quotes\" and a ) paren.
EOF
)\"")"
reason "quotes: heredoc commit is checked for the leaked file" "settings.local.json"
eq "quotes: heredoc body with an unquoted delimiter is scanned" 2 "$(jhook "$ws" "cat <<EOF
line \$($gp)
EOF")"
eq "quotes: heredoc body with a quoted delimiter is text" 0 "$(jhook "$ws" "cat <<'EOF'
it's \$($gp) and \"unbalanced
EOF
echo done")"
eq "quotes: heredoc with <<- and tabs" 0 "$(jhook "$ws" "cat <<-EOF
	don't
	EOF
echo ok")"
eq "quotes: here-string is not a heredoc" 0 "$(jhook "$ws" "grep x <<<\"it's\"")"
eq "quotes: comment with an apostrophe" 0 "$(jhook "$ws" "ls # don't")"

# Fail closed: when the repository cannot be told, refuse with the reason.
eq "unresolved: git -C \"\$X\" commit is refused" 2 "$(jhook "$tmp" "git -C \"\$X\" commit -m x")"
reason "unresolved: the reason is given" "$unres_msg"
eq "unresolved: git -C \$X commit is refused" 2 "$(jhook "$tmp" "git -C \$X commit -m x")"
eq "unresolved: git -C \$(pwd) commit is refused" 2 "$(jhook "$tmp" "git -C \$(pwd) commit -m x")"
eq "unresolved: git -C ~user commit is refused" 2 "$(jhook "$tmp" "git -C ~nobody/x commit -m x")"
eq "unresolved: a glob in -C is refused" 2 "$(jhook "$tmp" "git -C $tmp/code* commit -m x")"
eq "unresolved: cd \"\$D\" && git commit is refused" 2 "$(jhook "$tmp" "cd \"\$D\" && git commit -m x")"
reason "unresolved: cd reason" "$unres_msg"
eq "unresolved: cd - && git commit is refused" 2 "$(jhook "$tmp" "cd - && git commit -m x")"
eq "unresolved: \$'…' with a variable is literal (no expansion in \$'…')" 2 "$(jhook "$tmp" "git -C \$'$tmp/\$X' commit -m x")"
reason "unresolved: literal \$X dir does not exist" "$unres_msg"
eq "unresolved: cd \"\$D\" && ls is allowed (no commit)" 0 "$(jhook "$tmp" "cd \"\$D\" && ls")"
eq "unresolved: git \$SUB is refused" 2 "$(jhook "$tmp" "git \$SUB")"
eq "unresolved: git log \$REF is allowed" 0 "$(jhook "$tmp" "git log \$REF")"
eq "unresolved: bash -c \"\$CMD\" is allowed (nothing visible)" 0 "$(jhook "$tmp" "bash -c \"\$CMD\"")"
eq "unresolved: bash -c 'git -C \"\$X\" commit' is refused" 2 "$(jhook "$tmp" "bash -c 'git -C \"\$X\" commit -m x'")"
eq "literal nonexistent repo path is refused" 2 "$(jhook "$tmp" "git -C /nonexistent/repo commit -m x")"
reason "literal nonexistent repo path: reason" "$unres_msg"
eq "literal non-repo dir is refused" 2 "$(jhook "$tmp" "cd $tmp/nobin && git commit -m x")"
eq "malformed: unbalanced double quote is refused" 2 "$(jhook "$tmp" "git commit -m \"unterminated")"
reason "malformed: says what is wrong" "unbalanced double quote"
eq "malformed: unbalanced single quote is refused" 2 "$(jhook "$tmp" "echo 'oops")"
eq "malformed: unterminated \$( is refused" 2 "$(jhook "$tmp" "echo \$(git status")"
eq "malformed: unbalanced backquote is refused" 2 "$(jhook "$tmp" "echo \`git status")"
eq "malformed: unbalanced \${ is refused" 2 "$(jhook "$tmp" "echo \${x")"

# Quoted metacharacters are text, not separators.
mc="$tmp/a&b;c|d"
git init -q -b main "$mc"
mkdir -p "$mc/.claude"
echo "{}" >"$mc/.claude/settings.local.json"
git -C "$mc" add -f .claude/settings.local.json
eq "metachar: double-quoted path with & ; | is checked" 2 "$(jhook "$tmp" "git -C \"$mc\" commit -m x")"
reason "metachar: names the leaked file" "settings.local.json"
eq "metachar: single-quoted path is checked" 2 "$(jhook "$tmp" "git -C '$mc' commit -m x")"
eq "metachar: cd 'a&b;c|d' && git commit is checked" 2 "$(jhook "$tmp" "cd 'a&b;c|d' && git commit -m x")"
eq "metachar: escaped path is checked" 2 "$(jhook "$tmp" "git -C $tmp/a\\&b\\;c\\|d commit -m x")"
git -C "$mc" rm -q --cached .claude/settings.local.json
echo "x" >"$mc/f"
git -C "$mc" add f
eq "metachar: clean repo with such a path is allowed" 0 "$(jhook "$tmp" "git -C \"$mc\" commit -m x")"
eq "metachar: push inside a quoted path is not a push" 0 "$(jhook "$tmp" "ls \"$tmp/$gp\"")"

# --git-dir / --work-tree, also as GIT_DIR / GIT_WORK_TREE.
eq "git-dir: --git-dir=… --work-tree=… commit is checked" 2 "$(jhook "$tmp" "git --git-dir=\"$sp/.git\" --work-tree=\"$sp\" commit -m x")"
eq "git-dir: --git-dir … (separate) commit is checked" 2 "$(jhook "$tmp" "git --git-dir \"$sp/.git\" commit -m x")"
eq "git-dir: --work-tree=… alone commit is checked" 2 "$(jhook "$tmp" "git --work-tree=\"$sp\" commit -m x")"
eq "git-dir: GIT_DIR=… git commit is checked" 2 "$(jhook "$tmp" "GIT_DIR=\"$sp/.git\" git commit -m x")"
eq "git-dir: env GIT_WORK_TREE=… git commit is checked" 2 "$(jhook "$tmp" "env GIT_WORK_TREE=\"$sp\" git commit -m x")"
eq "git-dir: relative to a preceding -C" 2 "$(jhook "$ws" "git -C $tmp --git-dir='code with spaces/.git' commit -m x")"
eq "git-dir: --git-dir=\$G commit is refused" 2 "$(jhook "$tmp" "git --git-dir=\$G commit -m x")"
reason "git-dir: unresolved reason" "$unres_msg"
eq "git-dir: --work-tree \"\$W\" commit is refused" 2 "$(jhook "$tmp" "git --work-tree \"\$W\" commit -m x")"
eq "git-dir: nonexistent --git-dir is refused" 2 "$(jhook "$tmp" "git --git-dir=/nonexistent/.git commit -m x")"
eq "git-dir: clean repo through --git-dir is allowed" 0 "$(jhook "$tmp" "git --git-dir=\"$mc/.git\" --work-tree=\"$mc\" commit -m x")"
git -C "$sp" rm -q --cached .claude/settings.local.json
eq "spaces: clean again → allowed" 0 "$(jhook "$tmp" "git -C \"$sp\" commit -m x")"

# --- guard: substitutions in quotes, -c bodies, cd under control flow ---------

# Two plain-path repos: `cl` is clean, `dr` has a workspace file staged.
cl=$tmp/clean
dr=$tmp/dirty
for d in "$cl" "$dr"; do
  git init -q -b main "$d"
  echo "code" >"$d/main.sh"
  git -C "$d" add main.sh
  git -C "$d" -c user.name=t -c user.email=t@t commit -q -m init
  echo "more" >>"$d/main.sh"
  git -C "$d" add main.sh
done
mkdir -p "$dr/.claude"
echo "{}" >"$dr/.claude/settings.local.json"
git -C "$dr" add -f .claude/settings.local.json
gc="git commit -m t"
push_msg="chirat: git push is the human's step — commit on the branch and stop; the human reviews, merges and pushes."

# 1. A double-quoted region inside ${…} is scanned like any other.
eq "quotes in \${…}: \"\${x:-\"\$(git push)\"}\" is a push" 2 "$(jhook "$cl" "echo \"\${x:-\"\$($gp)\"}\"")"
reason "quotes in \${…}: refused as a push" "$push_msg"
eq "quotes in \${…}: \"\${x:-\"\$(git commit)\"}\" is a commit" 2 "$(jhook "$dr" "echo \"\${x:-\"\$($gc)\"}\"")"
reason "quotes in \${…}: the commit is checked for the leaked file" "settings.local.json"
eq "quotes in \${…}: the single-quoted twin is text" 0 "$(jhook "$cl" "echo '\${x:-\"\$($gp)\"}'")"
eq "quotes in \${…}: two levels of \"\$(…)\"" 2 "$(jhook "$cl" "echo \"\${x:-\$(echo \"\$($gp)\")}\"")"
eq "quotes in \${…}: \"\${x:-\"literal; git push\"}\" is text" 0 "$(jhook "$cl" "echo \"\${x:-\"literal; $gp\"}\"")"
eq "quotes in \${…}: inside an unquoted heredoc body" 2 "$(jhook "$cl" "cat <<EOF
\${x:-\"\$($gp)\"}
EOF")"
eq "quotes in \${…}: inside a bash -c body" 2 "$(jhook "$cl" "bash -c 'echo \"\${x:-\"\$($gp)\"}\"'")"
eq "quotes in \${…}: \${x:+\"\`git push\`\"} backticks" 2 "$(jhook "$cl" "echo \"\${x:+\"\`$gp\`\"}\"")"
eq "quotes in \${…}: nested \${y:-\"\$(git push)\"} inside \${x:-…}" 2 "$(jhook "$cl" "echo \"\${x:-\${y:-\"\$($gp)\"}}\"")"
eq "quotes in \${…}: an unbalanced quote inside is a parse error" 2 "$(jhook "$cl" "echo \"\${x:-\"abc}\"")"
reason "quotes in \${…}: parse error reason" "cannot parse this command"

# 2. A -c body / eval inherits the caller's repository context.
eq "context: GIT_DIR=dirty bash -c 'git commit' from clean" 2 "$(jhook "$cl" "GIT_DIR=\"$dr/.git\" bash -c '$gc'")"
reason "context: the dirty repo is the one checked" "settings.local.json"
eq "context: env -C dirty bash -c 'git commit' from clean" 2 "$(jhook "$cl" "env -C $dr bash -c '$gc'")"
eq "context: cd dirty && bash -c 'git commit' from clean" 2 "$(jhook "$cl" "cd $dr && bash -c '$gc'")"
eq "context: env GIT_WORK_TREE=dirty sh -c 'git commit' from clean" 2 "$(jhook "$cl" "env GIT_WORK_TREE=$dr GIT_DIR=$dr/.git sh -c '$gc'")"
eq "context: GIT_DIR=dirty eval 'git commit' from clean" 2 "$(jhook "$cl" "GIT_DIR=$dr/.git eval '$gc'")"
eq "context: GIT_DIR=clean bash -c 'git commit' from dirty is allowed" 0 "$(jhook "$dr" "GIT_DIR=$cl/.git bash -c '$gc'")"
eq "context: env -C clean bash -c 'git commit' from dirty is allowed" 0 "$(jhook "$dr" "env -C $cl bash -c '$gc'")"
eq "context: bash -c 'cd dirty && git commit' from clean" 2 "$(jhook "$cl" "bash -c 'cd $dr && $gc'")"
eq "context: bash -c 'cd dirty'; git commit from clean is allowed" 0 "$(jhook "$cl" "bash -c 'cd $dr' ; $gc")"
eq "context: GIT_DIR=\$X bash -c 'git commit' is refused" 2 "$(jhook "$cl" "GIT_DIR=\$X bash -c '$gc'")"
reason "context: unresolved GIT_DIR reason" "$unres_msg"
eq "context: cd \$D && bash -c 'git commit' is refused" 2 "$(jhook "$cl" "cd \$D && bash -c '$gc'")"
eq "context: GIT_DIR=dirty bash -c 'ls' is allowed" 0 "$(jhook "$cl" "GIT_DIR=$dr/.git bash -c 'ls'")"
eq "context: GIT_DIR=dirty bash -c 'git commit'; git commit from clean" 2 "$(jhook "$cl" "GIT_DIR=$dr/.git bash -c '$gc'; $gc")"
eq "context: GIT_DIR=dirty true; git commit from clean is allowed" 0 "$(jhook "$cl" "GIT_DIR=$dr/.git true; $gc")"
eq "context: sudo bash -c 'git push' is a push" 2 "$(jhook "$cl" "sudo bash -c '$gp'")"
eq "context: env -C dirty sh -lc 'git commit' from clean" 2 "$(jhook "$cl" "env -C $dr sh -lc '$gc'")"

# 3. The directory is a set of candidates: a commit is checked against every one.
eq "flow: cd clean | cat; git commit from dirty" 2 "$(jhook "$dr" "cd \"$cl\" | cat; $gc")"
reason "flow: the pipeline cd changed nothing" "settings.local.json"
eq "flow: if false; then cd clean; fi; git commit from dirty" 2 "$(jhook "$dr" "if false; then cd $cl; fi; $gc")"
eq "flow: cd clean && git commit from dirty is allowed" 0 "$(jhook "$dr" "cd $cl && $gc")"
eq "flow: cd clean && true; git commit from dirty (after the chain: {dirty, clean})" 2 "$(jhook "$dr" "cd $cl && true; $gc")"
eq "flow: cd clean && git add .; git commit from dirty" 2 "$(jhook "$dr" "cd $cl && git add .; $gc")"
eq "flow: cd clean; git add . && git commit from dirty is allowed" 0 "$(jhook "$dr" "cd $cl; git add . && $gc")"
eq "flow: false && cd clean; git commit from dirty" 2 "$(jhook "$dr" "false && cd $cl; $gc")"
eq "flow: (cd dirty); git commit from clean is allowed" 0 "$(jhook "$cl" "(cd $dr); $gc")"
eq "flow: cd dirty || true; git commit from clean" 2 "$(jhook "$cl" "cd $dr || true; $gc")"
eq "flow: while false; do cd clean; done; git commit from dirty" 2 "$(jhook "$dr" "while false; do cd $cl; done; $gc")"
eq "flow: until true; do cd clean; done; git commit from dirty" 2 "$(jhook "$dr" "until true; do cd $cl; done; $gc")"
eq "flow: for d in x; do cd dirty; done; git commit from clean" 2 "$(jhook "$cl" "for d in x; do cd $dr; done; $gc")"
eq "flow: case … esac with a cd inside; git commit from clean" 2 "$(jhook "$cl" "case x in y) cd $dr;; *) true;; esac; $gc")"
eq "flow: if cd clean; then git commit; fi from dirty is allowed" 0 "$(jhook "$dr" "if cd $cl; then $gc; fi")"
eq "flow: if cd clean; then :; fi; git commit from dirty" 2 "$(jhook "$dr" "if cd $cl; then :; fi; $gc")"
eq "flow: cd dirty; cd clean; git commit from dirty is allowed" 0 "$(jhook "$dr" "cd $dr; cd $cl; $gc")"
eq "flow: cd clean && cd dirty && git commit from clean" 2 "$(jhook "$cl" "cd $cl && cd $dr && $gc")"
eq "flow: cd clean || cd dirty; git commit from dirty" 2 "$(jhook "$dr" "cd $cl || cd $dr; $gc")"
eq "flow: cd clean && git commit | cat from dirty is allowed" 0 "$(jhook "$dr" "cd $cl && $gc | cat")"
eq "flow: { cd clean; }; git commit from dirty is allowed" 0 "$(jhook "$dr" "{ cd $cl; }; $gc")"
eq "flow: cd clean &&<newline>git commit from dirty is allowed" 0 "$(jhook "$dr" "cd $cl &&
$gc")"
eq "flow: cd clean; git commit; cd dirty from dirty is allowed" 0 "$(jhook "$dr" "cd $cl; $gc; cd $dr")"
eq "flow: git -C relative after a conditional cd" 2 "$(jhook "$tmp" "false && cd $tmp; git -C dirty commit -m t")"
eq "flow: for x in \$(git push); do :; done is a push" 2 "$(jhook "$cl" "for x in \$($gp); do :; done")"
eq "flow: case \$(git push) in … esac is a push" 2 "$(jhook "$cl" "case \$($gp) in x) :;; esac")"
eq "flow: cd - inside if; git commit from clean is refused" 2 "$(jhook "$cl" "if true; then cd -; fi; $gc")"
reason "flow: unknown candidate reason" "$unres_msg"
eq "flow: cd \$D | cat; git commit from clean is allowed" 0 "$(jhook "$cl" "cd \$D | cat; $gc")"

# --- guard: background jobs, loops, functions — the whitelist rule -----------

# Three nested repos: `ne` (outer) is dirty, `nm` and `ni` (inner) are clean.
ne=$tmp/nest/outer nm=$tmp/nest/outer/mid ni=$tmp/nest/outer/mid/inner
for d in "$ne" "$nm" "$ni"; do
  git init -q -b main "$d"
  echo "code" >"$d/main.sh"
  git -C "$d" add main.sh
  git -C "$d" -c user.name=t -c user.email=t@t commit -q -m init
  echo "more" >>"$d/main.sh"
  git -C "$d" add main.sh
done
mkdir -p "$ne/.claude"
echo "{}" >"$ne/.claude/settings.local.json"
git -C "$ne" add -f .claude/settings.local.json

# 1. A background job (`… &`, `coproc`) runs in its own shell.
eq "bg: cd clean & wait; git commit from dirty" 2 "$(jhook "$dr" "cd \"$cl\" & wait; $gc")"
reason "bg: the background cd changed nothing" "settings.local.json"
eq "bg: cd dirty & wait; git commit from clean is allowed" 0 "$(jhook "$cl" "cd $dr & wait; $gc")"
eq "bg: cd clean & git commit from dirty" 2 "$(jhook "$dr" "cd $cl & $gc")"
eq "bg: (cd clean &); git commit from dirty" 2 "$(jhook "$dr" "(cd $cl &); $gc")"
eq "bg: cd clean &<newline>git commit from dirty" 2 "$(jhook "$dr" "cd $cl &
$gc")"
eq "bg: cd clean && git commit & from dirty is allowed (the chain's own set)" 0 "$(jhook "$dr" "cd $cl && $gc &")"
eq "bg: cd dirty && git commit & from clean" 2 "$(jhook "$cl" "cd $dr && $gc &")"
eq "bg: { cd clean; } & git commit from dirty" 2 "$(jhook "$dr" "{ cd $cl; } & $gc")"
eq "bg: coproc cd clean; git commit from dirty" 2 "$(jhook "$dr" "coproc cd $cl; $gc")"
eq "bg: coproc { cd clean; }; git commit from dirty" 2 "$(jhook "$dr" "coproc { cd $cl; }; $gc")"
eq "bg: coproc X { cd clean; }; git commit from dirty" 2 "$(jhook "$dr" "coproc X { cd $cl; }; $gc")"
eq "bg: cd clean 2>&1 && git commit from dirty is allowed (a redirect, not a job)" 0 "$(jhook "$dr" "cd $cl 2>&1 && $gc")"
eq "bg: git push & is a push" 2 "$(jhook "$cl" "$gp &")"

# 2. A loop whose body or condition touches the directory leaves it unknown.
eq "loop: for n in 1 2; do cd ..; done; git commit from inner" 2 "$(jhook "$ni" "for n in 1 2; do cd ..; done; $gc")"
reason "loop: the set after the loop is unknown" "$unres_msg"
eq "loop: for n in 1; do cd clean; done; git commit from dirty" 2 "$(jhook "$dr" "for n in 1; do cd $cl; done; $gc")"
reason "loop: iterations are not counted" "$unres_msg"
eq "loop: while false; do cd clean; done; git commit from dirty" 2 "$(jhook "$dr" "while false; do cd $cl; done; $gc")"
eq "loop: until true; do cd clean; done; git commit from dirty" 2 "$(jhook "$dr" "until true; do cd $cl; done; $gc")"
eq "loop: while cd ..; do :; done; git commit from inner (the condition moves)" 2 "$(jhook "$ni" "while cd ..; do :; done; $gc")"
eq "loop: for n in 1; do cd clean; done && git commit from dirty" 2 "$(jhook "$dr" "for n in 1; do cd $cl; done && $gc")"
eq "loop: for n in 1; do cd clean; git commit; done from dirty (a commit inside is unknown)" 2 "$(jhook "$dr" "for n in 1; do cd $cl; $gc; done")"
reason "loop: the commit inside the moving loop is unknown" "$unres_msg"
eq "loop: for f in a b; do echo \$f; done; git commit from clean is allowed (untouched)" 0 "$(jhook "$cl" "for f in a b; do echo \$f; done; $gc")"
eq "loop: for n in 1; do git commit; done from clean is allowed" 0 "$(jhook "$cl" "for n in 1; do $gc; done")"
eq "loop: for d in a b; do (cd \$d && make); done; git commit from clean is allowed" 0 "$(jhook "$cl" "for d in a b; do (cd \$d && make); done; $gc")"
eq "loop: for x in \$(cd clean); do :; done; git commit from clean is allowed" 0 "$(jhook "$cl" "for x in \$(cd $cl); do :; done; $gc")"
eq "loop: cd clean; for f in a; do echo; done; git commit from dirty is allowed" 0 "$(jhook "$dr" "cd $cl; for f in a; do echo; done; $gc")"
eq "loop: cd dirty; for f in a; do echo; done; git commit from clean" 2 "$(jhook "$cl" "cd $dr; for f in a; do echo; done; $gc")"
reason "loop: the cd before the loop still counts" "settings.local.json"
eq "loop: while read -r d; do cd \"\$d\"; done; git commit from clean" 2 "$(jhook "$cl" "while read -r d; do cd \"\$d\"; done; $gc")"

# 3. Functions: the body is walked as an unknown directory; a body that
# touches the directory makes every later call unknown.
eq "fn: f() { cd clean; }; f; git commit from dirty" 2 "$(jhook "$dr" "f() { cd $cl; }; f; $gc")"
reason "fn: the call is unknown" "$unres_msg"
eq "fn: f() { cd clean; }; git commit from dirty (defining moves nothing)" 2 "$(jhook "$dr" "f() { cd $cl; }; $gc")"
reason "fn: still in the dirty repo" "settings.local.json"
eq "fn: f() { cd dirty; }; git commit from clean is allowed" 0 "$(jhook "$cl" "f() { cd $dr; }; $gc")"
eq "fn: function f { cd clean; }; f; git commit from dirty" 2 "$(jhook "$dr" "function f { cd $cl; }; f; $gc")"
eq "fn: function f() { cd clean; }; f; git commit from dirty" 2 "$(jhook "$dr" "function f() { cd $cl; }; f; $gc")"
eq "fn: f()<newline>{<newline>cd clean<newline>}<newline>git commit from dirty" 2 "$(jhook "$dr" "f()
{
  cd $cl
}
$gc")"
reason "fn: the newline-form body is the function's, not the caller's" "settings.local.json"
eq "fn: f() { echo hi; }; f; git commit from clean is allowed" 0 "$(jhook "$cl" "f() { echo hi; }; f; $gc")"
eq "fn: f() { git commit; }; f from clean (a commit in a body is unknown)" 2 "$(jhook "$cl" "f() { $gc; }; f")"
reason "fn: the body's commit is unknown" "$unres_msg"
eq "fn: f() { git -C <abs clean> commit; }; f from dirty is allowed" 0 "$(jhook "$dr" "f() { git -C $cl commit -m t; }; f")"
eq "fn: f() { git -C <abs dirty> commit; }; f from clean" 2 "$(jhook "$cl" "f() { git -C $dr commit -m t; }; f")"
eq "fn: f() { git push; } is a push" 2 "$(jhook "$cl" "f() { $gp; }")"
eq "fn: cd() { :; }; cd clean; git commit from dirty" 2 "$(jhook "$dr" "cd() { :; }; cd $cl; $gc")"
reason "fn: a shadowed cd is unknown" "$unres_msg"
eq "fn: git() { command git \"\$@\"; }; git push is refused" 2 "$(jhook "$cl" "git() { command git \"\$@\"; }; $gp")"
eq "fn: f() { cd clean; }; for n in 1; do f; done; git commit from dirty" 2 "$(jhook "$dr" "f() { cd $cl; }; for n in 1; do f; done; $gc")"
eq "fn: for n in 1; do f; f() { cd clean; }; done; git commit from dirty" 2 "$(jhook "$dr" "for n in 1; do f; f() { cd $cl; }; done; $gc")"
eq "fn: f() ( cd clean ); f; git commit from dirty" 2 "$(jhook "$dr" "f() ( cd $cl ); f; $gc")"
eq "fn: a=(); cd clean; git commit from dirty is allowed (an array, not a function)" 0 "$(jhook "$dr" "a=(); cd $cl; $gc")"

# 4. source, eval, trap, builtin, pushd, cd operands, shopt.
eq "src: source x.sh; git commit from clean" 2 "$(jhook "$cl" "source x.sh; $gc")"
reason "src: a sourced file may do anything" "after source the shell is unknown"
eq "src: . ./env.sh && git commit from clean" 2 "$(jhook "$cl" ". ./env.sh && $gc")"
eq "src: source x.sh alone is allowed" 0 "$(jhook "$cl" "source x.sh")"
eq "eval: eval \"\$CMD\"; git commit from clean" 2 "$(jhook "$cl" "eval \"\$CMD\"; $gc")"
reason "eval: an unresolved string is unknown" "after eval of a string that is not literal the shell is unknown"
eq "eval: eval 'cd clean'; git commit from dirty is allowed" 0 "$(jhook "$dr" "eval 'cd $cl'; $gc")"
eq "eval: eval \"\$CMD\" alone is allowed" 0 "$(jhook "$cl" "eval \"\$CMD\"")"
eq "trap: trap 'cd clean' EXIT; git commit from dirty" 2 "$(jhook "$dr" "trap 'cd $cl' EXIT; $gc")"
reason "trap: a trap body that moves is unknown" "$unres_msg"
eq "trap: trap 'echo bye' EXIT; git commit from clean is allowed" 0 "$(jhook "$cl" "trap 'echo bye' EXIT; $gc")"
eq "trap: trap 'git push' EXIT is a push" 2 "$(jhook "$cl" "trap '$gp' EXIT")"
eq "trap: trap \"\$T\" EXIT; git commit from clean" 2 "$(jhook "$cl" "trap \"\$T\" EXIT; $gc")"
eq "trap: trap - EXIT; git commit from clean is allowed" 0 "$(jhook "$cl" "trap - EXIT; $gc")"
eq "builtin: builtin cd clean; git commit from dirty is allowed" 0 "$(jhook "$dr" "builtin cd $cl; $gc")"
eq "builtin: builtin cd dirty; git commit from clean" 2 "$(jhook "$cl" "builtin cd $dr; $gc")"
eq "pushd: pushd -n clean; git commit from dirty" 2 "$(jhook "$dr" "pushd -n $cl; $gc")"
reason "pushd: an option is unknown" "$unres_msg"
eq "pushd: pushd; git commit from clean" 2 "$(jhook "$cl" "pushd; $gc")"
eq "pushd: pushd +1; git commit from clean" 2 "$(jhook "$cl" "pushd +1; $gc")"
eq "pushd: pushd clean && git commit from dirty is allowed" 0 "$(jhook "$dr" "pushd $cl && $gc")"
eq "cd: cd clean dirty; git commit from dirty" 2 "$(jhook "$dr" "cd $cl $dr; $gc")"
reason "cd: two operands are unknown" "$unres_msg"
eq "cd: cd -P clean && git commit from dirty is allowed" 0 "$(jhook "$dr" "cd -P $cl && $gc")"
eq "cd: cd -x clean; git commit from dirty" 2 "$(jhook "$dr" "cd -x $cl; $gc")"
eq "cd: cd -- clean && git commit from dirty is allowed" 0 "$(jhook "$dr" "cd -- $cl && $gc")"
eq "shopt: shopt -s expand_aliases; alias cd=true; cd clean; git commit from dirty" 2 "$(jhook "$dr" "shopt -s expand_aliases; alias cd=true; cd $cl; $gc")"
reason "shopt: alias expansion is unknown" "after shopt the shell is unknown"
eq "shopt: shopt -s nullglob; cd clean; git commit from dirty is allowed" 0 "$(jhook "$dr" "shopt -s nullglob; cd $cl; $gc")"
guard_shell=(env CDPATH=/x bash)
eq "cd: with CDPATH a relative cd is unknown" 2 "$(jhook "$tmp" "cd clean; $gc")"
reason "cd: CDPATH reason" "$unres_msg"
eq "cd: with CDPATH ./clean is still followed" 0 "$(jhook "$tmp" "cd ./clean; $gc")"
guard_shell=(bash)

# --- guard: shell state apart from the directory --------------------------------
# Two dimensions (hook header): `-C` cures an unknown directory, never an
# unknown shell; an exported GIT_DIR / GIT_WORK_TREE is carried like a prefix.

shell_unknown="the shell is unknown"
opaque_msg="chirat: a shell fed from a pipe, heredoc or stdin runs code the hook cannot see; put it in a script file"
eq "env: export GIT_DIR=clean; git commit from dirty is allowed" 0 "$(jhook "$dr" "export GIT_DIR=$cl/.git; $gc")"
eq "env: export GIT_DIR=clean GIT_WORK_TREE=clean; git commit from dirty is allowed" 0 "$(jhook "$dr" "export GIT_DIR=$cl/.git GIT_WORK_TREE=$cl; $gc")"
eq "env: declare -x GIT_DIR=clean; git commit from dirty is allowed" 0 "$(jhook "$dr" "declare -x GIT_DIR=$cl/.git; $gc")"
eq "env: export GIT_DIR=dirty GIT_WORK_TREE=dirty; git -C clean commit (the reviewer's line)" 2 "$(jhook "$cl" "export GIT_DIR=\"$dr/.git\" GIT_WORK_TREE=\"$dr\"; git -C \"$cl\" commit -m t")"
reason "env: the exported repo is the one checked" "settings.local.json"
eq "env: export GIT_DIR=\"\$X\"; git commit is refused" 2 "$(jhook "$cl" "export GIT_DIR=\"\$X\"; $gc")"
reason "env: an unresolved export leaves the shell unknown" "after export GIT_DIR $shell_unknown"
eq "env: export GIT_INDEX_FILE=/tmp/i; git -C clean commit is refused" 2 "$(jhook "$cl" "export GIT_INDEX_FILE=/tmp/i; git -C $cl commit -m t")"
reason "env: another GIT_* variable leaves the shell unknown" "after export GIT_INDEX_FILE $shell_unknown"
eq "env: export GIT_DIR=clean; unset GIT_DIR; git commit from dirty is refused" 2 "$(jhook "$dr" "export GIT_DIR=$cl/.git; unset GIT_DIR; $gc")"
reason "env: unset leaves the shell unknown" "after unset GIT_DIR $shell_unknown"
eq "env: export -n GIT_DIR; git commit from clean is refused" 2 "$(jhook "$cl" "export -n GIT_DIR; $gc")"
eq "env: export GIT_DIR (no value); git commit from clean is refused" 2 "$(jhook "$cl" "export GIT_DIR; $gc")"
eq "env: GIT_DIR=clean; git commit from dirty (a standalone assignment) is refused" 2 "$(jhook "$dr" "GIT_DIR=$cl/.git; $gc")"
reason "env: a standalone GIT_* assignment leaves the shell unknown" "after a standalone GIT_* assignment $shell_unknown"
eq "env: (export GIT_DIR=dirty); git -C clean commit is allowed (scoped)" 0 "$(jhook "$cl" "(export GIT_DIR=$dr/.git); git -C $cl commit -m t")"
eq "env: export GIT_DIR=dirty | cat; git commit from clean is allowed" 0 "$(jhook "$cl" "export GIT_DIR=$dr/.git | cat; $gc")"
eq "env: export GIT_DIR=dirty & wait; git commit from clean is allowed" 0 "$(jhook "$cl" "export GIT_DIR=$dr/.git & wait; $gc")"
eq "env: bash -c 'export GIT_DIR=dirty'; git commit from clean is allowed" 0 "$(jhook "$cl" "bash -c 'export GIT_DIR=$dr/.git'; $gc")"
eq "env: export GIT_DIR=dirty; git -C clean status is allowed (carried, no commit)" 0 "$(jhook "$cl" "export GIT_DIR=$dr/.git; git -C $cl status")"
eq "env: export GIT_DIR=\"\$X\"; git -C clean status is refused (unknown shell, every git)" 2 "$(jhook "$cl" "export GIT_DIR=\"\$X\"; git -C $cl status")"
eq "env: export GIT_DIR=clean && git commit from dirty is allowed (the chain sees it)" 0 "$(jhook "$dr" "export GIT_DIR=$cl/.git && $gc")"
eq "env: export GIT_DIR=clean && true; git commit from dirty is refused (after the chain)" 2 "$(jhook "$dr" "export GIT_DIR=$cl/.git && true; $gc")"
eq "env: if true; then export GIT_DIR=clean; fi; git commit from dirty is refused" 2 "$(jhook "$dr" "if true; then export GIT_DIR=$cl/.git; fi; $gc")"
eq "env: for n in 1; do export GIT_DIR=clean; done; git commit from dirty is refused" 2 "$(jhook "$dr" "for n in 1; do export GIT_DIR=$cl/.git; done; $gc")"
eq "env: { export GIT_DIR=clean; }; git commit from dirty is allowed" 0 "$(jhook "$dr" "{ export GIT_DIR=$cl/.git; }; $gc")"
eq "env: eval 'export GIT_DIR=dirty'; git -C clean commit is refused" 2 "$(jhook "$cl" "eval 'export GIT_DIR=$dr/.git'; git -C $cl commit -m t")"
eq "env: trap 'export GIT_DIR=dirty' DEBUG; git -C clean commit is refused" 2 "$(jhook "$cl" "trap 'export GIT_DIR=$dr/.git' DEBUG; git -C $cl commit -m t")"
eq "env: f() { git -C clean commit; }; export GIT_DIR=dirty; f is refused" 2 "$(jhook "$cl" "f() { git -C $cl commit -m t; }; export GIT_DIR=$dr/.git; f")"
reason "env: the function's commit was read without the export" "f commits and is called with an exported git environment"
eq "env: f() { echo hi; }; export GIT_DIR=clean; f; git commit from dirty is allowed" 0 "$(jhook "$dr" "f() { echo hi; }; export GIT_DIR=$cl/.git; f; $gc")"
eq "env: f() { export GIT_DIR=dirty; }; f; git -C clean commit is refused" 2 "$(jhook "$cl" "f() { export GIT_DIR=$dr/.git; }; f; git -C $cl commit -m t")"
eq "env: export FOO=\"\$BAR\"; git commit from clean is allowed (not GIT_*)" 0 "$(jhook "$cl" "export FOO=\"\$BAR\" PATH=\"\$HOME/bin:\$PATH\"; $gc")"
eq "env: GIT_INDEX_FILE=/tmp/i git commit from clean is refused" 2 "$(jhook "$cl" "GIT_INDEX_FILE=/tmp/i $gc")"
reason "env: the prefix variable is named" "GIT_INDEX_FILE in the environment changes where this commit goes"
eq "env: env GIT_OBJECT_DIRECTORY=/tmp/o git commit from clean is refused" 2 "$(jhook "$cl" "env GIT_OBJECT_DIRECTORY=/tmp/o $gc")"
eq "env: GIT_PAGER=cat git log is allowed (not a commit)" 0 "$(jhook "$cl" "GIT_PAGER=cat git log")"
eq "env: GIT_INDEX_FILE=/tmp/i bash -c 'git commit' from clean is refused" 2 "$(jhook "$cl" "GIT_INDEX_FILE=/tmp/i bash -c '$gc'")"
eq "shell: source x; git -C clean commit is refused (-C does not cure the shell)" 2 "$(jhook "$dr" "source x; git -C $cl commit -m t")"
reason "shell: the reason names the shell, not the directory" "after source $shell_unknown"
eq "shell: bash -c 'source x'; git -C clean commit is allowed (scoped)" 0 "$(jhook "$dr" "bash -c 'source x'; git -C $cl commit -m t")"
eq "shell: source x; git status is refused (every git)" 2 "$(jhook "$cl" "source x; git status")"
eq "shell: source x; npm test is refused" 2 "$(jhook "$cl" "source x; npm test")"
reason "shell: the npm reason names the shell" "this npm command cannot be checked"
eq "shell: source x | cat; git commit from clean is allowed" 0 "$(jhook "$cl" "source x | cat; $gc")"
eq "shell: source x & git commit from clean is allowed" 0 "$(jhook "$cl" "source x & $gc")"
eq "shell: (source x); git commit from clean is allowed" 0 "$(jhook "$cl" "(source x); $gc")"
eq "shell: f() { source x; }; f; git -C clean commit is refused" 2 "$(jhook "$dr" "f() { source x; }; f; git -C $cl commit -m t")"
reason "shell: the call is named" "after a call of f, whose body changes the shell"
eq "shell: f() { source x; }; git -C clean commit is allowed (defining runs nothing)" 0 "$(jhook "$dr" "f() { source x; }; git -C $cl commit -m t")"
eq "shell: eval \"\$CMD\"; git -C clean commit is refused" 2 "$(jhook "$dr" "eval \"\$CMD\"; git -C $cl commit -m t")"
eq "shell: trap \"\$T\" EXIT; git -C clean commit is refused" 2 "$(jhook "$dr" "trap \"\$T\" EXIT; git -C $cl commit -m t")"
eq "shell: shopt -s lastpipe; cd clean | cat; git commit from dirty is refused" 2 "$(jhook "$dr" "shopt -s lastpipe; cd $cl | cat; $gc")"
eq "shell: shopt -s expand_aliases; alias git=…; git -C clean commit is refused" 2 "$(jhook "$dr" "shopt -s expand_aliases; alias git='git -C $dr'; git -C $cl commit -m t")"
eq "shell: source x; cd clean; git commit is refused" 2 "$(jhook "$dr" "source x; cd $cl; $gc")"
eq "shell: source x alone is still allowed" 0 "$(jhook "$cl" "source x; ls")"

# --- guard: redirections are lexer tokens ----------------------------------------
# A quoted `>` is text; an unquoted one, with its target, is never an operand.

rx="$tmp/>x"
git init -q -b main "$rx"
echo "code" >"$rx/main.sh"
git -C "$rx" add main.sh
git -C "$rx" -c user.name=t -c user.email=t@t commit -q -m init
echo "more" >>"$rx/main.sh"
git -C "$rx" add main.sh
eq "redir: git -C '>x' commit, clean, is a commit in >x" 0 "$(jhook "$tmp" "git -C '>x' commit -m t")"
eq "redir: git -C \">x\" commit, clean, is a commit in >x" 0 "$(jhook "$tmp" "git -C \">x\" commit -m t")"
mkdir -p "$rx/.claude"
echo "{}" >"$rx/.claude/settings.local.json"
git -C "$rx" add -f .claude/settings.local.json
eq "redir: git -C '>x' commit, dirty, is checked" 2 "$(jhook "$tmp" "git -C '>x' commit -m t")"
reason "redir: the quoted path was not taken for a redirection" "settings.local.json"
eq "redir: git -C \">x\" commit, dirty, is checked" 2 "$(jhook "$tmp" "git -C \">x\" commit -m t")"
eq "redir: git -C \\>x commit, dirty, is checked" 2 "$(jhook "$tmp" "git -C \\>x commit -m t")"
eq "redir: cd '>x' && git commit, dirty, is checked" 2 "$(jhook "$tmp" "cd '>x' && $gc")"
eq "redir: git -C '>missing' commit is refused (no such repo)" 2 "$(jhook "$tmp" "git -C '>missing' commit -m t")"
reason "redir: …with the unresolved reason" "$unres_msg"
eq "redir: git commit -m '>not a redirect' from dirty is a commit" 2 "$(jhook "$dr" "git commit -m '>not a redirect'")"
reason "redir: …checked for the leaked file" "settings.local.json"
eq "redir: cd clean >/dev/null && git commit from dirty is allowed" 0 "$(jhook "$dr" "cd $cl >/dev/null && $gc")"
eq "redir: cd clean > /dev/null 2>&1 && git commit from dirty is allowed" 0 "$(jhook "$dr" "cd $cl > /dev/null 2>&1 && $gc")"
eq "redir: git commit 2>&1 | tee log from dirty is checked" 2 "$(jhook "$dr" "$gc 2>&1 | tee log")"
eq "redir: git commit >out 2>err from dirty is checked" 2 "$(jhook "$dr" "$gc >out 2>err")"
eq "redir: 2>&1 git commit from dirty is checked" 2 "$(jhook "$dr" "2>&1 $gc")"
eq "redir: echo '>' > file; git commit from dirty is checked" 2 "$(jhook "$dr" "echo '>' > file; $gc")"
eq "redir: echo '>' > file; git commit from clean is allowed" 0 "$(jhook "$cl" "echo '>' > file; $gc")"
eq "redir: echo foo>bar; git commit from clean is allowed" 0 "$(jhook "$cl" "echo foo>bar; $gc")"
eq "redir: exec 3>&1; git commit from clean is allowed" 0 "$(jhook "$cl" "exec 3>&1; $gc")"
eq "redir: exec {fd}>out; git commit from clean is allowed" 0 "$(jhook "$cl" "exec {fd}>out; $gc")"
eq "redir: git commit <<<msg from dirty is checked" 2 "$(jhook "$dr" "$gc <<<msg")"
eq "redir: cat <(git push) is a push" 2 "$(jhook "$cl" "cat <(git push)")"
eq "redir: a push in a redirection target is seen" 2 "$(jhook "$cl" "echo x >\$(git push)")"

# --- guard: shells fed from a pipe, heredoc or stdin -----------------------------

o="echo 'git push'"
for c in "$o | bash" "$o | sh" "$o | bash -" "$o | zsh" "$o | /bin/bash" "bash -s <<<'git push'" "sh -s" \
  "bash <<EOF
git push
EOF" "sh <<'EOF'
git push
EOF" "bash <<<\"\$X\"" "bash < script.sh" "bash 0<script.sh" "$o | sudo bash" "$o | env bash" "$o | nice bash" \
  "$o | timeout 5 bash" "$o | exec bash" "$o | { bash; }" "$o | (bash)" "{ bash; } <<<'git push'" "(bash) <script.sh" \
  "if true; then bash; fi <script.sh" "f() { bash; }; f <<<'git push'" "f() { bash; }; $o | f" "$o | bash -c 'bash'" \
  "exec <<<'git push'; bash" "exec <script.sh; bash" "echo -c 'git push' | xargs bash" "echo x | xargs sh -c" "bash -\$X"; do
  eq "opaque: $c" 2 "$(jhook "$cl" "$c")"
done
reason "opaque: the reason" "$opaque_msg"
for c in "bash tests/run.sh" "bash repos/x/tests/run.sh --fast" "bash -c 'echo hi'" "sh -ec 'ls'" "cat x | grep y" \
  "python3 - <<EOF
print(1)
EOF" "bash --version" "sh --help" "bash \"\$f\"" "bash -x \"\$f\"" "bash script.sh <input" "echo x | bash script.sh" \
  "$o | bash -c 'cat'" "bash -c 'echo hi' <<<'git push'" "bash" "sudo bash -c 'ls'" "{ bash; } >out" "(bash) 2>&1"; do
  eq "opaque: allowed: $c" 0 "$(jhook "$cl" "$c")"
done
eq "opaque: a -c body is still walked" 2 "$(jhook "$cl" "$o | bash -c 'git push'")"
reason "opaque: …as a push" "$push_msg"

# --- guard: differential corpus (guard vs. a real shell) ---------------------

if "$BASH" "$here/guard-corpus.sh"; then
  ok "guard corpus: nothing dirty passes"
else
  ko "guard corpus: see the lines above"
fi

# --- summary -------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
