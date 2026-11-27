#!/usr/bin/env bash
# Tests for bin/chirat-watch with a fake `claude` on PATH and a throwaway
# workspace. Usage: tests/chirat-watch.sh

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
watch=$root/bin/chirat-watch
rp=$root/plugin/bin/chirat-prompt

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
ko() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "     $2"; }

eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected [$2], got [$3]"; fi
}

eq_log() { # eq_log <name> <expected> <actual> [log]: eq for what is counted in watch.log; a failure prints that log
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected [$2], got [$3] in ${4:-$log}:"$'\n'"$(cat "${4:-$log}")"; fi
}

has() { # has <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then ok "$1"; else ko "$1" "no [$3] in $2:"$'\n'"$(cat "$2")"; fi
}

exists() { # exists <name> <test flag> <path>
  if test "$2" "$3"; then ok "$1"; else ko "$1" "test $2 $3 is false"; fi
}

absent() { # absent <name> <path>
  if [ -e "$2" ]; then ko "$1" "$2 exists"; else ok "$1"; fi
}

fs_snapshot() { # fs_snapshot <path>…: every path under each (or "absent"), and a checksum per file
  local d
  for d in "$@"; do
    if [ -e "$d" ]; then
      find "$d" -print | sort
      find "$d" -type f -exec cksum {} + | sort
    else
      echo "absent $d"
    fi
  done
}

first() { # first <glob...>: print the first existing match, or nothing
  for f in "$@"; do [ -e "$f" ] && { printf '%s\n' "$f"; return; }; done
  return 1
}

wait_claude() { # wait_claude <prompt file>: until it is running and the lock has claude.pid
  local _
  for _ in $(seq 1 100); do
    [ "$("$rp" get "$1" status)" = running ] && [ -s "$ws/.chirat/lock/claude.pid" ] && return 0
    sleep 0.1
  done
  return 1
}

gone() { # gone <pid>: wait up to 5 s until it no longer exists
  local _
  for _ in $(seq 1 50); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}
until_true() { # until_true <tenths of a second> <command…>: poll until it succeeds
  local n=$1
  shift
  while [ "$n" -gt 0 ]; do
    "$@" && return 0
    n=$((n - 1))
    sleep 0.1
  done
  return 1
}

# --- fake claude -----------------------------------------------------------
# Records argv (one per line) and $PWD, prints a JSON result, and acts on the
# prompt named after `-p "/chirat:next <file>"` like the real /chirat:next:
# claims it (`running`) and marks it `done`. FAKE_MODE=noflip stops after the
# claim; FAKE_MODE=noclaim touches nothing; FAKE_MODE=sleep claims and then
# sleeps 30 seconds; FAKE_MODE=hang claims and sleeps but prints nothing (the
# .json stays empty); FAKE_MODE=stubborn is sleep with TERM ignored;
# FAKE_MODE=orphan is sleep with a child that ignores TERM (its pid goes to
# $FAKE_CHILD). Exits with $FAKE_EXIT (default 0). FAKE_FINAL sets the status it ends with (default
# done); FAKE_SF names a status file it writes before that; FAKE_COMMIT=1 makes
# one commit on the prompt's branch in repos/demo first; FAKE_SET_COMMIT sets
# `commit:` to that value (a wrong one, for the watcher to correct). A line
# `fake-sleep: N` in the prompt body makes it sleep N seconds after the claim
# (the parallel tests give each run its own length that way). FAKE_LOCKS names
# a file that gets `lock` or `nolock` twice per run: whether $PWD/.chirat/lock
# exists when claude starts and when it is about to exit.

mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -u
{ printf '%s\n' "$@"; echo "PWD=$PWD"; } >"$FAKE_ARGV"
lockcheck() {
  [ -n "${FAKE_LOCKS:-}" ] || return 0
  if [ -d "$PWD/.chirat/lock" ]; then echo lock; else echo nolock; fi >>"$FAKE_LOCKS"
}
lockcheck
file=""
while [ $# -gt 0 ]; do
  case $1 in
    -p) file=${2#/chirat:next }; shift 2 ;;
    *) shift ;;
  esac
done
mode=${FAKE_MODE:-done}
if [ "$mode" != hang ]; then
  echo '{"result":"ok"}'
  echo "fake claude stderr" >&2
fi
[ "$mode" = stubborn ] && trap '' TERM
if [ "$mode" = orphan ]; then
  bash -c 'trap "" TERM; sleep 300' &
  echo $! >"$FAKE_CHILD"
fi
if [ -n "$file" ] && [ "$mode" != noclaim ]; then
  "$RP" set "$file" status running
  fs=$(sed -n 's/^fake-sleep: //p' "$file" 2>/dev/null)
  [ -z "$fs" ] || sleep "$fs"
  case $mode in sleep | hang | stubborn | orphan) sleep 30 ;; esac
  [ -z "${FAKE_SF:-}" ] || echo "status" >"$FAKE_SF"
  if [ -n "${FAKE_COMMIT:-}" ]; then
    br=$("$RP" get "$file" branch)
    git -C "$PWD/repos/demo" checkout -q "$br" 2>/dev/null || git -C "$PWD/repos/demo" checkout -q -b "$br"
    git -C "$PWD/repos/demo" commit -q --allow-empty -m "work on $br"
    git -C "$PWD/repos/demo" checkout -q main
  fi
  [ -z "${FAKE_SET_COMMIT:-}" ] || "$RP" set "$file" commit "$FAKE_SET_COMMIT"
  case $mode in noflip | sleep | hang | stubborn) ;; *) "$RP" set "$file" status "${FAKE_FINAL:-done}" ;; esac
fi
lockcheck
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$tmp/bin/claude"

# Fake osascript: records its arguments so the notification can be checked.
cat >"$tmp/bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_OSA"
EOF
chmod +x "$tmp/bin/osascript"
# A real terminal-notifier on this machine must not be picked up by the runs.
clean_path=""
IFS=: read -ra _pd <<<"$PATH"
for _d in "${_pd[@]}"; do
  [ -x "$_d/terminal-notifier" ] || clean_path="${clean_path:+$clean_path:}$_d"
done
export PATH=$tmp/bin:$clean_path RP=$rp FAKE_ARGV=$tmp/argv FAKE_OSA=$tmp/osa

# --- workspace + config ---------------------------------------------------

export HOME=$tmp XDG_CONFIG_HOME=$tmp/config XDG_STATE_HOME=$tmp/state
ws=$tmp/ws
mkdir -p "$ws"/docs/{plans,status} "$ws"/repos "$XDG_CONFIG_HOME/chirat"
prompt() { # prompt <name> <model> <status>
  cat >"$ws/docs/plans/$1" <<EOF
---
model: $2
status: $3
repo: demo
branch: feat/x
---
# $1
EOF
}
prompt demo.prompt-1.md opus pending
prompt demo.prompt-2.md sonnet pending
cat >"$XDG_CONFIG_HOME/chirat/workspaces" <<EOF
# workspaces, one per line; ~ is expanded
~/ws/   # trailing slash and comment on purpose

$tmp/not-a-workspace
EOF
log=$XDG_STATE_HOME/chirat/watch.log

# --- version / config -----------------------------------------------------

eq "--version" "chirat-watch $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$root/plugin/.claude-plugin/plugin.json")" "$("$watch" --version)"
XDG_CONFIG_HOME=$tmp/nowhere "$watch" --once >/dev/null 2>"$tmp/stderr"
eq "missing config exits 1" 1 $?
has "missing config prints usage" "$tmp/stderr" "chirat-watch [--once]"

# --- --dry-run ------------------------------------------------------------

before=$(fs_snapshot "$ws" "$XDG_STATE_HOME")
out=$("$watch" --once --dry-run 2>"$tmp/stderr")
eq "dry-run exits 0" 0 $?
has "dry-run prints the claude command" <(printf '%s\n' "$out") "claude -p /chirat:next\\ docs/plans/demo.prompt-1.md --model opus --permission-mode auto --permission-prompts none --output-format json"
eq "dry-run leaves the prompt pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-1.md" status)"
eq "dry-run runs nothing" "" "$(first "$ws"/.chirat/runs/*)"
absent "dry-run creates no .chirat/" "$ws/.chirat"
has "dry-run warns about a non-workspace path" "$tmp/stderr" "not a workspace (no docs/plans): $tmp/not-a-workspace"
absent "dry-run does not create the state dir" "$XDG_STATE_HOME"
eq "dry-run writes nothing (workspace and state dir unchanged)" "$before" "$(fs_snapshot "$ws" "$XDG_STATE_HOME")"
eq "dry-run prints the log line it would write" 1 "$(printf '%s\n' "$out" | grep -c "	docs/plans/demo.prompt-1.md	opus	dry-run	")"
eq "dry-run: mode column shows auto" auto "$(printf '%s\n' "$out" | grep "	dry-run	" | cut -f7)"

# --- permission mode: default auto, flag > env > default -------------------

mode_of() { # mode_of <env value or -> <flag args...>; prints the mode in the dry-run command
  local env=$1; shift
  if [ "$env" = - ]; then
    "$watch" --once --dry-run "$@" 2>/dev/null | grep -o -e '--permission-mode [^ ]*'
  else
    CHIRAT_PERMISSION_MODE=$env "$watch" --once --dry-run "$@" 2>/dev/null | grep -o -e '--permission-mode [^ ]*'
  fi
}
eq "mode: default is auto" "--permission-mode auto" "$(mode_of -)"
eq "mode: flag overrides default" "--permission-mode acceptEdits" "$(mode_of - --permission-mode acceptEdits)"
eq "mode: env overrides default" "--permission-mode plan" "$(mode_of plan)"
eq "mode: flag beats env" "--permission-mode acceptEdits" "$(mode_of plan --permission-mode acceptEdits)"
"$watch" --once --dry-run --permission-mode >/dev/null 2>&1
eq "mode: flag without value exits 64" 64 $?
absent "mode tests (dry-run) created no state dir" "$XDG_STATE_HOME"

# --- --once: happy path ---------------------------------------------------

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git -C "$ws" init -q
git -C "$ws" add docs/plans
git -C "$ws" commit -q -m "docs: plans"
rm -rf "$ws/.chirat/runs"

out=$("$watch" --once 2>"$tmp/stderr")
eq "once exits 0" 0 $?
json=$(first "$ws"/.chirat/runs/demo.prompt-1.*.json)
err=${json%.json}.err
exists "writes runs/<stem>.<ts>.json" -f "$json"
case ${json##*/} in demo.prompt-1.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].json) ok "timestamp is YYYYMMDD-HHMMSS" ;; *) ko "timestamp is YYYYMMDD-HHMMSS" "$json" ;; esac
eq "json holds claude's stdout" '{"result":"ok"}' "$(cat "$json")"
eq "err holds claude's stderr" "fake claude stderr" "$(cat "$err")"
eq "runs the lower-numbered prompt" "/chirat:next docs/plans/demo.prompt-1.md" "$(sed -n '/^-p$/{n;p;}' "$FAKE_ARGV")"
eq "passes the prompt's model" opus "$(sed -n '/^--model$/{n;p;}' "$FAKE_ARGV")"
eq "passes --permission-mode auto by default" auto "$(sed -n '/^--permission-mode$/{n;p;}' "$FAKE_ARGV")"
has "passes --permission-prompts none" "$FAKE_ARGV" "--permission-prompts"
has "passes --output-format json" "$FAKE_ARGV" "--output-format"
eq "runs from the workspace root" "PWD=$ws" "$(grep '^PWD=' "$FAKE_ARGV")"
eq "prompt-1 is done afterwards" "done" "$("$rp" get "$ws/docs/plans/demo.prompt-1.md" status)"
eq "prompt-2 is still pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-2.md" status)"
absent "lock released" "$ws/.chirat/lock"
eq "run log commit message" "docs: run log demo.prompt-1" "$(git -C "$ws" log -1 --format=%s)"
eq "run log commit holds runs/ files, status.log, LATEST and the prompt, not the lock" ".chirat/LATEST
.chirat/runs/${err##*/}
.chirat/runs/${json##*/}
.chirat/status.log
docs/plans/demo.prompt-1.md" "$(git -C "$ws" show --name-only --format= HEAD | sort)"
eq "LATEST: no pending changes" "" "$(git -C "$ws" status --porcelain -- .chirat/LATEST)"
eq "LATEST: one line after the first run" 1 "$(wc -l <"$ws/.chirat/LATEST" | tr -d ' ')"
IFS=$'\t' read -r a_ts a_stem a_status a_branch a_commit a_exit a_secs <"$ws/.chirat/LATEST"
case $a_ts in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ok "LATEST: iso timestamp" ;; *) ko "LATEST: iso timestamp" "$a_ts" ;; esac
eq "LATEST: stem" demo.prompt-1 "$a_stem"
eq "LATEST: status" "done" "$a_status"
eq "LATEST: branch" feat/x "$a_branch"
eq "LATEST: no repo → commit -" - "$a_commit"
eq "LATEST: exit" 0 "$a_exit"
case $a_secs in '' | *[!0-9]*) ko "LATEST: seconds" "$a_secs" ;; *) ok "LATEST: seconds" ;; esac
eq "run log: no pending runs/ changes" "" "$(git -C "$ws" status --porcelain -- .chirat/runs)"
eq_log "one log line" 1 "$(wc -l <"$log" | tr -d ' ')"
line=$(cat "$log")
eq "log line echoed to stdout" "$line" "$out"
IFS=$'\t' read -r l_ts l_ws l_file l_model l_exit l_secs l_mode <<<"$line"
case $l_ts in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ok "log: iso timestamp" ;; *) ko "log: iso timestamp" "$l_ts" ;; esac
eq "log: workspace" "$ws" "$l_ws"
eq "log: file" "docs/plans/demo.prompt-1.md" "$l_file"
eq "log: model" opus "$l_model"
eq "log: exit" 0 "$l_exit"
eq "log: mode" auto "$l_mode"
case $l_secs in '' | *[!0-9]*) ko "log: seconds" "$l_secs" ;; *) ok "log: seconds" ;; esac
has "notification names the prompt" "$FAKE_OSA" "demo.prompt-1"
has "notification carries the final status" "$FAKE_OSA" 'title "chirat: done"'
rm -f "$FAKE_OSA"

# --- --once: claude exits without flipping the status ---------------------

CHIRAT_NOTIFY=0 FAKE_MODE=noflip FAKE_EXIT=3 "$watch" --once >"$tmp/out" 2>"$tmp/stderr"
eq "once still exits 0 when claude fails" 0 $?
absent "CHIRAT_NOTIFY=0 sends nothing" "$FAKE_OSA"
eq "prompt-2 set to failed" failed "$("$rp" get "$ws/docs/plans/demo.prompt-2.md" status)"
err2=$(first "$ws"/.chirat/runs/demo.prompt-2.*.err)
has "err notes the forced failure" "$err2" "claude exited 3 with the prompt still 'running'; set to failed"
has "err keeps claude's own stderr first" "$err2" "fake claude stderr"
eq "LATEST: second run appends a line" 2 "$(wc -l <"$ws/.chirat/LATEST" | tr -d ' ')"
eq "LATEST: forced failure recorded" "demo.prompt-2	failed	feat/x	-	3" "$(tail -n 1 "$ws/.chirat/LATEST" | cut -f2-6)"
eq "LATEST: first line untouched" demo.prompt-1 "$(head -n 1 "$ws/.chirat/LATEST" | cut -f2)"
eq "log: exit code 3" 3 "$(tail -n 1 "$log" | cut -f5)"
eq "log: model sonnet by default" sonnet "$(tail -n 1 "$log" | cut -f4)"
absent "lock released after failure" "$ws/.chirat/lock"

# --- --once: claude exits before claiming the prompt ----------------------

prompt demo.prompt-3.md sonnet pending
FAKE_MODE=noclaim FAKE_EXIT=1 "$watch" --once >/dev/null 2>&1
eq "unclaimed prompt set to failed (no retry loop)" failed "$("$rp" get "$ws/docs/plans/demo.prompt-3.md" status)"
err3=$(first "$ws"/.chirat/runs/demo.prompt-3.*.err)
has "err notes the prompt was still pending" "$err3" "claude exited 1 with the prompt still 'pending'; set to failed"
rm -f "$ws/docs/plans/demo.prompt-3.md"

# --- --once: nothing pending ----------------------------------------------

out=$("$watch" --once 2>/dev/null)
eq "once with empty queue exits 0" 0 $?
eq "once with empty queue prints nothing" "" "$out"
eq_log "once with empty queue logs nothing" 3 "$(wc -l <"$log" | tr -d ' ')"

# --- lock held → skip -----------------------------------------------------

"$rp" set "$ws/docs/plans/demo.prompt-2.md" status pending
mkdir "$ws/.chirat/lock"
echo $$ >"$ws/.chirat/lock/watcher.pid" # a live owner: this shell
: >"$FAKE_ARGV"
"$watch" --once >/dev/null 2>"$tmp/stderr"
eq "locked workspace: exit 0" 0 $?
has "locked workspace: says so on stderr" "$tmp/stderr" "in progress, lock held by watcher $$"
eq "locked workspace: claude not called" "" "$(cat "$FAKE_ARGV")"
eq "locked workspace: prompt stays pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-2.md" status)"
exists "locked workspace: lock left alone" -d "$ws/.chirat/lock"
rm -f "$ws/.chirat/lock/watcher.pid"
rmdir "$ws/.chirat/lock"

# --- model missing → sonnet; --interval validation -----------------------

prompt demo.prompt-3.md "" pending
sed -i.bak '/^model:/d' "$ws/docs/plans/demo.prompt-3.md" && rm -f "$ws/docs/plans/demo.prompt-3.md.bak"
"$watch" --once >/dev/null 2>&1
eq "runs prompt-2 before prompt-3" "/chirat:next docs/plans/demo.prompt-2.md" "$(sed -n '/^-p$/{n;p;}' "$FAKE_ARGV")"
"$watch" --once >/dev/null 2>&1
eq "no model key → sonnet" sonnet "$(sed -n '/^--model$/{n;p;}' "$FAKE_ARGV")"
"$watch" --once --interval abc >/dev/null 2>&1
eq "--interval rejects non-numbers" 1 $?
"$watch" --bogus >/dev/null 2>&1
eq "unknown flag → usage (64)" 64 $?

# --- SIGTERM during a run → pending, logged, lock released ----------------

prompt demo.prompt-9.md sonnet pending
lines_before=$(wc -l <"$log" | tr -d ' ')
FAKE_MODE="sleep" "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
lock=$ws/.chirat/lock
wait_claude "$ws/docs/plans/demo.prompt-9.md"
eq "sleeping run has claimed the prompt" running "$("$rp" get "$ws/docs/plans/demo.prompt-9.md" status)"
cpid=$(cat "$lock/claude.pid" 2>/dev/null)
for f in watcher.pid prompt run started claude.pid; do exists "lock holds $f" -s "$lock/$f"; done
eq "lock: watcher.pid is the watcher" "$wpid" "$(cat "$lock/watcher.pid")"
eq "lock: prompt" docs/plans/demo.prompt-9.md "$(cat "$lock/prompt")"
case $(cat "$lock/run") in demo.prompt-9.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ok "lock: run is <stem>.<stamp>" ;; *) ko "lock: run is <stem>.<stamp>" "$(cat "$lock/run")" ;; esac
exists "lock: run names the .err of this run" -e "$ws/.chirat/runs/$(cat "$lock/run").err"
case $(cat "$lock/started") in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ok "lock: started is iso" ;; *) ko "lock: started is iso" "$(cat "$lock/started")" ;; esac
has "lock: claude.pid is the fake claude" <(ps -o args= -p "$cpid") "bin/claude -p"
kill -TERM "$wpid"
wait "$wpid"
eq "SIGTERM: watcher exits 130" 130 $?
eq "SIGTERM: prompt back to pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-9.md" status)"
err9=$(first "$ws"/.chirat/runs/demo.prompt-9.*.err)
has "SIGTERM: err notes the interruption" "$err9" "chirat-watch was interrupted with the prompt still 'running'; set to pending (SIGTERM)"
eq_log "SIGTERM: one more log line" $((lines_before + 1)) "$(wc -l <"$log" | tr -d ' ')"
eq "SIGTERM: LATEST records interrupted" "demo.prompt-9	pending	feat/x	-	interrupted" "$(tail -n 1 "$ws/.chirat/LATEST" | cut -f2-6)"
eq "SIGTERM: LATEST committed" "" "$(git -C "$ws" status --porcelain -- .chirat/LATEST)"
eq "SIGTERM: log exit column is interrupted" interrupted "$(tail -n 1 "$log" | cut -f5)"
eq "SIGTERM: log names the prompt" docs/plans/demo.prompt-9.md "$(tail -n 1 "$log" | cut -f3)"
absent "SIGTERM: lock released" "$ws/.chirat/lock"
if kill -0 "$cpid" 2>/dev/null; then ko "SIGTERM: claude is gone"; else ok "SIGTERM: claude is gone"; fi
rm -f "$ws/docs/plans/demo.prompt-9.md"

# --- lock owners, stale locks, stopping claude -----------------------------

runs=$ws/.chirat/runs
pf=$ws/docs/plans/demo.prompt-20.md

# A dead watcher, a dead runner and a dead claude leave the prompt `running`
# and the lock. die_mid_run <FAKE_MODE>: start, kill the watcher, its runner
# and claude's whole process group with -9, leave wpid/rpid/cpid/err/json set.
# (The runner is its own process since 0.3.0; left alive it would see claude
# die and mark the prompt `failed`, which is the point of a runner.)
die_mid_run() {
  FAKE_MODE=$1 "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
  wpid=$!
  wait_claude "$pf"
  cpid=$(cat "$ws/.chirat/lock/claude.pid")
  rpid=$(cat "$ws/.chirat/lock/runner.pid")
  run=$(cat "$ws/.chirat/lock/run")
  # Let the fake reach its sleep first: KILL to the group must not cut
  # chirat-prompt off between renaming the file and logging the change.
  for _ in $(seq 1 50); do
    ps -o pgid=,comm= -A 2>/dev/null | awk -v g="$cpid" '$1 == g && $2 ~ /sleep$/ { f = 1 } END { exit !f }' && break
    sleep 0.1
  done
  kill -9 "$wpid"
  kill -9 "$rpid"
  kill -9 -- "-$cpid"
  wait "$wpid" 2>/dev/null
  gone "$rpid"
  gone "$cpid"
  for _ in $(seq 1 50); do ps -o pgid= -A 2>/dev/null | tr -d ' ' | grep -qx "$cpid" || break; sleep 0.1; done
}

prompt demo.prompt-20.md sonnet pending
: >"$log"
rm -f "$ws/.chirat/status.log"
die_mid_run hang
eq "dead run: prompt still running" running "$("$rp" get "$pf" status)"
exists "dead run: lock left behind" -d "$ws/.chirat/lock"
exists "dead run: .json is empty" -f "$runs/$run.json"
"$watch" --once >"$tmp/out" 2>"$tmp/stderr"
has "heal: stderr says so" "$tmp/stderr" "recovered stale lock (claude $cpid dead)"
has "heal: err holds the note" "$runs/$run.err" "recovered: watcher/claude died with the prompt 'running'; set to pending"
absent "heal: empty .json removed" "$runs/$run.json"
absent "heal: lock gone" "$ws/.chirat/lock"
eq "heal: first log line is recovered" recovered "$(head -n 1 "$log" | cut -f5)"
eq "heal: log names the prompt" docs/plans/demo.prompt-20.md "$(head -n 1 "$log" | cut -f3)"
eq "heal: then the prompt ran again" "done" "$("$rp" get "$pf" status)"
eq_log "heal: two log lines (recovered, run)" 2 "$(wc -l <"$log" | tr -d ' ')"
eq "status.log: pending → running, running → pending (recovery), pending → running, running → done" \
  "pending	running
running	pending
pending	running
running	done" "$(cut -f3,4 "$ws/.chirat/status.log" | sed -n '1,4p;')"
eq "status.log: recovery's parent is chirat-watch" chirat-watch "$(sed -n 2p "$ws/.chirat/status.log" | cut -f7)"
eq "status.log: claude's parent is the fake claude" claude "$(sed -n 4p "$ws/.chirat/status.log" | cut -f7)"
eq "status.log: file column" docs/plans/demo.prompt-20.md "$(sed -n 1p "$ws/.chirat/status.log" | cut -f2)"
before=$(wc -l <"$ws/.chirat/status.log" | tr -d ' ')
"$rp" set "$pf" model opus
eq "status.log: other keys add nothing" "$before" "$(wc -l <"$ws/.chirat/status.log" | tr -d ' ')"

# A non-empty .json survives recovery.
"$rp" set "$pf" status pending
die_mid_run sleep
"$watch" --once >/dev/null 2>&1
exists "heal: non-empty .json kept" -s "$runs/$run.json"
has "heal: note in err" "$runs/$run.err" "recovered:"
eq "heal (sleep): prompt ran again" "done" "$("$rp" get "$pf" status)"

# Legacy lock: an empty directory and a running prompt.
"$rp" set "$pf" status running
mkdir "$ws/.chirat/lock"
rm -f "$runs"/demo.prompt-20.*.err
: >"$log"
"$watch" --once >/dev/null 2>&1
eq "legacy lock: prompt ran again after recovery" "done" "$("$rp" get "$pf" status)"
absent "legacy lock: lock gone" "$ws/.chirat/lock"
has "legacy lock: fresh err has the note" "$(first "$runs"/demo.prompt-20.*.err)" "recovered: watcher/claude died with the prompt 'running'; set to pending"
eq "legacy lock: recovered line logged" recovered "$(head -n 1 "$log" | cut -f5)"
eq "legacy lock: log names the prompt" docs/plans/demo.prompt-20.md "$(head -n 1 "$log" | cut -f3)"

# Legacy lock, nothing running: just removed, file column -.
mkdir "$ws/.chirat/lock"
: >"$log"
"$watch" --once >/dev/null 2>&1
absent "legacy lock without running prompt: lock gone" "$ws/.chirat/lock"
eq "legacy lock without running prompt: file column -" - "$(head -n 1 "$log" | cut -f3)"

# A live lock is respected, even when the prompt reads pending (not retried).
"$rp" set "$pf" status pending
FAKE_MODE="sleep" "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
cpid=$(cat "$ws/.chirat/lock/claude.pid")
"$rp" set "$pf" status pending
: >"$FAKE_ARGV"
"$watch" --once >"$tmp/out2" 2>"$tmp/stderr2"
has "live lock: says in progress" "$tmp/stderr2" "in progress, lock held by claude $cpid (docs/plans/demo.prompt-20.md)"
eq "live lock: prompt not retried" pending "$("$rp" get "$pf" status)"
eq "live lock: claude not started again" "" "$(cat "$FAKE_ARGV")"
exists "live lock: lock still there" -d "$ws/.chirat/lock"
kill -TERM "$wpid"
wait "$wpid"
eq "live lock: first watcher still exits 130 on TERM" 130 $?
if kill -0 "$cpid" 2>/dev/null; then ko "live lock: claude gone after TERM"; else ok "live lock: claude gone after TERM"; fi
absent "live lock: lock released after TERM" "$ws/.chirat/lock"

# SIGHUP behaves like SIGTERM.
"$rp" set "$pf" status pending
FAKE_MODE="sleep" "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
cpid=$(cat "$ws/.chirat/lock/claude.pid")
kill -HUP "$wpid"
wait "$wpid"
eq "SIGHUP: watcher exits 130" 130 $?
eq "SIGHUP: prompt back to pending" pending "$("$rp" get "$pf" status)"
absent "SIGHUP: lock released" "$ws/.chirat/lock"
if kill -0 "$cpid" 2>/dev/null; then ko "SIGHUP: claude is gone"; else ok "SIGHUP: claude is gone"; fi
has "SIGHUP: err names the signal" "$(find "$runs" -name 'demo.prompt-20.*.err' -print | sort | tail -n 1)" "(SIGHUP)"

# A claude that ignores TERM is killed after the grace period.
FAKE_MODE=stubborn CHIRAT_STOP_GRACE=2 "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
cpid=$(cat "$ws/.chirat/lock/claude.pid")
t0=$(date +%s)
kill -TERM "$wpid"
wait "$wpid"
eq "stubborn: watcher exits 130" 130 $?
if [ $(($(date +%s) - t0)) -le 20 ]; then ok "stubborn: stopped within 20 s"; else ko "stubborn: stopped within 20 s"; fi
if kill -0 "$cpid" 2>/dev/null; then ko "stubborn: claude PID gone (KILL)"; else ok "stubborn: claude PID gone (KILL)"; fi
eq "stubborn: prompt pending" pending "$("$rp" get "$pf" status)"
absent "stubborn: lock released" "$ws/.chirat/lock"

# --- process group: children of claude, group inspection ---------------------
# Four tests here need to look at other processes (pgrep -g / ps -A); when a
# sandbox denies that, they are skipped, not failed.
can_inspect=0
if ps -o pid=,pgid=,stat= -A >/dev/null 2>&1 || pgrep -g "$$" >/dev/null 2>&1; then can_inspect=1; fi
latest_err() { find "$runs" -name "demo.prompt-20.*.err" -print | sort | tail -n 1; }
if [ "$can_inspect" = 1 ]; then
  # The audit's repro: claude dies on TERM, its child ignores TERM. The
  # watcher must wait for the whole group, KILL it, and only then re-queue.
  export FAKE_CHILD=$tmp/child.pid
  rm -f "$FAKE_CHILD"
  FAKE_MODE=orphan CHIRAT_STOP_GRACE=2 "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
  wpid=$!
  wait_claude "$pf"
  cpid=$(cat "$ws/.chirat/lock/claude.pid")
  for _ in $(seq 1 50); do [ -s "$FAKE_CHILD" ] && break; sleep 0.1; done
  child=$(cat "$FAKE_CHILD")
  eq "orphan: the child is in claude's process group" "$cpid" "$(ps -o pgid= -p "$child" | tr -d ' ')"
  kill -TERM "$wpid"
  wait "$wpid"
  eq "orphan: watcher exits 130" 130 $?
  if kill -0 "$child" 2>/dev/null; then ko "orphan: child is dead after the watcher exits"; kill -9 "$child" 2>/dev/null; else ok "orphan: child is dead after the watcher exits"; fi
  if kill -0 "$cpid" 2>/dev/null; then ko "orphan: claude is gone"; else ok "orphan: claude is gone"; fi
  eq "orphan: prompt back to pending" pending "$("$rp" get "$pf" status)"
  absent "orphan: lock released" "$ws/.chirat/lock"
  eq "orphan: log exit column is interrupted" interrupted "$(tail -n 1 "$log" | cut -f5)"

  # Stubs for the branches KILL cannot produce: pgrep that always reports a
  # live member, pgrep/ps that fail. Without FAKE_PGREP / FAKE_PS they run the
  # real commands.
  real_pgrep=$(command -v pgrep) real_ps=$(command -v ps)
  cat >"$tmp/bin/pgrep" <<EOF
#!/usr/bin/env bash
case "\${FAKE_PGREP:-}:\$*" in
  alive:-g*) echo "\$FAKE_LIVE_PID"; exit 0 ;;
  error:-g*) exit 3 ;;
esac
exec "$real_pgrep" "\$@"
EOF
  cat >"$tmp/bin/ps" <<EOF
#!/usr/bin/env bash
case "\${FAKE_PS:-}:\$*" in
  error:*pgid*) exit 1 ;;
esac
exec "$real_ps" "\$@"
EOF
  chmod +x "$tmp/bin/pgrep" "$tmp/bin/ps"

  # A group that stays alive after KILL: prompt and lock are left alone.
  sleep 100 &
  live_pid=$!
  FAKE_MODE=sleep FAKE_PGREP=alive FAKE_LIVE_PID=$live_pid CHIRAT_STOP_GRACE=1 "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
  wpid=$!
  wait_claude "$pf"
  cpid=$(cat "$ws/.chirat/lock/claude.pid")
  kill -TERM "$wpid"
  wait "$wpid"
  eq "group alive after KILL: watcher exits 130" 130 $?
  eq "group alive after KILL: prompt left running" running "$("$rp" get "$pf" status)"
  exists "group alive after KILL: lock kept" -d "$ws/.chirat/lock"
  eq "group alive after KILL: log says interrupted-alive" interrupted-alive "$(tail -n 1 "$log" | cut -f5)"
  has "group alive after KILL: err says the group could not be stopped" "$(latest_err)" "process group $cpid could not be stopped; prompt left 'running', lock kept"
  kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
  kill -9 -- "-$cpid" 2>/dev/null
  rm -rf "$ws/.chirat/lock"
  "$rp" set "$pf" status pending

  # Inspection fails: unknown is never "gone" — prompt and lock are kept.
  FAKE_MODE=sleep FAKE_PGREP=error FAKE_PS=error CHIRAT_STOP_GRACE=1 "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
  wpid=$!
  wait_claude "$pf"
  cpid=$(cat "$ws/.chirat/lock/claude.pid")
  kill -TERM "$wpid"
  wait "$wpid"
  eq "inspection error: watcher exits 130" 130 $?
  eq "inspection error: prompt left running" running "$("$rp" get "$pf" status)"
  exists "inspection error: lock kept" -d "$ws/.chirat/lock"
  eq "inspection error: log says interrupted-alive" interrupted-alive "$(tail -n 1 "$log" | cut -f5)"
  has "inspection error: err says the group cannot be inspected" "$(latest_err)" "cannot inspect process group $cpid"
  kill -9 -- "-$cpid" 2>/dev/null
  rm -rf "$ws/.chirat/lock"
  "$rp" set "$pf" status pending
  rm -f "$tmp/bin/pgrep" "$tmp/bin/ps"

  # Lock liveness looks at the group: a dead leader with a live child is
  # live; a dead leader with only a zombie is stale.
  "$rp" set "$pf" status running
  set -m
  ( bash -c 'sleep 100 & sleep 0.2' ) &
  gl=$!
  set +m
  wait "$gl" 2>/dev/null
  mkdir -p "$ws/.chirat/lock"
  echo 999999 >"$ws/.chirat/lock/watcher.pid"
  echo "$gl" >"$ws/.chirat/lock/claude.pid"
  echo docs/plans/demo.prompt-20.md >"$ws/.chirat/lock/prompt"
  "$watch" status >"$tmp/st.out" 2>&1
  eq "dead leader, live child: status is not stale" 0 $?
  has "dead leader, live child: lock is claude's" "$tmp/st.out" "lock: claude $gl alive"
  "$watch" recover >"$tmp/out" 2>"$tmp/stderr"
  eq "dead leader, live child: recover refuses" 1 $?
  "$watch" --once >/dev/null 2>"$tmp/stderr"
  has "dead leader, live child: pass skips it as in progress" "$tmp/stderr" "in progress, lock held by claude $gl"
  eq "dead leader, live child: prompt untouched" running "$("$rp" get "$pf" status)"
  kill -9 -- "-$gl" 2>/dev/null
  for _ in $(seq 1 50); do ps -o pgid= -A 2>/dev/null | tr -d ' ' | grep -qx "$gl" || break; sleep 0.1; done
  "$watch" status >"$tmp/st.out" 2>&1
  eq "group gone: status is stale" 1 $?
  has "group gone: says claude dead" "$tmp/st.out" "STALE: claude $gl dead"
  rm -rf "$ws/.chirat/lock"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, subprocess, sys, time
p = subprocess.Popen(["sleep", "0.1"], preexec_fn=os.setsid)
time.sleep(0.6)
print(p.pid, flush=True)
time.sleep(60)' >"$tmp/zpid" &
    zholder=$!
    for _ in $(seq 1 50); do [ -s "$tmp/zpid" ] && break; sleep 0.1; done
    zpid=$(cat "$tmp/zpid")
    eq "zombie: the member is a zombie" Z "$(ps -o stat= -p "$zpid" | cut -c1)"
    mkdir -p "$ws/.chirat/lock"
    echo 999999 >"$ws/.chirat/lock/watcher.pid"
    echo "$zpid" >"$ws/.chirat/lock/claude.pid"
    "$watch" status >"$tmp/st.out" 2>&1
    eq "zombie-only group: status is stale" 1 $?
    has "zombie-only group: says claude dead" "$tmp/st.out" "STALE: claude $zpid dead"
    kill "$zholder" 2>/dev/null; wait "$zholder" 2>/dev/null
    rm -rf "$ws/.chirat/lock"
  else
    echo "skip zombie-only group test (needs python3)"
  fi
  "$rp" set "$pf" status pending
else
  echo "skip process group tests: orphan child, group alive after KILL, inspection error, dead/zombie members (ps/pgrep unavailable in this sandbox)"
fi
rm -f "$pf"

# --dry-run takes no lock and writes nothing, even with a live watcher's pid files around.
prompt demo.prompt-21.md sonnet pending
echo 424242 >"$XDG_STATE_HOME/chirat/watcher.pid"
echo "--interval" >"$XDG_STATE_HOME/chirat/watcher.flags"
before=$(fs_snapshot "$ws" "$XDG_STATE_HOME")
out=$("$watch" --once --dry-run 2>/dev/null)
absent "dry-run: no lock afterwards" "$ws/.chirat/lock"
has "dry-run: would run the pending prompt" <(printf '%s\n' "$out") "/chirat:next\\ docs/plans/demo.prompt-21.md"
eq "dry-run: pid files, log, runs, LATEST, status.log all unchanged" "$before" "$(fs_snapshot "$ws" "$XDG_STATE_HOME")"
rm -f "$XDG_STATE_HOME/chirat/watcher.pid" "$XDG_STATE_HOME/chirat/watcher.flags" "$ws/docs/plans/demo.prompt-21.md"

# --- after: waiting line, logged once --------------------------------------

wr=$ws/repos/demo
git init -q -b main "$wr"
git -C "$wr" commit -q --allow-empty -m init
git -C "$wr" branch dep
git -C "$wr" checkout -q dep
git -C "$wr" commit -q --allow-empty -m dep
git -C "$wr" checkout -q main
prompt demo.prompt-5.md sonnet pending
"$rp" set "$ws/docs/plans/demo.prompt-5.md" after dep
lines_before=$(wc -l <"$log" | tr -d ' ')
out=$("$watch" --once 2>/dev/null)
want=$(printf 'waiting\t%s\tdocs/plans/demo.prompt-5.md\tafter=dep' "$ws")
case $out in *"$want") ok "waiting line printed" ;; *) ko "waiting line printed" "$out" ;; esac
eq_log "waiting line logged" $((lines_before + 1)) "$(wc -l <"$log" | tr -d ' ')"
out=$("$watch" --once 2>/dev/null)
eq "waiting line not repeated within 10 minutes" "" "$out"
eq "waiting prompt stays pending, claude not run" pending "$("$rp" get "$ws/docs/plans/demo.prompt-5.md" status)"
git -C "$wr" merge -q --no-edit dep
"$watch" --once >/dev/null 2>&1
eq "merged dependency: prompt runs" "done" "$("$rp" get "$ws/docs/plans/demo.prompt-5.md" status)"

lines=$(wc -l <"$ws/.chirat/LATEST" | tr -d ' ')
git -C "$wr" branch feat/x
want=$(git -C "$wr" rev-parse --short feat/x)
prompt demo.prompt-6.md sonnet pending
"$watch" --once >/dev/null 2>&1
eq "LATEST: commit is the short hash of the branch" "$want" "$(tail -n 1 "$ws/.chirat/LATEST" | cut -f5)"
eq "LATEST: one line per run, none for waiting/misnamed" $((lines + 1)) "$(wc -l <"$ws/.chirat/LATEST" | tr -d ' ')"
rm -f "$ws/docs/plans/demo.prompt-6.md"

# --- commit: the result of a run, recorded in the prompt -----------------------

prompt demo.prompt-7.md sonnet pending
FAKE_COMMIT=1 "$watch" --once >/dev/null 2>&1
head7=$(git -C "$wr" rev-parse feat/x)
eq "commit: recorded after a done run (full sha of the branch head)" "$head7" "$("$rp" get "$ws/docs/plans/demo.prompt-7.md" commit)"
eq "commit: the prompt is part of the run log commit, no other prompt" "docs/plans/demo.prompt-7.md" "$(git -C "$ws" show --name-only --format= HEAD | grep '^docs/')"
eq "commit: nothing pending on the prompt" "" "$(git -C "$ws" status --porcelain -- docs/plans/demo.prompt-7.md)"
eq "LATEST: still the short hash" "$(git -C "$wr" rev-parse --short feat/x)" "$(tail -n 1 "$ws/.chirat/LATEST" | cut -f5)"
prompt demo.prompt-8.md sonnet pending
FAKE_COMMIT=1 FAKE_SET_COMMIT=deadbeef "$watch" --once >/dev/null 2>&1
eq "commit: a wrong value left by the run is corrected" "$(git -C "$wr" rev-parse feat/x)" "$("$rp" get "$ws/docs/plans/demo.prompt-8.md" commit)"
prompt demo.prompt-9b.md sonnet pending
"$rp" set "$ws/docs/plans/demo.prompt-9b.md" branch feat/gone
"$rp" set "$ws/docs/plans/demo.prompt-9b.md" commit "$head7"
"$watch" --once >/dev/null 2>&1
eq "commit: a rerun without a branch removes the stale value" 1 "$("$rp" get "$ws/docs/plans/demo.prompt-9b.md" commit >/dev/null 2>&1; echo $?)"
eq "commit: stale value removed — prompt still done" "done" "$("$rp" get "$ws/docs/plans/demo.prompt-9b.md" status)"
prompt demo.prompt-9c.md sonnet pending
FAKE_COMMIT=1 FAKE_FINAL=blocked "$watch" --once >/dev/null 2>&1
eq "commit: recorded for a blocked run with commits" "$(git -C "$wr" rev-parse feat/x)" "$("$rp" get "$ws/docs/plans/demo.prompt-9c.md" commit)"
prompt demo.prompt-9d.md sonnet pending
"$rp" set "$ws/docs/plans/demo.prompt-9d.md" branch feat/none
FAKE_MODE=noflip FAKE_EXIT=1 "$watch" --once >/dev/null 2>&1
eq "commit: none for a failed run without a branch" 1 "$("$rp" get "$ws/docs/plans/demo.prompt-9d.md" commit >/dev/null 2>&1; echo $?)"
rm -f "$ws"/docs/plans/demo.prompt-9[bcd].md
# after_mode: done — the opt-out warning is printed by the watcher and kept in the .err
prompt demo.prompt-10.md sonnet pending
"$rp" set "$ws/docs/plans/demo.prompt-10.md" after feat/x
"$rp" set "$ws/docs/plans/demo.prompt-10.md" after_mode "done"
out=$("$watch" --once 2>/dev/null)
eq "after_mode: done — the prompt ran" "done" "$("$rp" get "$ws/docs/plans/demo.prompt-10.md" status)"
case $out in *"after_mode: done — feat/x counts as satisfied because docs/plans/demo.prompt-8.md is done; this does not prove a merge into main"*) ok "after_mode: done — watcher prints the warning" ;; *) ko "after_mode: done — watcher prints the warning" "$out" ;; esac
has "after_mode: done — warning kept in the run's .err" "$(find "$ws/.chirat/runs" -name 'demo.prompt-10.*.err' | head -n 1)" "does not prove a merge"
rm -f "$ws/docs/plans/demo.prompt-10.md" "$ws"/docs/plans/demo.prompt-[78].md

# --- misnamed pending file, logged once ----------------------------------------

prompt demo.prompt-x.md sonnet pending
lines_before=$(wc -l <"$log" | tr -d ' ')
out=$("$watch" --once 2>/dev/null)
want=$(printf 'misnamed\t%s\tdocs/plans/demo.prompt-x.md\tname does not match <topic>.prompt-<N><suffix>.md' "$ws")
case $out in *"$want") ok "misnamed line printed" ;; *) ko "misnamed line printed" "$out" ;; esac
eq_log "misnamed line logged" $((lines_before + 1)) "$(wc -l <"$log" | tr -d ' ')"
out=$("$watch" --once 2>/dev/null)
eq "misnamed line not repeated" "" "$out"
rm -f "$ws/docs/plans/demo.prompt-x.md"

# --- install ----------------------------------------------------------------

inst=$tmp/inst/bin
"$watch" install "$inst" >"$tmp/out" 2>"$tmp/stderr"
eq "install exits 0" 0 $?
eq "install links chirat-watch" "$watch" "$(readlink "$inst/chirat-watch")"
eq "install links chirat-prompt" "$rp" "$(readlink "$inst/chirat-prompt")"
eq "install links chirat-init" "$root/bin/chirat-init" "$(readlink "$inst/chirat-init")"
"$inst/chirat-init" --help >"$tmp/out2" 2>&1
eq "installed chirat-init --help exits 0" 0 $?
has "installed chirat-init --help prints the help" "$tmp/out2" "<name>   folder name of the workspace"
has "install hints at PATH when needed" "$tmp/out" "is not on PATH"
eq "install off PATH: closing line, chirat-init by full path" \
  "next: \"$root/bin/chirat-init\" NAME --git-name \"Your Name\" --git-email you@example.com" "$(tail -n 1 "$tmp/out")"
if grep -q '^ok: ' "$tmp/out"; then ko "install off PATH: no ok line"; else ok "install off PATH: no ok line"; fi
"$watch" install "$inst" >"$tmp/out" 2>&1
eq "install is repeatable" 0 $?
eq "installed symlink finds the plugin" "$("$watch" --version)" "$("$inst/chirat-watch" --version)"
PATH=$inst:$PATH "$watch" install "$inst" >"$tmp/out" 2>&1
if grep -qF "not on PATH" "$tmp/out"; then ko "no PATH hint when dir is on PATH"; else ok "no PATH hint when dir is on PATH"; fi
eq "install on PATH: closing line" \
  "ok: $("$watch" --version) on PATH; next: chirat-init NAME --git-name \"Your Name\" --git-email you@example.com" "$(tail -n 1 "$tmp/out")"
# another copy earlier on PATH: no ok line, the winner is named, full path
mkdir -p "$tmp/other"
printf '#!/bin/sh\n' >"$tmp/other/chirat-watch"; chmod +x "$tmp/other/chirat-watch"
PATH=$tmp/other:$inst:$PATH "$watch" install "$inst" >"$tmp/out" 2>&1
eq "install shadowed chirat-watch exits 0" 0 $?
if grep -q '^ok: ' "$tmp/out"; then ko "install shadowed chirat-watch: no ok line" "$(cat "$tmp/out")"; else ok "install shadowed chirat-watch: no ok line"; fi
has "install shadowed chirat-watch: names the winner" "$tmp/out" "chirat-watch on PATH is $tmp/other/chirat-watch, not $inst/chirat-watch"
eq "install shadowed chirat-watch: chirat-init by full path" \
  "next: \"$root/bin/chirat-init\" NAME --git-name \"Your Name\" --git-email you@example.com" "$(tail -n 1 "$tmp/out")"
mv "$tmp/other/chirat-watch" "$tmp/other/chirat-init"
PATH=$tmp/other:$inst:$PATH "$watch" install "$inst" >"$tmp/out" 2>&1
eq "install shadowed chirat-init exits 0" 0 $?
if grep -q '^ok: ' "$tmp/out"; then ko "install shadowed chirat-init: no ok line" "$(cat "$tmp/out")"; else ok "install shadowed chirat-init: no ok line"; fi
has "install shadowed chirat-init: names the winner" "$tmp/out" "chirat-init on PATH is $tmp/other/chirat-init, not $inst/chirat-init"
if grep -qF "chirat-watch on PATH is" "$tmp/out"; then ko "install shadowed chirat-init: chirat-watch not named" "$(cat "$tmp/out")"; else ok "install shadowed chirat-init: chirat-watch not named"; fi
eq "install shadowed chirat-init: chirat-init by full path" \
  "next: \"$root/bin/chirat-init\" NAME --git-name \"Your Name\" --git-email you@example.com" "$(tail -n 1 "$tmp/out")"
rm -r "$tmp/other"
# PATH names dir through a symlink, install gets the physical path with a slash
ln -s "$inst" "$tmp/inst-link"
PATH=$tmp/inst-link:$PATH "$watch" install "$inst/" >"$tmp/out" 2>&1
eq "install via symlinked PATH exits 0" 0 $?
if grep -qF "on PATH is" "$tmp/out"; then ko "install via symlinked PATH: no winner line" "$(cat "$tmp/out")"; else ok "install via symlinked PATH: no winner line"; fi
eq "install via symlinked PATH: closing line" \
  "ok: $("$watch" --version) on PATH; next: chirat-init NAME --git-name \"Your Name\" --git-email you@example.com" "$(tail -n 1 "$tmp/out")"
rm "$tmp/inst-link"
# CDPATH with a decoy of the same relative name: the PATH entry is the caller's
mkdir -p "$tmp/cdw/inst" "$tmp/decoy/inst"
(cd "$tmp/cdw" && CDPATH=$tmp/decoy PATH=inst:$PATH "$watch" install "$tmp/cdw/inst" >"$tmp/out" 2>&1)
eq "install under CDPATH exits 0" 0 $?
eq "install under CDPATH: closing line" \
  "ok: $("$watch" --version) on PATH; next: chirat-init NAME --git-name \"Your Name\" --git-email you@example.com" "$(tail -n 1 "$tmp/out")"
if grep -qF "not on PATH" "$tmp/out"; then ko "install under CDPATH: no PATH hint" "$(cat "$tmp/out")"; else ok "install under CDPATH: no PATH hint"; fi
if grep -qF "on PATH is" "$tmp/out"; then ko "install under CDPATH: no winner line" "$(cat "$tmp/out")"; else ok "install under CDPATH: no winner line"; fi
eq "install under CDPATH: nothing written into the decoy" "" "$(ls -A "$tmp/decoy/inst")"
# a script started by a relative path resolves its own folder without CDPATH
mkdir -p "$tmp/rel" "$tmp/decoy/bin"
ln -s "$root/bin" "$tmp/rel/bin"; ln -s "$root/plugin" "$tmp/rel/plugin"
(cd "$tmp/rel" && CDPATH=$tmp/decoy bin/chirat-watch --version >"$tmp/out" 2>&1)
eq "relative start under CDPATH: --version is one line" "chirat-watch $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$root/plugin/.claude-plugin/plugin.json")" "$(cat "$tmp/out")"
rm -rf "$tmp/cdw" "$tmp/decoy" "$tmp/rel"
# a link to a directory is replaced itself, never written through
for n in chirat-init chirat-prompt; do
  mkdir -p "$tmp/elsewhere-$n"
  echo theirs >"$tmp/elsewhere-$n/$n"
  rm "$inst/$n"
  ln -s "$tmp/elsewhere-$n" "$inst/$n"
done
"$watch" install "$inst" >"$tmp/out" 2>&1
eq "install over links to directories exits 0" 0 $?
eq "install replaced the chirat-init link to a directory" "$root/bin/chirat-init" "$(readlink "$inst/chirat-init")"
eq "install replaced the chirat-prompt link to a directory" "$rp" "$(readlink "$inst/chirat-prompt")"
for n in chirat-init chirat-prompt; do
  if [ -f "$tmp/elsewhere-$n/$n" ] && [ ! -L "$tmp/elsewhere-$n/$n" ] && [ "$(cat "$tmp/elsewhere-$n/$n")" = theirs ]; then
    ok "install left the file behind the $n link alone"
  else
    ko "install left the file behind the $n link alone" "$(ls -l "$tmp/elsewhere-$n")"
  fi
done
rm -r "$tmp/elsewhere-chirat-init" "$tmp/elsewhere-chirat-prompt"
rm "$inst/chirat-prompt"
echo "mine" >"$inst/chirat-prompt"
"$watch" install "$inst" >"$tmp/out" 2>"$tmp/stderr"
eq "install refuses to overwrite a regular file" 1 $?
has "install says why" "$tmp/stderr" "not a symlink"
eq "install left the regular file alone" mine "$(cat "$inst/chirat-prompt")"
# a checkout without bin/chirat-init: refused before anything is linked
mkdir -p "$tmp/noinit/bin" "$tmp/noinit/plugin/bin"
cp "$watch" "$tmp/noinit/bin/"
cp "$rp" "$tmp/noinit/plugin/bin/"
"$tmp/noinit/bin/chirat-watch" install "$tmp/noinit/inst" >"$tmp/out" 2>"$tmp/stderr"
eq "install without chirat-init exits 1" 1 $?
has "install without chirat-init says why" "$tmp/stderr" "chirat-init not found next to this script: $tmp/noinit/bin/chirat-init"
absent "install without chirat-init links nothing" "$tmp/noinit/inst"

# --- status / recover / restart ------------------------------------------------

# Fake tmux: has-session succeeds for names in $FAKE_TMUX_SESSIONS, new-session
# records and (unless FAKE_TMUX_RUN=0) runs its command in the background,
# list-panes prints $FAKE_TMUX_PANE_PID, a session killed (and logged) is gone, everything is appended to $FAKE_TMUX_LOG.
# FAKE_TMUX_FAIL=N makes new-session start nothing and exit N; FAKE_TMUX_KEEP=1
# makes a killed session stay.
cat >"$tmp/bin/tmux" <<'EOT'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_TMUX_LOG"
case $1 in
  has-session)
    [ "${FAKE_TMUX_KEEP:-0}" = 1 ] || ! grep -qxF "kill-session -t ${3}" "$FAKE_TMUX_LOG" || exit 1 # killed since it was listed
    for s in ${FAKE_TMUX_SESSIONS:-}; do [ "$s" = "${3#=}" ] && exit 0; done
    exit 1 ;;
  new-session)
    [ -z "${FAKE_TMUX_FAIL:-}" ] || exit "$FAKE_TMUX_FAIL"
    [ "${FAKE_TMUX_RUN:-1}" = 0 ] || nohup bash -c "${*: -1}" </dev/null >/dev/null 2>&1 &
    exit 0 ;;
  list-panes) [ -z "${FAKE_TMUX_PANE_PID:-}" ] || echo "$FAKE_TMUX_PANE_PID"; exit 0 ;;
esac
exit 0
EOT
chmod +x "$tmp/bin/tmux"
export FAKE_TMUX_LOG=$tmp/tmux.log
: >"$FAKE_TMUX_LOG"

# A second workspace, alone in the config, so the earlier state does not matter.
ws=$tmp/ops
runs=$ws/.chirat/runs
mkdir -p "$ws"/docs/{plans,status} "$ws"/repos
printf '%s\n' "$ws" >"$XDG_CONFIG_HOME/chirat/workspaces"
git init -q -b main "$ws/repos/demo"
git -C "$ws/repos/demo" commit -q --allow-empty -m init
git -C "$ws/repos/demo" checkout -q -b dep
git -C "$ws/repos/demo" commit -q --allow-empty -m dep
git -C "$ws/repos/demo" checkout -q main
pf=$ws/docs/plans/demo.prompt-1.md
prompt demo.prompt-1.md sonnet pending
prompt demo.prompt-2.md sonnet pending
"$rp" set "$ws/docs/plans/demo.prompt-2.md" after dep
prompt demo.prompt-3.md sonnet blocked
rm -f "$XDG_STATE_HOME"/chirat/watcher.*

st() { "$watch" status "$@" >"$tmp/st.out" 2>"$tmp/st.err"; return $?; }

st
eq "status: clean workspace exits 0" 0 $?
has "status: no watcher" "$tmp/st.out" "watcher: not running"
has "status: tmux session absent" "$tmp/st.out" "tmux: session 'chirat' absent"
has "status: log line" "$tmp/st.out" "log: $log"
has "status: workspace as configured" "$tmp/st.out" "$ws"
has "status: queue with waiting and blocked" "$tmp/st.out" "queue: 2 pending (demo.prompt-1, demo.prompt-2 waiting after=dep), 0 running, 1 blocked (demo.prompt-3), 0 failed"
has "status: no lock" "$tmp/st.out" "lock: none"
has "status: no last run" "$tmp/st.out" "last: none"
st ops
eq "status: filter by bare name" 0 $?
has "status: filter keeps the workspace" "$tmp/st.out" "queue:"
st nosuch
eq "status: unknown workspace exits 1" 1 $?
FAKE_TMUX_SESSIONS=chirat st
eq "status: session without watcher is stale" 1 $?
has "status: says so" "$tmp/st.out" "STALE: tmux: session 'chirat' present but no live watcher"

# A watcher and its claude killed with -9.
: >"$log"
die_mid_run hang
st
eq "status: dead run exits 1" 1 $?
has "status: stale lock" "$tmp/st.out" "STALE: claude $cpid dead on docs/plans/demo.prompt-1.md"
has "status: dead watcher" "$tmp/st.out" "watcher: dead (stale pid file, pid $wpid)"
snap() { find "$ws" "$XDG_STATE_HOME" -type f -exec cksum {} + | sort; ls -A "$ws/.chirat/lock"; }
before=$(snap)
"$watch" recover --dry-run >"$tmp/out" 2>"$tmp/stderr"
eq "recover --dry-run exits 0" 0 $?
has "dry-run: would set pending" "$tmp/out" "would set docs/plans/demo.prompt-1.md pending"
has "dry-run: would remove the empty json" "$tmp/out" "would remove empty $runs/$run.json"
has "dry-run: would remove the lock" "$tmp/out" "would remove lock $ws/.chirat/lock"
eq "dry-run: nothing changed" "$before" "$(snap)"
eq "dry-run: prompt still running" running "$("$rp" get "$pf" status)"
# The audit's repro: --once --dry-run on a stale lock used to recover it for real.
before=$(fs_snapshot "$ws" "$XDG_STATE_HOME")
"$watch" --once --dry-run >"$tmp/out" 2>"$tmp/stderr"
eq "--once --dry-run on a stale lock exits 0" 0 $?
has "--once --dry-run: would set pending" "$tmp/out" "would set docs/plans/demo.prompt-1.md pending"
has "--once --dry-run: would remove the lock" "$tmp/out" "would remove lock $ws/.chirat/lock"
has "--once --dry-run: then would run the recovered prompt" "$tmp/out" "claude -p /chirat:next\\ docs/plans/demo.prompt-1.md"
eq "--once --dry-run: prompt still running" running "$("$rp" get "$pf" status)"
exists "--once --dry-run: lock still there" -d "$ws/.chirat/lock"
eq "--once --dry-run: nothing written (workspace, runs, err, log, pid files)" "$before" "$(fs_snapshot "$ws" "$XDG_STATE_HOME")"
"$watch" recover >"$tmp/out" 2>"$tmp/stderr"
eq "recover exits 0" 0 $?
has "recover: stderr line" "$tmp/stderr" "recovered stale lock (claude $cpid dead)"
has "recover: err note" "$runs/$run.err" "recovered: watcher/claude died with the prompt 'running'; set to pending"
eq "recover: prompt pending" pending "$("$rp" get "$pf" status)"
absent "recover: lock gone" "$ws/.chirat/lock"
absent "recover: empty json gone" "$runs/$run.json"
eq "recover: logged" recovered "$(head -n 1 "$log" | cut -f5)"
"$watch" recover >"$tmp/out" 2>&1
eq "recover with nothing to do exits 0" 0 $?
has "recover: says so" "$tmp/out" "nothing to recover"
rm -f "$XDG_STATE_HOME"/chirat/watcher.*

# A live watcher with a dead claude is between claude's exit and release_lock.
mkdir "$ws/.chirat/lock"
echo $$ >"$ws/.chirat/lock/watcher.pid"
echo "$cpid" >"$ws/.chirat/lock/claude.pid"
echo docs/plans/demo.prompt-1.md >"$ws/.chirat/lock/prompt"
echo "$run" >"$ws/.chirat/lock/run"
date +%Y-%m-%dT%H:%M:%S%z >"$ws/.chirat/lock/started"
"$rp" set "$pf" status running
st
eq "status: live watcher, dead claude is not stale" 0 $?
has "status: held by the watcher" "$tmp/st.out" "lock: held by watcher $$ on docs/plans/demo.prompt-1.md"
before=$(snap)
"$watch" recover >"$tmp/out" 2>"$tmp/stderr"
eq "recover: refuses a live lock" 1 $?
has "recover: names the owner" "$tmp/stderr" "lock held by watcher $$"
"$watch" --once >/dev/null 2>"$tmp/stderr"
has "pass: skips it as in progress" "$tmp/stderr" "in progress, lock held by watcher $$"
eq "recover/pass left everything alone" "$before" "$(snap)"
rm -f "$ws/.chirat/lock"/*
rmdir "$ws/.chirat/lock"

# running prompt without a lock
st
eq "status: running prompt without lock exits 0" 0 $?
has "status: warns" "$tmp/st.out" "  warn: docs/plans/demo.prompt-1.md is running with no lock (interactive run, or flip it by hand)"
if grep -q STALE "$tmp/st.out"; then ko "status: no STALE for it"; else ok "status: no STALE for it"; fi
"$rp" set "$pf" status pending

# live run
: >"$FAKE_TMUX_LOG"
env FAKE_MODE=sleep "$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
eq "watcher.pid while running" "$wpid" "$(cat "$XDG_STATE_HOME/chirat/watcher.pid")"
eq "watcher.flags while running" "--interval
1000" "$(cat "$XDG_STATE_HOME/chirat/watcher.flags")"
st
eq "status: live run exits 0" 0 $?
has "status: watcher alive with flags" "$tmp/st.out" "watcher: alive (pid $wpid, flags: --interval 1000, parallel: 1)"
has "status: claude alive since" "$tmp/st.out" "alive since"
has "status: running prompt listed" "$tmp/st.out" "1 running (demo.prompt-1)"
cpid=$(cat "$ws/.chirat/lock/claude.pid")
"$watch" restart >"$tmp/out" 2>"$tmp/stderr"
eq "restart: refused during a live run" 1 $?
has "restart: names the prompt" "$tmp/stderr" "docs/plans/demo.prompt-1.md is running"
if kill -0 "$wpid" 2>/dev/null && kill -0 "$cpid" 2>/dev/null; then ok "restart: refusal stopped nothing"; else ko "restart: refusal stopped nothing"; fi
eq "restart: refusal started nothing" "" "$(grep new-session "$FAKE_TMUX_LOG")"
FAKE_TMUX_RUN=0 "$watch" restart --force >"$tmp/out" 2>"$tmp/stderr"
eq "restart --force exits 0" 0 $?
wait "$wpid"
eq "restart --force: old watcher exited 130" 130 $?
eq "restart --force: prompt back to pending" pending "$("$rp" get "$pf" status)"
absent "watcher.pid gone after exit" "$XDG_STATE_HOME/chirat/watcher.pid"
absent "watcher.flags gone after exit" "$XDG_STATE_HOME/chirat/watcher.flags"
has "restart --force: new session with the original flags" "$FAKE_TMUX_LOG" "--interval 1000"
has "restart --force: new-session" "$FAKE_TMUX_LOG" "new-session -d -s chirat"

# restart with no watcher starts one (nothing pending, so it idles)
"$rp" set "$pf" status "done"
"$rp" set "$ws/docs/plans/demo.prompt-2.md" status "done"
: >"$FAKE_TMUX_LOG"
"$watch" restart >"$tmp/out" 2>"$tmp/stderr"
eq "restart without a watcher exits 0" 0 $?
has "restart: says no watcher" "$tmp/out" "no watcher running"
has "restart: prints the new watcher line" "$tmp/out" "watcher: alive (pid "
wpid=$(cat "$XDG_STATE_HOME/chirat/watcher.pid")
exists "new watcher wrote watcher.flags" -e "$XDG_STATE_HOME/chirat/watcher.flags"
eq "no flags: empty watcher.flags" "" "$(cat "$XDG_STATE_HOME/chirat/watcher.flags")"
kill -TERM "$wpid"
gone "$wpid"
absent "watcher.pid gone after TERM" "$XDG_STATE_HOME/chirat/watcher.pid"
absent "watcher.flags gone after TERM" "$XDG_STATE_HOME/chirat/watcher.flags"

# no pid file: the pane of the tmux session is the fallback; the session is killed
sleep 100 &
spid=$!
: >"$FAKE_TMUX_LOG"
FAKE_TMUX_SESSIONS=chirat FAKE_TMUX_PANE_PID=$spid FAKE_TMUX_RUN=0 "$watch" restart >"$tmp/out" 2>"$tmp/stderr"
eq "restart via pane pid exits 0" 0 $?
wait "$spid" 2>/dev/null
if kill -0 "$spid" 2>/dev/null; then ko "restart: pane process stopped"; else ok "restart: pane process stopped"; fi
has "restart: leftover session killed" "$FAKE_TMUX_LOG" "kill-session -t =chirat"
has "restart: new session started" "$FAKE_TMUX_LOG" "new-session -d -s chirat"

# --- start / stop / restart with flags ---------------------------------------
# Every call goes through the fake tmux above; nothing here reaches a real one.

wfile=$XDG_STATE_HOME/chirat/watcher.pid
ffile=$XDG_STATE_HOME/chirat/watcher.flags
nosess() { if grep -q "$1" "$FAKE_TMUX_LOG"; then ko "$2" "$(cat "$FAKE_TMUX_LOG")"; else ok "$2"; fi; }
lacks() { # lacks <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then ko "$1" "[$3] in $2:"$'\n'"$(cat "$2")"; else ok "$1"; fi
}
dead_pid() { sh -c 'exit 0' & local d=$!; wait "$d"; echo "$d"; }
# fake_watcher <flag…>: a process that stands in for a recorded watcher
fake_watcher() {
  sleep 100 &
  fwpid=$!
  echo "$fwpid" >"$wfile"
  if [ $# -gt 0 ]; then printf '%s\n' "$@" >"$ffile"; else : >"$ffile"; fi
}

# start: the flags reach new-session; a second start is refused
: >"$FAKE_TMUX_LOG"
"$watch" start --interval 1000 --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr"
eq "start exits 0" 0 $?
has "start: new-session with the flags given" "$FAKE_TMUX_LOG" "--interval 1000 --max-parallel 2"
has "start: prints the watcher line" "$tmp/out" "watcher: alive (pid "
cp "$tmp/out" "$tmp/start.out"
wpid=$(cat "$wfile")
: >"$FAKE_TMUX_LOG"
FAKE_TMUX_SESSIONS=chirat "$watch" start >"$tmp/out" 2>"$tmp/stderr"
eq "start: refused while a watcher runs" 1 $?
has "start: refusal shows the watcher line" "$tmp/stderr" "watcher: alive (pid $wpid, flags: --interval 1000 --max-parallel 2"
has "start: refusal points at restart" "$tmp/stderr" "chirat-watch restart"
nosess new-session "start: refusal started nothing"
"$watch" start --once >"$tmp/out" 2>"$tmp/stderr"
eq "start --once is a usage error" 64 $?
"$watch" start --dry-run >"$tmp/out" 2>"$tmp/stderr"
eq "start --dry-run is a usage error" 64 $?
"$watch" start --max-parallel 0 >"$tmp/out" 2>"$tmp/stderr"
eq "start: bad --max-parallel exits 1" 1 $?

# stop with a watcher and no run
: >"$FAKE_TMUX_LOG"
FAKE_TMUX_SESSIONS=chirat "$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "stop exits 0" 0 $?
if gone "$wpid"; then ok "stop: the watcher is gone"; else ko "stop: the watcher is gone"; fi
has "stop: says what it stopped, with the flags" "$tmp/out" "stopped watcher $wpid (flags: --interval 1000 --max-parallel 2)"
has "stop: the command that starts it again" "$tmp/out" "start again with: chirat-watch start --interval 1000 --max-parallel 2"
has "stop: session killed" "$FAKE_TMUX_LOG" "kill-session -t =chirat"
nosess new-session "stop: starts nothing"
cp "$tmp/out" "$tmp/stop.out"
"$watch" start >/dev/null 2>&1
wpid=$(cat "$wfile")
"$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "stop (no flags) exits 0" 0 $?
gone "$wpid"
has "stop: flags none" "$tmp/out" "stopped watcher $wpid (flags: none)"
eq "stop: flags none starts again with the bare start" "start again with: chirat-watch start" "$(grep '^start again with:' "$tmp/out")"

# stop with no watcher, with and without a leftover session
: >"$FAKE_TMUX_LOG"
"$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "stop without a watcher exits 0" 0 $?
has "stop: says no watcher" "$tmp/out" "no watcher running"
nosess kill-session "stop: no session, nothing killed"
FAKE_TMUX_SESSIONS=chirat "$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "stop: leftover session, exits 0" 0 $?
has "stop: leftover session killed" "$FAKE_TMUX_LOG" "kill-session -t =chirat"
lacks "stop: nothing claimed stopped" "$tmp/out" "stopped watcher"

# start that does not start
: >"$FAKE_TMUX_LOG"
FAKE_TMUX_SESSIONS=chirat "$watch" start >"$tmp/out" 2>"$tmp/stderr"
eq "start: session without a watcher is refused" 1 $?
has "start: names the session" "$tmp/stderr" "tmux session 'chirat' exists but no live watcher is recorded"
has "start: points at stop" "$tmp/stderr" "chirat-watch stop"
nosess new-session "start: no new-session then"
FAKE_TMUX_FAIL=3 "$watch" start >"$tmp/out" 2>"$tmp/stderr"
eq "start: failed new-session's status passed on" 3 $?
lacks "start: no running line" "$tmp/out" "running in tmux"
lacks "start: no watcher line" "$tmp/out" "watcher:"
cp "$tmp/stderr" "$tmp/startfail.err"
FAKE_TMUX_RUN=0 "$watch" start >"$tmp/out" 2>"$tmp/stderr"
eq "start: session but no watcher pid exits 1" 1 $?
has "start: says the watcher did not start" "$tmp/stderr" "watcher did not start; look at it with: tmux attach -t chirat; log: $log"
lacks "start: no watcher line then" "$tmp/out" "watcher:"
cp "$tmp/stderr" "$tmp/startnone.err"

# --tmux keeps its old checks: no pid wait (dry-run, once), but a failed
# new-session is passed on, also through restart
FAKE_TMUX_RUN=0 "$watch" --tmux --dry-run >"$tmp/out" 2>"$tmp/stderr"
eq "--tmux --dry-run exits 0 without a pid file" 0 $?
has "--tmux --dry-run: today's message" "$tmp/out" "chirat-watch running in tmux session 'chirat'"
FAKE_TMUX_RUN=0 "$watch" --tmux --once >"$tmp/out" 2>"$tmp/stderr"
eq "--tmux --once exits 0 without a pid file" 0 $?
has "--tmux --once: today's message" "$tmp/out" "chirat-watch running in tmux session 'chirat'"
FAKE_TMUX_FAIL=3 "$watch" --tmux >"$tmp/out" 2>"$tmp/stderr"
eq "--tmux: failed new-session's status passed on" 3 $?
lacks "--tmux: no running line then" "$tmp/out" "running in tmux"
FAKE_TMUX_FAIL=3 "$watch" restart >"$tmp/out" 2>"$tmp/stderr"
eq "restart: failed new-session exits non-zero" 3 $?
lacks "restart: no watcher line then" "$tmp/out" "watcher:"

# stop verifies: a session that stays, a watcher that stays
"$watch" start >/dev/null 2>&1
wpid=$(cat "$wfile")
: >"$FAKE_TMUX_LOG"
FAKE_TMUX_SESSIONS=chirat FAKE_TMUX_KEEP=1 "$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "stop: session still there exits 1" 1 $?
has "stop: names the session" "$tmp/stderr" "tmux session 'chirat' is still there"
lacks "stop: no stopped line (session)" "$tmp/out" "stopped watcher"
lacks "stop: no start again line (session)" "$tmp/out" "start again with:"
cp "$tmp/stderr" "$tmp/stopkeep.err"
gone "$wpid"
"$watch" start >/dev/null 2>&1
wpid=$(cat "$wfile")
CHIRAT_STOP_GRACE=0 CHIRAT_TEST_SPARE_PID=$wpid "$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "stop: watcher still there exits 1" 1 $?
has "stop: names the watcher" "$tmp/stderr" "watcher $wpid is still running"
lacks "stop: no stopped line (watcher)" "$tmp/out" "stopped watcher"
lacks "stop: no start again line (watcher)" "$tmp/out" "start again with:"
cp "$tmp/stderr" "$tmp/stopspare.err"
kill -TERM "$wpid"; gone "$wpid"

# the start again line is quoted and works
fake_watcher --permission-mode "a b"
"$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "stop: quoted flags, exits 0" 0 $?
wait "$fwpid" 2>/dev/null
line=$(sed -n 's/^start again with: //p' "$tmp/out")
eval "set -- $line"
eq "stop: start again line evaluates to the kept arguments" "4|chirat-watch|start|--permission-mode|a b" "$#|$1|$2|$3|$4"
set --
cp "$tmp/out" "$tmp/stopquote.out"
fake_watcher --once --interval 5
"$watch" stop >"$tmp/out" 2>"$tmp/stderr"
wait "$fwpid" 2>/dev/null
eq "stop: --once kept, the bare form" "run again with: chirat-watch --once --interval 5" "$(grep 'again with:' "$tmp/out")"
lacks "stop: --once kept, no start line" "$tmp/out" "chirat-watch start"
cp "$tmp/out" "$tmp/stoponce.out"
fake_watcher --once
: >"$FAKE_TMUX_LOG"
FAKE_TMUX_SESSIONS=chirat "$watch" stop >"$tmp/out" 2>"$tmp/stderr"
wait "$fwpid" 2>/dev/null
eq "stop: --once kept with a session, --tmux first" "run again with: chirat-watch --tmux --once" "$(grep 'again with:' "$tmp/out")"
rm -f "$wfile" "$ffile"

# The again line reads the kept flags as pairs: --once as the value of
# --permission-mode is not the --once flag.
fake_watcher --permission-mode --once
"$watch" stop >"$tmp/out" 2>"$tmp/stderr"
wait "$fwpid" 2>/dev/null
eq "stop: --once as a value, the start form" "start again with: chirat-watch start --permission-mode --once" "$(grep 'again with:' "$tmp/out")"
rm -f "$wfile" "$ffile"


# A live run under a watcher: restart with a bad flag value and plain stop
# are refused and touch nothing; stop --force stops it, starts nothing.
"$rp" set "$pf" status pending
: >"$FAKE_TMUX_LOG"
env FAKE_MODE=sleep "$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
cpid=$(cat "$ws/.chirat/lock/claude.pid")
"$watch" restart --interval --force >"$tmp/out" 2>"$tmp/stderr"
eq "restart --interval --force: bad --interval, not --force" 1 $?
has "restart --interval --force: the --interval message" "$tmp/stderr" "--interval needs a whole number of seconds"
"$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "stop: refused during a live run" 1 $?
has "stop: names the prompt" "$tmp/stderr" "refusing to stop: ops/docs/plans/demo.prompt-1.md is running (claude $cpid"
has "stop: refusal names --force" "$tmp/stderr" "--force stops it and puts the prompt back to pending"
cp "$tmp/stderr" "$tmp/stoprefuse.err"
if kill -0 "$wpid" 2>/dev/null && kill -0 "$cpid" 2>/dev/null; then ok "refusals and the bad flag stopped nothing"; else ko "refusals and the bad flag stopped nothing"; fi
eq "refusals and the bad flag: no tmux call that changes anything" "" "$(grep -E 'kill-session|new-session' "$FAKE_TMUX_LOG")"
eq "refusals: prompt still running" running "$("$rp" get "$pf" status)"
"$watch" stop --force >"$tmp/out" 2>"$tmp/stderr"
eq "stop --force exits 0" 0 $?
wait "$wpid"
eq "stop --force: watcher exited 130" 130 $?
eq "stop --force: prompt back to pending" pending "$("$rp" get "$pf" status)"
absent "stop --force: lock released" "$ws/.chirat/lock"
has "stop --force: stopped line" "$tmp/out" "stopped watcher $wpid (flags: --interval 1000)"
nosess new-session "stop --force: no new-session"
cp "$tmp/out" "$tmp/stopforce.out"

# A run whose watcher is gone (the T14 situation): stop refuses, and stop
# --force leaves it alone too: it is named, exit 1.
env FAKE_MODE=sleep "$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
rpid=$(cat "$ws/.chirat/lock/runner.pid") cpid=$(cat "$ws/.chirat/lock/claude.pid")
kill -9 "$wpid"
wait "$wpid" 2>/dev/null
: >"$FAKE_TMUX_LOG"
"$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "orphan: stop refused" 1 $?
has "orphan: stop names the run" "$tmp/stderr" "ops/docs/plans/demo.prompt-1.md is running"
if kill -0 "$rpid" 2>/dev/null; then ok "orphan: runner still alive after the refusal"; else ko "orphan: runner still alive after the refusal"; fi
"$watch" stop --force >"$tmp/out" 2>"$tmp/stderr"
eq "orphan: stop --force exits 1" 1 $?
if kill -0 "$rpid" 2>/dev/null && kill -0 "$cpid" 2>/dev/null; then ok "orphan: runner and claude alive after stop --force"; else ko "orphan: runner and claude alive after stop --force"; fi
eq "orphan: prompt still running" running "$("$rp" get "$pf" status)"
has "orphan: says no watcher" "$tmp/out" "no watcher running"
has "orphan: names the run it left" "$tmp/stderr" "$ws/docs/plans/demo.prompt-1.md is still running (claude $cpid); stop --force stops only the runs of the watcher it stops — see docs/safety.md"
lacks "orphan: stopped no runner" "$tmp/stderr" "stopped runner"
nosess new-session "orphan: no new-session"
cat "$tmp/out" "$tmp/stderr" >"$tmp/stoporphan.out"
kill -TERM "$rpid"
gone "$rpid"
eq "orphan: the test's TERM puts it back" pending "$("$rp" get "$pf" status)"
rm -f "$wfile" "$ffile"

# orphan_lock <runner pid> [claude pid]: a lock whose watcher is dead
orphan_lock() {
  local l=$ws/.chirat/lock
  mkdir -p "$l"
  dead_pid >"$l/watcher.pid"
  echo "$1" >"$l/runner.pid"
  [ -z "${2:-}" ] || echo "$2" >"$l/claude.pid"
  echo docs/plans/demo.prompt-1.md >"$l/prompt"
  echo demo.prompt-1.20260101-000000 >"$l/run"
  echo 2026-01-01T00:00:00+0000 >"$l/started"
  "$rp" set "$pf" status running
}
clear_lock() { rm -rf "$ws/.chirat/lock"; "$rp" set "$pf" status pending; }
# sig_marker <file>: a process that writes each signal it gets to <file> and
# keeps running
sig_marker() { bash -c 'trap "echo TERM >>$0" TERM; trap "echo INT >>$0" INT; trap "echo HUP >>$0" HUP; while :; do sleep 0.2; done' "$1" & }

# The same during setup: a live runner, no claude.pid.
sleep 100 &
hr=$!
orphan_lock "$hr"
"$watch" stop >"$tmp/out" 2>"$tmp/stderr"
eq "setup: stop refused" 1 $?
has "setup: stop names it" "$tmp/stderr" "ops/docs/plans/demo.prompt-1.md is running (runner $hr"
"$watch" stop --force >"$tmp/out" 2>"$tmp/stderr"
eq "setup: stop --force exits 1" 1 $?
if kill -0 "$hr" 2>/dev/null; then ok "setup: runner alive after stop --force"; else ko "setup: runner alive after stop --force"; fi
has "setup: names the run it left" "$tmp/stderr" "$ws/docs/plans/demo.prompt-1.md is still running (runner $hr); stop --force stops only the runs of the watcher it stops — see docs/safety.md"
cp "$tmp/stderr" "$tmp/stopsetup.err"
kill -9 "$hr" 2>/dev/null; wait "$hr" 2>/dev/null
clear_lock
bash -c 'trap "" TERM; while :; do sleep 0.2; done' &
hr=$!
orphan_lock "$hr"
CHIRAT_STOP_GRACE=0 "$watch" stop --force >"$tmp/out" 2>"$tmp/stderr"
eq "setup, runner ignores TERM: stop --force exits 1" 1 $?
has "setup, runner ignores TERM: still running" "$tmp/stderr" "$ws/docs/plans/demo.prompt-1.md is still running (runner $hr)"
kill -9 "$hr" 2>/dev/null; wait "$hr" 2>/dev/null
clear_lock

# The mixed case: no recorded watcher, a live orphaned run and a session whose
# pane is a process of this test. stop --force stops the pane's process and
# closes the session; the orphaned runner and its claude get no signal.
rm -f "$wfile" "$ffile" "$tmp/sig.r" "$tmp/sig.c" "$tmp/sig.p"
sig_marker "$tmp/sig.r"
hr=$!
sig_marker "$tmp/sig.c"
hc=$!
bash -c 'trap "echo TERM >>$0; exit 0" TERM; while :; do sleep 0.2; done' "$tmp/sig.p" &
hp=$!
orphan_lock "$hr" "$hc"
: >"$FAKE_TMUX_LOG"
FAKE_TMUX_SESSIONS=chirat FAKE_TMUX_PANE_PID=$hp "$watch" stop --force >"$tmp/out" 2>"$tmp/stderr"
eq "mixed: stop --force exits 1" 1 $?
wait "$hp" 2>/dev/null
eq "mixed: the pane's process got TERM" TERM "$(cat "$tmp/sig.p" 2>/dev/null)"
if kill -0 "$hp" 2>/dev/null; then ko "mixed: the pane's process is gone"; else ok "mixed: the pane's process is gone"; fi
has "mixed: session closed" "$FAKE_TMUX_LOG" "kill-session -t =chirat"
has "mixed: stopped line for the pane's process" "$tmp/out" "stopped watcher $hp (flags: none)"
sleep 0.5
absent "mixed: the orphaned runner got no signal" "$tmp/sig.r"
absent "mixed: its claude got no signal" "$tmp/sig.c"
if kill -0 "$hr" 2>/dev/null && kill -0 "$hc" 2>/dev/null; then ok "mixed: runner and claude alive"; else ko "mixed: runner and claude alive"; fi
has "mixed: names the run it left" "$tmp/stderr" "$ws/docs/plans/demo.prompt-1.md is still running (claude $hc); stop --force stops only the runs of the watcher it stops — see docs/safety.md"
eq "mixed: prompt still running" running "$("$rp" get "$pf" status)"
cat "$tmp/out" "$tmp/stderr" >"$tmp/stopmixed.out"
kill -9 "$hr" "$hc" 2>/dev/null; wait "$hr" "$hc" 2>/dev/null
clear_lock

# The KILL fallback with a lock whose runner is gone: claude's group is
# stopped, the lock is left for recovery and the prompt is not pending yet.
env FAKE_MODE=sleep "$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
rpid=$(cat "$ws/.chirat/lock/runner.pid") cpid=$(cat "$ws/.chirat/lock/claude.pid")
kill -STOP "$wpid"
kill -9 "$rpid"
CHIRAT_STOP_GRACE=0 "$watch" stop --force >"$tmp/out" 2>"$tmp/stderr"
eq "KILL fallback, runner gone: stop --force exits 0" 0 $?
wait "$wpid" 2>/dev/null
has "KILL fallback: the watcher was killed" "$tmp/stderr" "did not stop within 10 s, sending KILL"
has "KILL fallback: claude's group stopped" "$tmp/stderr" "stopped claude's process group $cpid"
has "KILL fallback: left for recovery" "$tmp/stderr" "$ws: lock left for recovery (claude $cpid dead, docs/plans/demo.prompt-1.md); the next chirat-watch start recovers it"
lacks "KILL fallback: not claimed pending" "$tmp/stderr" "pending again"
eq "KILL fallback: prompt not pending yet" running "$("$rp" get "$pf" status)"
cat "$tmp/out" "$tmp/stderr" >"$tmp/stopkill.out"
"$watch" recover >/dev/null 2>&1
eq "KILL fallback: recover puts it back" pending "$("$rp" get "$pf" status)"
"$rp" set "$pf" status "done"
rm -f "$wfile" "$ffile"

# stop without tmux on PATH: a foreground watcher is stopped, and the again
# line is the foreground form.
mkdir -p "$tmp/nt"
for _f in "$tmp/bin"/*; do [ "${_f##*/}" = tmux ] || ln -sf "$_f" "$tmp/nt/"; done
nt_path=$tmp/nt
# A directory that holds tmux is replaced by a shadow of it (a link to every
# entry but tmux), so what shares the directory with tmux (env, bash on
# ubuntu) stays; a directory reached twice (/bin -> /usr/bin) counts once.
nt_seen=:
nt_n=0
IFS=: read -ra _pd <<<"$clean_path"
for _d in "${_pd[@]}"; do
  if [ ! -x "$_d/tmux" ]; then
    nt_path=$nt_path:$_d
    continue
  fi
  _real=$(cd -P "$_d" && pwd -P) || continue
  case $nt_seen in *":$_real:"*) continue ;; esac
  nt_seen=$nt_seen$_real:
  nt_n=$((nt_n + 1))
  mkdir -p "$tmp/nt-shadow$nt_n"
  (
    shopt -s dotglob nullglob
    for _e in "$_real"/*; do
      [ "${_e##*/}" = tmux ] || ln -s "$_e" "$tmp/nt-shadow$nt_n/"
    done
  )
  nt_path=$nt_path:$tmp/nt-shadow$nt_n
done
if PATH=$nt_path command -v tmux >/dev/null 2>&1; then ko "no tmux: none on the test PATH"; else ok "no tmux: none on the test PATH"; fi
nt_missing=""
for _c in env bash ps git sed awk date sleep cat stat tr head tail dirname basename mkdir rm mv kill pgrep; do
  PATH=$nt_path command -v "$_c" >/dev/null 2>&1 || nt_missing="$nt_missing $_c"
done
eq "no tmux: the tools the watcher needs are on that PATH" "" "${nt_missing# }"
nt_ready() { # nt_ready <flags>: watcher.pid holds $wpid, it is alive, watcher.flags is there with exactly that content
  [ "$(cat "$wfile" 2>/dev/null)" = "$wpid" ] && kill -0 "$wpid" 2>/dev/null &&
    [ -f "$ffile" ] && [ "$(cat "$ffile" 2>/dev/null)" = "$1" ]
}
nt_found() { echo "pid [$(cat "$wfile" 2>/dev/null)] want [$wpid], alive [$(kill -0 "$wpid" 2>/dev/null && echo yes || echo no)], flags [$(cat "$ffile" 2>/dev/null)]"; }
nt_reap() { # nt_reap <pid>: end the process this test started, never anything else; wait only once it is gone
  if kill -0 "$1" 2>/dev/null; then
    kill -TERM "$1" 2>/dev/null
    gone "$1" || { kill -KILL "$1" 2>/dev/null; gone "$1"; }
  fi
  if kill -0 "$1" 2>/dev/null; then echo "     process $1 survived KILL; not waiting for it"; return 1; fi
  wait "$1" 2>/dev/null
  return 0
}
PATH=$nt_path "$watch" --interval 1000 >/dev/null 2>&1 &
wpid=$!
nt_flags=$(printf '%s\n' --interval 1000)
if until_true 100 nt_ready "$nt_flags"; then
  ok "no tmux: the watcher started"
  PATH=$nt_path "$watch" stop >"$tmp/out" 2>"$tmp/stderr"
  eq "no tmux: stop exits 0" 0 $?
  if gone "$wpid"; then ok "no tmux: the watcher is gone"; else ko "no tmux: the watcher is gone"; fi
  nt_reap "$wpid"
  has "no tmux: stopped line" "$tmp/out" "stopped watcher $wpid (flags: --interval 1000)"
  eq "no tmux: the foreground again line" "run again with: chirat-watch --interval 1000" "$(grep 'again with:' "$tmp/out")"
  lacks "no tmux: no start form" "$tmp/out" "chirat-watch start"
  lacks "no tmux: not refused for tmux" "$tmp/stderr" "tmux not installed"
else
  ko "no tmux: the watcher started" "$(nt_found)"
  ko "no tmux: stop and its assertions not run, the watcher was not ready"
  nt_reap "$wpid"
  : >"$tmp/out"
fi
cp "$tmp/out" "$tmp/stopnotmux.out"
PATH=$nt_path "$watch" >/dev/null 2>&1 &
wpid=$!
if until_true 100 nt_ready ""; then
  ok "no tmux, no flags: the watcher started"
  PATH=$nt_path "$watch" stop >"$tmp/out" 2>"$tmp/stderr"
  eq "no tmux, no flags: stop exits 0" 0 $?
  if gone "$wpid"; then ok "no tmux, no flags: the watcher is gone"; else ko "no tmux, no flags: the watcher is gone"; fi
  nt_reap "$wpid"
  eq "no tmux, no flags: the bare again line" "run again with: chirat-watch" "$(grep 'again with:' "$tmp/out")"
  lacks "no tmux, no flags: no start form" "$tmp/out" "chirat-watch start"
else
  ko "no tmux, no flags: the watcher started" "$(nt_found)"
  ko "no tmux, no flags: stop and its assertions not run, the watcher was not ready"
  nt_reap "$wpid"
  : >"$tmp/out"
fi
cat "$tmp/out" >>"$tmp/stopnotmux.out"
rm -f "$wfile" "$ffile"

# restart replaces the kept flag of the same name; --force on either side
"$watch" --interval 1000 --max-parallel 2 >/dev/null 2>&1 &
wpid=$!
until_true 50 test -s "$wfile"
: >"$FAKE_TMUX_LOG"
"$watch" restart --max-parallel 0 >"$tmp/out" 2>"$tmp/stderr"
eq "restart --max-parallel 0 exits 1" 1 $?
"$watch" restart --interval x >"$tmp/out" 2>"$tmp/stderr"
eq "restart --interval x exits 1" 1 $?
if kill -0 "$wpid" 2>/dev/null; then ok "restart, bad values: old watcher still alive"; else ko "restart, bad values: old watcher still alive"; fi
eq "restart, bad values: no kill-session, no new-session" "" "$(grep -E 'kill-session|new-session' "$FAKE_TMUX_LOG")"
"$watch" restart --max-parallel 3 >"$tmp/out" 2>"$tmp/stderr"
eq "restart --max-parallel 3 exits 0" 0 $?
wait "$wpid"
has "restart --max-parallel 3: kept --interval, new cap" "$FAKE_TMUX_LOG" "--interval 1000 --max-parallel 3"
lacks "restart --max-parallel 3: old cap gone" "$FAKE_TMUX_LOG" "--max-parallel 2"
has "restart --max-parallel 3: new watcher line" "$tmp/out" "flags: --interval 1000 --max-parallel 3, parallel: 3"
cp "$tmp/out" "$tmp/restartflags.out"
: >"$FAKE_TMUX_LOG"
wpid=$(cat "$wfile")
"$watch" restart --force --max-parallel 4 >"$tmp/out" 2>"$tmp/stderr"
eq "restart --force --max-parallel 4 exits 0" 0 $?
gone "$wpid"
has "restart --force first: replaced" "$FAKE_TMUX_LOG" "--interval 1000 --max-parallel 4"
: >"$FAKE_TMUX_LOG"
wpid=$(cat "$wfile")
"$watch" restart --max-parallel 5 --force >"$tmp/out" 2>"$tmp/stderr"
eq "restart --max-parallel 5 --force exits 0" 0 $?
gone "$wpid"
has "restart --force last: replaced" "$FAKE_TMUX_LOG" "--interval 1000 --max-parallel 5"
wpid=$(cat "$wfile")
"$watch" stop >/dev/null 2>&1
eq "stop after the restarts exits 0" 0 $?
gone "$wpid"
rm -f "$wfile" "$ffile"

# --- logs ------------------------------------------------------------------

rm -f "$log"
out=$("$watch" logs); eq "logs: no log yet" "no log yet" "$out"
"$watch" logs >/dev/null
eq "logs: no log yet exits 0" 0 $?
for i in $(seq 1 25); do
  printf '2026-10-29T10:%02d:00+0000\t%s/aat\tdocs/plans/x.prompt-%d.md\tsonnet\t0\t5\tauto\n' "$i" "$tmp" "$i" >>"$log"
done
printf '2026-10-29T11:00:00+0000\twaiting\t%s/other\tdocs/plans/y.prompt-1.md\tafter=dep\n' "$tmp" >>"$log"
eq_log "logs: default is 20 lines" 20 "$("$watch" logs | wc -l | tr -d ' ')"
eq_log "logs: -n 2" 2 "$("$watch" logs -n 2 | wc -l | tr -d ' ')"
eq "logs: lines as stored" "$(tail -n 1 "$log")" "$("$watch" logs -n 1)"
eq_log "logs: bare name filters" 25 "$("$watch" logs -n 100 aat | wc -l | tr -d ' ')"
eq_log "logs: filter matches waiting lines" 1 "$("$watch" logs -n 100 other | wc -l | tr -d ' ')"
eq "logs: filter then last N" "$(grep aat "$log" | tail -n 3)" "$("$watch" logs -n 3 aat)"

# --- tail ------------------------------------------------------------------

# Line shapes copied from a real transcript (one content block per record).
tdir=$HOME/.claude/projects/${ws//\//-}
mkdir -p "$tdir"
tf=$tdir/11111111-2222-3333-4444-555555555555.jsonl
cat >"$tf" <<'JSONL'
{"type":"queue-operation","operation":"enqueue","sessionId":"s","timestamp":"2026-10-29T00:32:30.000Z"}
{"parentUuid":"a","isSidechain":false,"message":{"model":"m","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Dependency met.\n  Claim   and proceed."}],"stop_reason":"end_turn"},"type":"assistant","uuid":"u1","timestamp":"2026-10-29T00:32:40.566Z"}
{"parentUuid":"b","isSidechain":false,"message":{"model":"m","id":"msg_2","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"cat docs/plans/x.md;\ngit status"},"caller":{"type":"direct"}}],"stop_reason":"tool_use"},"type":"assistant","uuid":"u2","timestamp":"2026-10-29T00:32:41.100Z"}
{"parentUuid":"c","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"secret output"}]},"uuid":"u3","timestamp":"2026-10-29T00:32:42.773Z"}
{"parentUuid":"d","isSidechain":false,"message":{"model":"m","id":"msg_3","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"abc"}]},"type":"assistant","uuid":"u4","timestamp":"2026-10-29T00:32:43.000Z"}
{"parentUuid":"e","isSidechain":false,"message":{"model":"m","id":"msg_4","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Read","input":{"file_path":"/tmp/ws/docs/plans/x.md"}}]},"type":"assistant","uuid":"u5","timestamp":"2026-10-29T00:32:44.200Z"}
{"type":"user","message":{"role":"user","content":"a user turn"},"uuid":"u6","timestamp":"2026-10-29T00:32:45.000Z"}
{"this is not json
{"parentUuid":"f","isSidechain":false,"message":{"model":"m","id":"msg_5","type":"message","role":"assistant","content":[{"type":"text","text":"Done."}]},"type":"assistant","uuid":"u7","timestamp":"2026-10-29T00:32:46.000Z"}
JSONL
expect_tail="00:32:40  assistant  Dependency met. Claim and proceed.
00:32:41  tool       Bash  cat docs/plans/x.md; git status
00:32:44  tool       Read  /tmp/ws/docs/plans/x.md
00:32:46  assistant  Done."

"$watch" tail >"$tmp/out" 2>"$tmp/stderr"
eq "tail: no run in progress exits 1" 1 $?
has "tail: says so" "$tmp/stderr" "no run in progress"

"$rp" set "$pf" status pending
env FAKE_MODE=sleep "$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
touch "$tf"
eq "tail: transcript turns" "$expect_tail" "$("$watch" tail)"
eq "tail: by bare name" "$expect_tail" "$("$watch" tail ops)"
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  eq "tail: python3 path gives the same lines" "$expect_tail" "$(CHIRAT_TAIL_PY=1 "$watch" tail)"
else
  echo "skip tail: python3 path (needs both jq and python3)"
fi
touch -t 200001010000 "$tf"
eq "tail: transcript older than the run" "no transcript yet" "$("$watch" tail)"
"$watch" tail >/dev/null
eq "tail: no transcript yet exits 0" 0 $?
rm -f "$tf"
eq "tail: no transcript at all" "no transcript yet" "$("$watch" tail)"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
"$rp" set "$pf" status pending

# --- doctor ----------------------------------------------------------------

# A fake claude that knows `--version` and `plugin list`; the run-time one above
# is put back afterwards.
mv "$tmp/bin/claude" "$tmp/bin/claude.run"
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
case $1 in
  --version) echo "9.9.9 (Claude Code)" ;;
  plugin) echo "${FAKE_PLUGINS-chirat@chirat 0.1.0}" ;;
  -p) [ -z "${FAKE_LOGIN:-}" ] || { echo "Not logged in" >&2; exit 1; }; echo '{"result":"ok"}' ;;
esac
EOF
chmod +x "$tmp/bin/claude"
mkdir -p "$tmp/inst"
"$watch" install "$tmp/inst" >/dev/null
dpath=$tmp/inst:$tmp/bin:/usr/bin:/bin
doc() { PATH=$dpath "$watch" doctor "$@" >"$tmp/doc.out" 2>&1; return $?; }
printf '%s\n' "$ws" >"$XDG_CONFIG_HOME/chirat/workspaces"
# the registered workspace must be green too: doctor without ws exits 1 on its FAIL
git init -q -b main "$ws"
git config -f "$ws/.gitconfig" user.email ws@example.com
git config -f "$tmp/.gitconfig" "includeIf.gitdir:$(cd -P "$ws" && pwd -P)/.path" "$ws/.gitconfig"
doc
eq "doctor: all good exits 0" 0 $?
has "doctor: claude" "$tmp/doc.out" "ok   claude: "
has "doctor: plugin" "$tmp/doc.out" "ok   plugin: chirat installed"
has "doctor: workspace" "$tmp/doc.out" "ok   workspace $ws"
has "doctor: chirat-prompt" "$tmp/doc.out" "ok   chirat-prompt: $tmp/inst/chirat-prompt"
has "doctor: chirat-init" "$tmp/doc.out" "ok   chirat-init: $tmp/inst/chirat-init"
has "doctor: state dir" "$tmp/doc.out" "ok   state dir: "
has "doctor: watcher line" "$tmp/doc.out" "ok   watcher: not running"
has "doctor: osascript warn" "$tmp/doc.out" 'warn notifications via osascript'
mkdir -p "$tmp/dtn"
cat >"$tmp/dtn/terminal-notifier" <<'EOF2'
#!/bin/sh
if [ "$1" = -version ]; then [ -z "$FAKE_TNV" ] || echo "$FAKE_TNV"; exit 0; fi
[ -z "$FAKE_TNERR" ] || echo "$FAKE_TNERR" >&2
exit 0
EOF2
chmod +x "$tmp/dtn/terminal-notifier"
FAKE_TNV="terminal-notifier 3.1.0." PATH=$tmp/dtn:$dpath "$watch" doctor >"$tmp/doc2.out" 2>&1
has "doctor: terminal-notifier 3 ok" "$tmp/doc2.out" "ok   terminal-notifier 3.x (click opens each workspace's notify_open)"
FAKE_TNV=3.1.0 PATH=$tmp/dtn:$dpath "$watch" doctor >"$tmp/doc2.out" 2>&1
has "doctor: terminal-notifier bare 3 ok" "$tmp/doc2.out" "ok   terminal-notifier 3.x (click opens each workspace's notify_open)"
FAKE_TNV="terminal-notifier 2.0.0." PATH=$tmp/dtn:$dpath "$watch" doctor >"$tmp/doc2.out" 2>&1
has "doctor: terminal-notifier 2 warns" "$tmp/doc2.out" "warn terminal-notifier 2.0.0: 3.x needed for -open; brew upgrade terminal-notifier"
PATH=$tmp/dtn:$dpath "$watch" doctor >"$tmp/doc2.out" 2>&1
has "doctor: terminal-notifier unknown version warns" "$tmp/doc2.out" "warn terminal-notifier ?: 3.x needed"
FAKE_TNV=3.1.0 FAKE_TNERR="Notifications are not allowed for this application" PATH=$tmp/dtn:$dpath "$watch" doctor --online >"$tmp/doc2.out" 2>&1
has "doctor --online: permission FAIL" "$tmp/doc2.out" "FAIL terminal-notifier: notifications not allowed — run: open "
has "doctor --online: permission FAIL asks for Allow" "$tmp/doc2.out" "once and click Allow"
FAKE_TNV=3.1.0 PATH=$tmp/dtn:$dpath "$watch" doctor --online >"$tmp/doc2.out" 2>&1
has "doctor --online: permission ok" "$tmp/doc2.out" "ok   terminal-notifier: permission granted"
FAKE_TNV=3.1.0 PATH=$tmp/dtn:$dpath "$watch" doctor >"$tmp/doc2.out" 2>&1
if grep -q 'permission' "$tmp/doc2.out"; then ko "doctor without --online: no probe"; else ok "doctor without --online: no probe"; fi
printf 'notify_open=nonsense\n' >"$ws/.chirat/config"
PATH=$tmp/dtn:$dpath "$watch" doctor >"$tmp/doc2.out" 2>&1
has "doctor: notify_open unrecognized" "$tmp/doc2.out" "warn notify_open: unrecognized value nonsense"
printf 'notify_open=claude://claude.ai/project/x\n' >"$ws/.chirat/config"
CHIRAT_NOTIFY=0 "$watch" status "$ws" >"$tmp/st.out" 2>&1
has "status: notify line" "$tmp/st.out" "  notify: CHIRAT_NOTIFY=0 CHIRAT_NOTIFY_OPEN=0 notify_open=claude://claude.ai/project/x"
rm -f "$ws/.chirat/config"
mkdir -p "$tmp/tnapp/terminal-notifier.app/Contents/MacOS" "$tmp/tnbin"
cp "$tmp/dtn/terminal-notifier" "$tmp/tnapp/terminal-notifier.app/Contents/MacOS/terminal-notifier"
ln -sf "$tmp/tnapp/terminal-notifier.app/Contents/MacOS/terminal-notifier" "$tmp/tnbin/terminal-notifier"
FAKE_TNV=3.1.0 FAKE_TNERR="Notifications are not allowed for this application" PATH=$tmp/tnbin:$dpath "$watch" doctor --online >"$tmp/doc2.out" 2>&1
has "doctor: permission FAIL names the .app bundle" "$tmp/doc2.out" "open \"$tmp/tnapp/terminal-notifier.app\" once"
rm -f "$ws/.chirat/config"
if grep -q '^FAIL' "$tmp/doc.out"; then ko "doctor: no FAIL lines" "$(cat "$tmp/doc.out")"; else ok "doctor: no FAIL lines"; fi
FAKE_PLUGINS="other@x 1.0" doc
eq "doctor: plugin missing exits 1" 1 $?
has "doctor: plugin FAIL" "$tmp/doc.out" "FAIL plugin: chirat not in"
printf '%s\n%s\n' "$ws" "$tmp/nowhere" >"$XDG_CONFIG_HOME/chirat/workspaces"
doc
eq "doctor: bad workspace exits 1" 1 $?
has "doctor: bad workspace FAIL" "$tmp/doc.out" "FAIL workspace $tmp/nowhere: no such directory"
: >"$XDG_CONFIG_HOME/chirat/workspaces"
doc
eq "doctor: no workspaces is a warn" 0 $?
has "doctor: warn no workspaces" "$tmp/doc.out" "warn no workspaces"
printf '%s\n' "$ws" >"$XDG_CONFIG_HOME/chirat/workspaces"
PATH=$tmp/bin:/usr/bin:/bin "$watch" doctor >"$tmp/doc.out" 2>&1
eq "doctor: chirat-prompt off PATH exits 1" 1 $?
has "doctor: install hint" "$tmp/doc.out" "FAIL chirat-prompt: not on PATH: run \`$watch install\`"
has "doctor: PATH export" "$tmp/doc.out" "export PATH="
mv "$tmp/inst/chirat-init" "$tmp/chirat-init.link"
doc
eq "doctor: chirat-init off PATH exits 0" 0 $?
has "doctor: chirat-init off PATH warns with the fix" "$tmp/doc.out" "warn chirat-init: not on PATH: run \`$watch install\`"
mv "$tmp/chirat-init.link" "$tmp/inst/chirat-init"
mkdir -p "$tmp/elsewhere"
printf '#!/bin/sh\n' >"$tmp/elsewhere/chirat-prompt"; chmod +x "$tmp/elsewhere/chirat-prompt"
PATH=$tmp/elsewhere:$dpath "$watch" doctor >"$tmp/doc.out" 2>&1
eq "doctor: other chirat-prompt only warns" 0 $?
has "doctor: warn names both paths" "$tmp/doc.out" "warn chirat-prompt: resolves to $tmp/elsewhere/chirat-prompt, this checkout has $rp"
XDG_CONFIG_HOME=$tmp/nowhere doc
eq "doctor: no config exits 1" 1 $?
has "doctor: config FAIL" "$tmp/doc.out" "FAIL config: "
doc --online
eq "doctor --online ok" 0 $?
has "doctor --online line" "$tmp/doc.out" "ok   claude -p: answered"
FAKE_LOGIN=1 doc --online
eq "doctor --online login expired exits 1" 1 $?
has "doctor --online first stderr line" "$tmp/doc.out" "FAIL claude -p: exit 1: Not logged in"

# --- doctor <ws> -----------------------------------------------------------

# Its own HOME with a real ~/.gitconfig and ~/.config/chirat/workspaces; an empty
# XDG_CONFIG_HOME falls back to ~/.config, for chirat-watch and for git alike.
dh=$(cd -P "$tmp" && pwd -P)/dochome
dws=$dh/code/dw
mkdir -p "$dws/.chirat" "$dws/docs/plans" "$dws/repos" "$dh/.config/chirat"
git init -q -b main "$dws"
git config -f "$dws/.gitconfig" user.name "Doc Tor"
git config -f "$dws/.gitconfig" user.email doc@example.com
printf 'notify_open=claude://claude.ai/project/x\n' >"$dws/.chirat/config"
git init -q -b main "$tmp/docsrc"
git -C "$tmp/docsrc" -c user.name=T -c user.email=t@example.com commit -q --allow-empty -m init
git clone -q "$tmp/docsrc" "$dws/repos/app"
printf '%s\n' "$dws" >"$dh/.config/chirat/workspaces"
dgit() { HOME=$dh XDG_CONFIG_HOME="" git "$@"; }
dinclude() { # dinclude <gitdir pattern> <path>: ~/.gitconfig holds just this include
  rm -f "$dh/.gitconfig"
  dgit config --global --add "includeIf.gitdir:$1.path" "$2"
}
dd() { HOME=$dh XDG_CONFIG_HOME="" PATH=$dpath "$watch" doctor "$@" >"$tmp/dd.out" 2>&1; return $?; }
fixline="git config --global --add includeIf.\"gitdir:$dws/\".path \"$dws/.gitconfig\""

dinclude "$dws/" "$dws/.gitconfig"
dd "$dws"
eq "doctor ws: all green exits 0" 0 $?
has "doctor ws: machine checks run too" "$tmp/dd.out" "ok   claude: "
has "doctor ws: includeIf ok" "$tmp/dd.out" "ok   includeIf: gitdir:$dws/"
has "doctor ws: identity ok" "$tmp/dd.out" "ok   identity: doc@example.com"
has "doctor ws: workspaces ok" "$tmp/dd.out" "ok   workspaces: registered in"
has "doctor ws: repos ok" "$tmp/dd.out" "ok   repos: app"
has "doctor ws: default_branch ok" "$tmp/dd.out" "ok   default_branch: main"
has "doctor ws: notify_open ok" "$tmp/dd.out" "ok   notify_open: claude://claude.ai/project/x"
if grep -q '^FAIL\|^warn [a-z_]*:.*dw' "$tmp/dd.out"; then ko "doctor ws: no FAIL, no warn about it" "$(cat "$tmp/dd.out")"; else ok "doctor ws: no FAIL, no warn about it"; fi
# shellcheck disable=SC2088 # the literal ~ is the test
dd "~/code/dw"
eq "doctor ws: ~ allowed" 0 $?
dd --online "$dws/"
eq "doctor ws: --online and a trailing / " 0 $?

rm -f "$dh/.gitconfig"
dd "$dws"
eq "doctor ws: no includeIf exits 1" 1 $?
has "doctor ws: no includeIf FAIL" "$tmp/dd.out" "FAIL includeIf: no includeIf for it"
has "doctor ws: the fix line" "$tmp/dd.out" "$fixline"
has "doctor ws: identity FAIL without the include" "$tmp/dd.out" "FAIL identity: "
(HOME=$dh XDG_CONFIG_HOME="" eval "$(grep 'git config --global --add' "$tmp/dd.out")")
dd "$dws"
eq "doctor ws: the printed fix line works" 0 $?

dinclude "$dws" "$dws/.gitconfig"
dd "$dws"
eq "doctor ws: no trailing / exits 1" 1 $?
has "doctor ws: no trailing / FAIL" "$tmp/dd.out" "has no trailing /"

dinclude "$dws/" "$dh/other.gitconfig"
dd "$dws"
eq "doctor ws: wrong path exits 1" 1 $?
has "doctor ws: wrong path FAIL" "$tmp/dd.out" "has path = $dh/other.gitconfig"

printf '[includeIf "gitdir:%s/"]\n  path = %s/.gitconfig\n' "$dws" "$dws" >"$dh/extra.gitconfig"
rm -f "$dh/.gitconfig"
dgit config --global include.path "$dh/extra.gitconfig"
dd "$dws"
eq "doctor ws: include in an included file exits 0" 0 $?
has "doctor ws: include in an included file ok" "$tmp/dd.out" "ok   includeIf: gitdir:$dws/"

ln -s "$dws" "$dh/dwlink"
dinclude "$dh/dwlink/" "$dws/.gitconfig"
dd "$dws"
has "doctor ws: symlink resolved for the comparison" "$tmp/dd.out" "ok   includeIf: gitdir:$dws/"
has "doctor ws: identity shows git does not follow it" "$tmp/dd.out" "FAIL identity: "
# shellcheck disable=SC2088 # the literal ~ is the test
dinclude "~/code/dw/" "~/code/dw/.gitconfig"
dd "$dws"
eq "doctor ws: ~ in the include resolved" 0 $?

dinclude "$dws/" "$dws/.gitconfig"
: >"$dh/.config/chirat/workspaces"
dd "$dws"
eq "doctor ws: missing workspaces line exits 1" 1 $?
has "doctor ws: workspaces FAIL" "$tmp/dd.out" "FAIL workspaces: not in"
has "doctor ws: workspaces fix line" "$tmp/dd.out" "mkdir -p \"$dh/.config/chirat\" && echo \"$dws\" >> \"$dh/.config/chirat/workspaces\""
printf '%s\n' "$dh/dwlink" >"$dh/.config/chirat/workspaces"
dd "$dws"
has "doctor ws: workspaces compared resolved" "$tmp/dd.out" "ok   workspaces: registered"
printf '%s\n' "$dws" >"$dh/.config/chirat/workspaces"

mv "$dws/repos/app" "$tmp/docapp"
dd "$dws"
eq "doctor ws: no clone exits 0" 0 $?
has "doctor ws: no clone warn" "$tmp/dd.out" "warn repos: no clone"
mv "$tmp/docapp" "$dws/repos/app"

printf 'default_branch=mobile\nnotify_open=claude://claude.ai/project/x\n' >"$dws/.chirat/config"
dd "$dws"
eq "doctor ws: default_branch missing exits 0" 0 $?
has "doctor ws: default_branch warn names the current branch" "$tmp/dd.out" "warn default_branch: no local branch mobile in repos/app, which is on main"
printf '# notify_open=claude://claude.ai/project/<uuid>\n' >"$dws/.chirat/config"
dd "$dws"
eq "doctor ws: notify_open commented exits 0" 0 $?
has "doctor ws: notify_open unset warn" "$tmp/dd.out" "warn notify_open: not set"
printf 'notify_open=claude://claude.ai/project/<uuid>\n' >"$dws/.chirat/config"
dd "$dws"
has "doctor ws: notify_open placeholder warn" "$tmp/dd.out" "warn notify_open: placeholder left"
printf 'notify_open=claude://claude.ai/project/x\n' >"$dws/.chirat/config"

# W2: default_branch per repository
dcfg() { printf '%s\n' "$@" 'notify_open=claude://claude.ai/project/x' >"$dws/.chirat/config"; }
line() { # line <name> <whole line of the output>
  if grep -qxF -- "$2" "$tmp/dd.out"; then ok "$1"; else ko "$1" "no line [$2] in: $(cat "$tmp/dd.out")"; fi
}
no_line() { # no_line <name> <regex>
  if grep -q -- "$2" "$tmp/dd.out"; then ko "$1" "$(grep -- "$2" "$tmp/dd.out")"; else ok "$1"; fi
}
dmiss() { # dmiss <branch> <clone> <current> <key>: the missing-branch line
  echo "warn default_branch: no local branch $1 in repos/$2, which is on $3: set $4=$3 in $dws/.chirat/config"
}
git -C "$dws/repos/app" branch -q -m main dev
dcfg '# no key'
dd "$dws"
line "W2: one clone: the workspace key is the hint" "$(dmiss main app dev default_branch)"
git -C "$dws/repos/app" worktree add -q "$dws/repos/app-fix" -b fix
dd "$dws"
line "W2: one clone and a linked worktree: same hint" "$(dmiss main app dev default_branch)"
no_line "W2: a linked worktree is skipped" '^warn default_branch.*app-fix'
dcfg default_branch.app=trunk
dd "$dws"
line "W2: one clone with a key of its own: that key is the hint" "$(dmiss trunk app dev default_branch.app)"
git clone -q "$tmp/docsrc" "$dws/repos/lib"
dcfg '# no key'
dd "$dws"
eq "W2: two clones, a missing branch exits 0" 0 $?
line "W2: two clones: the per-repo hint" "$(dmiss main app dev default_branch.app)"
no_line "W2: two clones: the other one is fine" '^warn default_branch.*repos/lib'
no_line "W2: no ok line after a warn" '^ok   default_branch'
dcfg default_branch.app=dev
dd "$dws"
eq "W2: the hint applied exits 0" 0 $?
line "W2: the mixed ok line" "ok   default_branch: main (app: dev)"
no_line "W2: no warn with the key set, worktree included" '^warn default_branch'
git clone -q "$tmp/docsrc" "$dws/repos/app-x"
git -C "$dws/repos/app-x" branch -q -m main next
dcfg default_branch.app-x=next default_branch.app=dev
dd "$dws"
line "W2: three clones, the differing ones in byte order" "ok   default_branch: main (app: dev, app-x: next)"
dcfg default_branch.app-x=next default_branch.app=dev default_branch.ap=dev \
  default_branch.my-app.v2=dev default_branch.empty= default_branch.app-fix=fix
dd "$dws"
eq "W2: an orphan key exits 0" 0 $?
line "W2: an orphan key" "warn default_branch.ap: no clone repos/ap"
line "W2: an orphan key with a dotted name" "warn default_branch.my-app.v2: no clone repos/my-app.v2"
line "W2: a worktree's name is an orphan key" "warn default_branch.app-fix: no clone repos/app-fix"
no_line "W2: an empty value gets no warning" '^warn default_branch\.empty'
line "W2: an orphan key leaves the ok line" "ok   default_branch: main (app: dev, app-x: next)"
git -C "$dws/repos/app-x" branch -q -m next dev
rm -rf "$dws/repos/lib"
dcfg default_branch.app=dev default_branch.app-x=dev
dd "$dws"
line "W2: every clone on the same branch" "ok   default_branch: dev"
rm -rf "$dws/repos/app-x"
git -C "$dws/repos/app" worktree remove "$dws/repos/app-fix"
git -C "$dws/repos/app" branch -q -m dev main
mv "$dws/repos/app" "$tmp/docapp"
dcfg default_branch.app=dev
dd "$dws"
line "W2: an orphan key without any clone" "warn default_branch.app: no clone repos/app"
mv "$tmp/docapp" "$dws/repos/app"
dcfg '# no key'

mkdir -p "$dh/plain"
dd "$dh/plain"
eq "doctor ws: not a workspace exits 1" 1 $?
has "doctor ws: not a workspace FAIL" "$tmp/dd.out" "not a workspace (no .chirat/)"
dd "$dh/nowhere"
eq "doctor ws: no such path exits 1" 1 $?
has "doctor ws: no such path FAIL" "$tmp/dd.out" "no such directory"
dd "$dws" extra
eq "doctor: two paths is a usage error" 64 $?

# a bare name: the registered workspace, unless a folder of that name is here
dd_in() { # dd_in <cwd> <arg>: dd from that directory
  (cd "$1" && HOME=$dh XDG_CONFIG_HOME="" PATH=$dpath "$watch" doctor "$2") >"$tmp/dd.out" 2>&1
}
mkdir -p "$dh/empty" "$dh/folder/dw"
dd_in "$dh/empty" "$dws"
cp "$tmp/dd.out" "$tmp/dd.path"
dd_in "$dh/empty" dw
eq "doctor name: exits 0" 0 $?
eq "doctor name: same output as the full path" "$(cat "$tmp/dd.path")" "$(cat "$tmp/dd.out")"
dd_in "$dws/repos" dw
eq "doctor name: from inside the workspace too" "$(cat "$tmp/dd.path")" "$(cat "$tmp/dd.out")"
dd_in "$dh/folder" dw
eq "doctor name: a folder here wins, exit 1" 1 $?
has "doctor name: a folder here wins" "$tmp/dd.out" "FAIL workspace $dh/folder/dw: not a workspace (no .chirat/)"
dd_in "$dh/code" dw
eq "doctor name: the workspace folder itself, relative" 0 $?
dd_in "$dh/empty" nope
eq "doctor name: unknown exits 1" 1 $?
eq "doctor name: unknown is one FAIL" "FAIL workspace nope: no registered workspace with that name in $dh/.config/chirat/workspaces, and no such directory here; pass a path" "$(grep '^FAIL' "$tmp/dd.out")"
has "doctor name: unknown, the machine checks run" "$tmp/dd.out" "ok   claude: "
if grep -qF "$dh/empty" "$tmp/dd.out"; then ko "doctor name: unknown, no path under cwd" "$(cat "$tmp/dd.out")"; else ok "doctor name: unknown, no path under cwd"; fi
dd_in "$dh/empty" nope/dw
eq "doctor name: a path that is not there exits 1" 1 $?
has "doctor name: a path with / is never a name" "$tmp/dd.out" "FAIL workspace nope/dw: no such directory"
mkdir -p "$dh/other/dw/.chirat"
printf '%s\n%s\n' "$dws" "$dh/other/dw" >"$dh/.config/chirat/workspaces"
dd_in "$dh/empty" dw
eq "doctor name: ambiguous exits 1" 1 $?
eq "doctor name: ambiguous is one FAIL naming both" "FAIL workspace dw: several registered workspaces with that name: $dws, $dh/other/dw; pass a path" "$(grep '^FAIL' "$tmp/dd.out")"
if grep -q '^ok   workspace\|includeIf' "$tmp/dd.out"; then ko "doctor name: ambiguous, no workspace checks" "$(cat "$tmp/dd.out")"; else ok "doctor name: ambiguous, no workspace checks"; fi
mv "$dh/.config/chirat/workspaces" "$dh/workspaces.away"
dd_in "$dh/empty" dw
eq "doctor name: no config exits 1" 1 $?
has "doctor name: no config, nothing registered" "$tmp/dd.out" "FAIL workspace dw: no registered workspace with that name"
mv "$dh/workspaces.away" "$dh/.config/chirat/workspaces"
# a path listed twice is one workspace, not an ambiguous name
printf '%s\n%s/\n' "$dws" "$dws" >"$dh/.config/chirat/workspaces"
dd_in "$dh/empty" dw
eq "doctor name: listed twice exits 0" 0 $?
eq "doctor name: listed twice, one workspace line" 1 "$(grep -c "^ok   workspace $dws" "$tmp/dd.out")"
dd
eq "doctor: listed twice, one summary line" 1 "$(grep -c '^dw: ' "$tmp/dd.out")"
printf '%s\n' "$dws" >"$dh/.config/chirat/workspaces"

# without an argument: one line per registered workspace, exit as before
dws2=$dh/code/mvg
mkdir -p "$dws2/.chirat" "$dws2/docs/plans" "$dws2/repos"
git init -q -b main "$dws2"
git config -f "$dws2/.gitconfig" user.email mvg@example.com
printf '%s\n%s\n' "$dws" "$dws2" >"$dh/.config/chirat/workspaces"
dd
eq "doctor: a workspace FAIL exits 1" 1 $?
has "doctor: a green workspace in one line" "$tmp/dd.out" "dw: ok"
has "doctor: a failing workspace in one line" "$tmp/dd.out" "mvg: includeIf FAIL, identity FAIL"
eq "doctor: one line each" 2 "$(grep -cE '^(dw|mvg): ' "$tmp/dd.out")"
if grep -q 'git config --global' "$tmp/dd.out"; then ko "doctor: no fix lines in the summary"; else ok "doctor: no fix lines in the summary"; fi
dd --online
eq "doctor --online: a workspace FAIL exits 1" 1 $?
has "doctor --online: the summary names the failing workspace" "$tmp/dd.out" "mvg: includeIf FAIL, identity FAIL"

# all registered workspaces green -> 0; a warn alone -> 0
printf '%s\n' "$dws" >"$dh/.config/chirat/workspaces"
dd
eq "doctor: all workspaces green exits 0" 0 $?
has "doctor: green summary line" "$tmp/dd.out" "dw: ok"
mv "$dws/repos/app" "$tmp/docapp"
dd
eq "doctor: a workspace with only a warn exits 0" 0 $?
has "doctor: warn-only workspace is ok in the summary" "$tmp/dd.out" "dw: ok"
mv "$tmp/docapp" "$dws/repos/app"
printf '%s\n%s\n' "$dws" "$dws2" >"$dh/.config/chirat/workspaces"

# --- doctor: identity by origin, quieter doctor <ws> ------------------------

printf '%s\n' "$dws" >"$dh/.config/chirat/workspaces"
if grep -q 'claude://' <(FAKE_TNV=3.1.0 PATH=$tmp/dtn:$dpath "$watch" doctor | grep 'terminal-notifier 3.x'); then ko "doctor: terminal-notifier line names no project"; else ok "doctor: terminal-notifier line names no project"; fi

# the regression: the same address globally, no includeIf
rm -f "$dh/.gitconfig"
dgit config --global user.email doc@example.com
dgit config --global user.name "Doc Tor"
dd "$dws"
eq "doctor ws: same global email, no include exits 1" 1 $?
has "doctor ws: same global email FAIL identity" "$tmp/dd.out" "FAIL identity: user.email in $dws comes from $dh/.gitconfig, not $dws/.gitconfig"
has "doctor ws: ... and the clone" "$tmp/dd.out" "user.email in $dws/repos/app comes from $dh/.gitconfig"
has "doctor ws: ... and user.name" "$tmp/dd.out" "user.name in $dws comes from $dh/.gitconfig"

# include in place -> ok; also through an included file
rm -f "$dh/.gitconfig"
dgit config --global user.email doc@example.com
dgit config --global --add "includeIf.gitdir:$dws/.path" "$dws/.gitconfig"
dd "$dws"
eq "doctor ws: global email plus include exits 0" 0 $?
has "doctor ws: identity ok with the include" "$tmp/dd.out" "ok   identity: doc@example.com"
rm -f "$dh/.gitconfig"
dgit config --global user.email doc@example.com
dgit config --global include.path "$dh/extra.gitconfig"
dd "$dws"
eq "doctor ws: include inside an included file, global email exits 0" 0 $?
has "doctor ws: identity ok via included file" "$tmp/dd.out" "ok   identity: doc@example.com"

# user.name from the wrong origin: the include comes first, a later global wins
dinclude "$dws/" "$dws/.gitconfig"
dgit config --global user.name "Other Name"
dd "$dws"
eq "doctor ws: user.name from the global file exits 1" 1 $?
has "doctor ws: user.name FAIL" "$tmp/dd.out" "FAIL identity: user.name in $dws comes from $dh/.gitconfig"

# core.sshCommand
git config -f "$dws/.gitconfig" core.sshCommand "ssh -i '$dh/.ssh/id_work' -o IdentitiesOnly=yes"
rm -f "$dh/.gitconfig"
dgit config --global user.email doc@example.com
dgit config --global user.name "Doc Tor"
dd "$dws"
eq "doctor ws: sshCommand without include exits 1" 1 $?
has "doctor ws: sshCommand FAIL" "$tmp/dd.out" "core.sshCommand in $dws is not set"
dinclude "$dws/" "$dws/.gitconfig"
dd "$dws"
eq "doctor ws: sshCommand with include exits 0" 0 $?
has "doctor ws: ok names the key" "$tmp/dd.out" "ok   identity: doc@example.com, ssh key $dh/.ssh/id_work"
dgit config --global core.sshCommand "ssh -i /elsewhere"
dd "$dws"
eq "doctor ws: sshCommand from the global file exits 1" 1 $?
has "doctor ws: sshCommand origin FAIL" "$tmp/dd.out" "core.sshCommand in $dws comes from $dh/.gitconfig"
git config -f "$dws/.gitconfig" --unset core.sshCommand
dinclude "$dws/" "$dws/.gitconfig"
dd "$dws"
if grep 'identity' "$tmp/dd.out" | grep -qi 'ssh'; then ko "doctor ws: no ssh text without core.sshCommand"; else ok "doctor ws: no ssh text without core.sshCommand"; fi

# the first clone is checked as well: a repo-local identity beats the include
git -C "$dws/repos/app" config user.email local@example.com
dd "$dws"
eq "doctor ws: clone with its own email exits 1" 1 $?
has "doctor ws: clone FAIL" "$tmp/dd.out" "user.email in $dws/repos/app comes from .git/config"
git -C "$dws/repos/app" config --unset user.email

# doctor <ws> lists only that workspace in the machine part
printf '%s\n%s\n' "$dws" "$dws2" >"$dh/.config/chirat/workspaces"
dd "$dws"
if grep -q "ok   workspace $dws2" "$tmp/dd.out"; then ko "doctor ws: no other workspace line"; else ok "doctor ws: no other workspace line"; fi
has "doctor ws: the asked workspace line" "$tmp/dd.out" "ok   workspace $dws"
dd
has "doctor: without ws every workspace line" "$tmp/dd.out" "ok   workspace $dws2"

# a registered path that is not a workspace, or vanished: FAIL, exit 1
mkdir -p "$dh/notws"
printf '%s\n%s\n' "$dws" "$dh/notws" >"$dh/.config/chirat/workspaces"
dd
eq "doctor: registered non-workspace exits 1" 1 $?
has "doctor: non-workspace summary FAIL" "$tmp/dd.out" "notws: FAIL not a workspace (no .chirat/)"
printf '%s\n%s\n' "$dws" "$dh/vanished" >"$dh/.config/chirat/workspaces"
dd
eq "doctor: vanished path exits 1" 1 $?
has "doctor: vanished summary FAIL" "$tmp/dd.out" "vanished: FAIL no such directory"
printf '%s\n%s\n' "$dws" "$dws2" >"$dh/.config/chirat/workspaces"

mv "$tmp/bin/claude.run" "$tmp/bin/claude"

# --once leaves nothing behind
"$watch" --once >/dev/null 2>&1
absent "--once leaves no watcher.pid" "$XDG_STATE_HOME/chirat/watcher.pid"
ws=$tmp/ws

# --- notification text, CHIRAT_NOTIFY_OPEN, status next: -------------------------

cat >"$tmp/bin/open" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_OPEN"
EOF
chmod +x "$tmp/bin/open"
export FAKE_OPEN=$tmp/open
ws=$tmp/nt
mkdir -p "$ws"/docs/{plans,status} "$ws"/repos
printf '%s\n' "$ws" >"$XDG_CONFIG_HOME/chirat/workspaces"
git init -q -b main "$ws/repos/demo"
git -C "$ws/repos/demo" commit -q --allow-empty -m init
nprompt() { prompt "$@"; "$rp" set "$ws/docs/plans/$1" branch "${4:-feat/x}"; }
sf=$ws/docs/status/2026-10-29-demo.prompt-1.md

nprompt demo.prompt-1.md sonnet pending
FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
has "notify done: names the status file and branch" "$FAKE_OSA" "demo.prompt-1 done → review docs/status/2026-10-29-demo.prompt-1.md, merge feat/x"
has "notify done: subtitle is the workspace" "$FAKE_OSA" 'subtitle "nt"'
absent "CHIRAT_NOTIFY_OPEN unset does not open" "$FAKE_OPEN"
rm -f "$FAKE_OSA"

nprompt demo.prompt-1.md sonnet pending
FAKE_SF=$sf CHIRAT_NOTIFY_OPEN=1 "$watch" --once >/dev/null 2>&1
eq "CHIRAT_NOTIFY_OPEN=1 opens the status file" "$sf" "$(cat "$FAKE_OPEN")"
rm -f "$FAKE_OPEN" "$FAKE_OSA"

nprompt demo.prompt-1.md sonnet pending
FAKE_SF=$sf CHIRAT_NOTIFY_OPEN=0 "$watch" --once >/dev/null 2>&1
absent "CHIRAT_NOTIFY_OPEN=0 does not open" "$FAKE_OPEN"
rm -f "$FAKE_OSA"

nprompt demo.prompt-1.md sonnet pending
touch -t 202001010000 "$sf" # older than the run: not this run's status file
"$watch" --once >/dev/null 2>&1
has "notify done: no status file" "$FAKE_OSA" "review (no status file), merge feat/x"
nprompt demo.prompt-1.md sonnet pending
CHIRAT_NOTIFY_OPEN=1 "$watch" --once >/dev/null 2>&1
absent "CHIRAT_NOTIFY_OPEN=1 without a status file does not open" "$FAKE_OPEN"
rm -f "$FAKE_OSA" "$sf"

nprompt demo.prompt-1.md sonnet pending
FAKE_FINAL=blocked FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
has "notify blocked" "$FAKE_OSA" "demo.prompt-1 needs a decision → question at the top of docs/status/2026-10-29-demo.prompt-1.md"
has "notify blocked: title" "$FAKE_OSA" 'title "chirat: blocked"'
rm -f "$FAKE_OSA"

nprompt demo.prompt-1.md sonnet pending
FAKE_MODE=noflip FAKE_SF=$sf CHIRAT_NOTIFY_OPEN=1 "$watch" --once >/dev/null 2>&1
has "notify failed: status file and err" "$FAKE_OSA" "demo.prompt-1 failed → docs/status/2026-10-29-demo.prompt-1.md, .chirat/runs/demo.prompt-1."
has "notify failed: err suffix" "$FAKE_OSA" ".err"
has "CHIRAT_NOTIFY_OPEN=1 opens on failed too" "$FAKE_OPEN" "$sf"
rm -f "$FAKE_OSA" "$FAKE_OPEN" "$sf"

# --- terminal-notifier -----------------------------------------------------

mkdir -p "$tmp/tn"
cat >"$tmp/tn/terminal-notifier" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_TN"
[ -z "$FAKE_TNERR" ] || echo "$FAKE_TNERR" >&2
exit "${FAKE_TNEXIT:-0}"
EOF2
chmod +x "$tmp/tn/terminal-notifier"
export FAKE_TN=$tmp/tn.out
rm -f "$FAKE_OSA" "$FAKE_OPEN" "$FAKE_TN"
oldpath=$PATH
PATH=$tmp/tn:$PATH
noflag() { # noflag <name> <flag>: the fake was not given <flag>
  if grep -qx -- "$2" "$FAKE_TN"; then ko "$1"; else ok "$1"; fi
}

nprompt demo.prompt-1.md sonnet pending
FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
has "terminal-notifier: called" "$FAKE_TN" "chirat: done"
has "terminal-notifier: -group" "$FAKE_TN" "chirat:nt"
has "terminal-notifier: title" "$FAKE_TN" "-title"
has "terminal-notifier: -activate by default" "$FAKE_TN" "com.anthropic.claudefordesktop"
has "terminal-notifier: -activate flag" "$FAKE_TN" "-activate"
noflag "terminal-notifier: no -sender" -sender
noflag "terminal-notifier: no -execute by default" -execute
noflag "terminal-notifier: no -open by default" -open
absent "terminal-notifier: osascript not called" "$FAKE_OSA"
rm -f "$FAKE_TN"

printf 'notify_open=claude://claude.ai/project/x\n' >"$ws/.chirat/config"
nprompt demo.prompt-1.md sonnet pending
FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
has "notify_open: -open URL" "$FAKE_TN" "claude://claude.ai/project/x"
has "notify_open: -open flag" "$FAKE_TN" "-open"
noflag "notify_open: no -execute" -execute
noflag "notify_open: no -activate" -activate
noflag "notify_open: no -sender" -sender
rm -f "$FAKE_TN"

nprompt demo.prompt-1.md sonnet pending
FAKE_SF=$sf CHIRAT_NOTIFY_OPEN=1 "$watch" --once >/dev/null 2>&1
has "CHIRAT_NOTIFY_OPEN: file first, then URL" "$FAKE_TN" "open '$sf'; open 'claude://claude.ai/project/x'"
noflag "CHIRAT_NOTIFY_OPEN: no -open" -open
noflag "CHIRAT_NOTIFY_OPEN: no -activate" -activate
absent "CHIRAT_NOTIFY_OPEN: not opened at once under terminal-notifier" "$FAKE_OPEN"
rm -f "$FAKE_TN" "$sf"

printf "notify_open=/tmp/it's\n" >"$ws/.chirat/config"
nprompt demo.prompt-1.md sonnet pending
FAKE_SF=$sf "$watch" --once >/dev/null 2>"$tmp/nterr"
noflag "quote in notify_open: no -execute" -execute
noflag "quote in notify_open: no -open" -open
has "quote in notify_open: warn" "$tmp/nterr" "warning: notify_open"
rm -f "$FAKE_TN" "$sf" "$ws/.chirat/config"

nprompt demo.prompt-1.md sonnet pending
CHIRAT_NOTIFY=0 FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
absent "CHIRAT_NOTIFY=0: terminal-notifier not called" "$FAKE_TN"
absent "CHIRAT_NOTIFY=0: osascript not called" "$FAKE_OSA"
rm -f "$sf"

nprompt demo.prompt-1.md sonnet pending
CHIRAT_NOTIFY_ACTIVATE='' FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
has "empty CHIRAT_NOTIFY_ACTIVATE: still notifies" "$FAKE_TN" "chirat: done"
noflag "empty CHIRAT_NOTIFY_ACTIVATE: no -activate" -activate
noflag "empty CHIRAT_NOTIFY_ACTIVATE: no -open" -open
noflag "empty CHIRAT_NOTIFY_ACTIVATE: no -execute" -execute
rm -f "$FAKE_TN" "$sf"

nprompt demo.prompt-1.md sonnet pending
CHIRAT_NOTIFY_ACTIVATE=com.example.app FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
has "CHIRAT_NOTIFY_ACTIVATE overrides the bundle id" "$FAKE_TN" "com.example.app"
rm -f "$FAKE_TN" "$sf"

# stderr and exit code of terminal-notifier end up in the run's .err
rm -f "$ws"/.chirat/runs/*
nprompt demo.prompt-1.md sonnet pending
FAKE_TNERR='[!] -sender is no longer supported and will be ignored' FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
nerr=$(find "$ws/.chirat/runs" -name "demo.prompt-1.*.err" | head -n 1)
has "notify stderr: header in .err" "$nerr" "notify: terminal-notifier said:"
has "notify stderr: line in .err" "$nerr" "[!] -sender is no longer supported"
rm -f "$FAKE_TN" "$sf" "$ws"/.chirat/runs/*

nprompt demo.prompt-1.md sonnet pending
FAKE_TNEXIT=2 FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
nerr=$(find "$ws/.chirat/runs" -name "demo.prompt-1.*.err" | head -n 1)
has "notify exit: line in .err" "$nerr" "notify: terminal-notifier exit 2"
rm -f "$FAKE_TN" "$sf" "$ws"/.chirat/runs/*

nprompt demo.prompt-1.md sonnet pending
FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
nerr=$(find "$ws/.chirat/runs" -name "demo.prompt-1.*.err" | head -n 1)
if grep -q 'notify:' "$nerr"; then ko "quiet notify: nothing in .err"; else ok "quiet notify: nothing in .err"; fi
rm -f "$FAKE_TN" "$sf"

PATH=$oldpath
nprompt demo.prompt-1.md sonnet pending
FAKE_SF=$sf "$watch" --once >/dev/null 2>&1
has "no terminal-notifier: osascript as before" "$FAKE_OSA" "chirat: done"
absent "no terminal-notifier: nothing recorded" "$FAKE_TN"
rm -f "$FAKE_OSA" "$sf"

# a longer stem does not lend its status file (prompt-1 vs prompt-16)
nprompt demo.prompt-1.md sonnet pending
printf x >"$ws/docs/status/2026-10-29-demo.prompt-16.md"
"$watch" --once >/dev/null 2>&1
has "notify: prompt-16's file is not prompt-1's" "$FAKE_OSA" "review (no status file)"
rm -f "$FAKE_OSA" "$ws/docs/status/2026-10-29-demo.prompt-16.md"

# status: the next: line, one case per branch of the rule
rm -f "$ws"/docs/plans/*.md "$ws"/docs/status/*.md
nx() { st; grep '^  next:' "$tmp/st.out"; }
# shellcheck disable=SC2016 # backticks are literal
eq "status header sentence" 'A `done` prompt is a branch waiting for your review and merge; nothing lands on `main` by itself, and the next `after:` prompt waits for that merge.' "$(head -n 1 "$tmp/st.out")"
eq "status next: queue empty" "  next: queue empty" "$(nx)"
nprompt demo.prompt-1.md sonnet pending
nprompt demo.prompt-2.md sonnet pending
eq "status next: pending" "  next: wait (2 pending)" "$(nx)"
"$rp" set "$ws/docs/plans/demo.prompt-1.md" status running
eq "status next: running" "  next: wait (demo.prompt-1 running since -)" "$(nx)"
"$rp" set "$ws/docs/plans/demo.prompt-1.md" status failed
printf x >"$ws/docs/status/2026-10-29-demo.prompt-1.md"
"$rp" set "$ws/docs/plans/demo.prompt-2.md" status failed
eq "status next: failed" "  next: look at demo.prompt-1 (docs/status/2026-10-29-demo.prompt-1.md)" "$(nx)"
"$rp" set "$ws/docs/plans/demo.prompt-2.md" status blocked
printf x >"$ws/docs/status/2026-10-29-demo.prompt-2.md"
eq "status next: blocked beats failed" "  next: answer demo.prompt-2 (docs/status/2026-10-29-demo.prompt-2.md)" "$(nx)"

# done with an unmerged branch: oldest status file first; releases lists the waiting prompts
git -C "$ws/repos/demo" checkout -q -b feat/a
git -C "$ws/repos/demo" commit -q --allow-empty -m a
git -C "$ws/repos/demo" checkout -q main
git -C "$ws/repos/demo" checkout -q -b feat/b
git -C "$ws/repos/demo" commit -q --allow-empty -m b
git -C "$ws/repos/demo" checkout -q main
nprompt demo.prompt-1.md sonnet 'done' feat/a
nprompt demo.prompt-2.md sonnet 'done' feat/b
nprompt demo.prompt-3.md sonnet pending
"$rp" set "$ws/docs/plans/demo.prompt-3.md" after feat/a
nprompt demo.prompt-4.md sonnet pending
"$rp" set "$ws/docs/plans/demo.prompt-4.md" after feat/a
touch -t 202601010000 "$ws/docs/status/2026-10-29-demo.prompt-2.md"
eq "status next: done unmerged, oldest first, releases" "  next: review demo.prompt-2 (feat/b, docs/status/2026-10-29-demo.prompt-2.md), then merge; releases nothing
  next: review demo.prompt-1 (feat/a, docs/status/2026-10-29-demo.prompt-1.md), then merge; releases demo.prompt-3, demo.prompt-4" "$(nx)"
git -C "$ws/repos/demo" merge -q --no-edit feat/a
git -C "$ws/repos/demo" merge -q --no-edit feat/b
eq "status next: merged → pending" "  next: wait (2 pending)" "$(nx)"
ws=$tmp/ws

# --- .chirat/config: plans_dir, status_dir, default_branch -------------------

ws2=$tmp/ws2
mkdir -p "$ws2/work/queue" "$ws2/work/notes" "$ws2/.chirat"
printf '%s\n' '# custom layout' 'plans_dir=work/queue' 'status_dir = work/notes' 'bogus line' 'unknown=1' >"$ws2/.chirat/config"
cfgprompt() { # cfgprompt <file> <status> <branch> [after]
  {
    printf '%s\n' '---' 'model: sonnet' "status: $2" 'repo: demo' "branch: $3"
    [ -z "${4:-}" ] || printf 'after: %s\n' "$4"
    printf '%s\n' '---' '# demo'
  } >"$1"
}
cfgprompt "$ws2/work/queue/demo.prompt-1.md" pending feat/x
git -C "$ws2" init -q
git -C "$ws2" add -A
git -C "$ws2" commit -q -m "start"
ws3=$tmp/ws3
mkdir -p "$ws3/docs/plans" "$ws3/docs/status/runs" "$ws3/repos/demo" "$ws3/.chirat"
: >"$ws3/docs/status/LATEST"
git -C "$ws3/repos/demo" init -q -b trunk
git -C "$ws3/repos/demo" commit -q --allow-empty -m base
git -C "$ws3/repos/demo" checkout -q -b feat/t
git -C "$ws3/repos/demo" commit -q --allow-empty -m t
git -C "$ws3/repos/demo" checkout -q trunk
mkdir -p "$tmp/cfg2/chirat"
printf '%s\n' "$ws2" "$ws3" >"$tmp/cfg2/chirat/workspaces"
cfgprompt "$ws3/docs/plans/demo.prompt-1.md" "done" feat/t
cfgprompt "$ws3/docs/plans/demo.prompt-2.md" pending feat/u feat/t
printf '%s\n' 'default_branch=trunk' >"$ws3/.chirat/config"

: >"$tmp/osa"
XDG_CONFIG_HOME=$tmp/cfg2 FAKE_SF=$ws2/work/notes/2026-10-29-demo.prompt-1.md "$watch" --once >"$tmp/out" 2>"$tmp/stderr"
eq "config: plans_dir: prompt from work/queue ran" "done" "$("$rp" get "$ws2/work/queue/demo.prompt-1.md" status)"
eq "config: plans_dir: claude gets the configured path" "/chirat:next work/queue/demo.prompt-1.md" "$(sed -n '/^-p$/{n;p;}' "$FAKE_ARGV")"
has "config: status_dir: notification names work/notes file" "$tmp/osa" "work/notes/2026-10-29-demo.prompt-1.md"
has "config: malformed line is a warning" "$tmp/stderr" "not key=value"
eq "config: status.log lands in .chirat/" "work/queue/demo.prompt-1.md" "$(sed -n 1p "$ws2/.chirat/status.log" | cut -f2)"
json2=$(first "$ws2"/.chirat/runs/demo.prompt-1.*.json)
err2=${json2%.json}.err
eq "run log commit holds .chirat/runs, LATEST and the prompt, not the lock" ".chirat/LATEST
.chirat/runs/${err2##*/}
.chirat/runs/${json2##*/}
.chirat/status.log
work/queue/demo.prompt-1.md" "$(git -C "$ws2" show --name-only --format= HEAD | sort)"
absent "config: lock released" "$ws2/.chirat/lock"

XDG_CONFIG_HOME=$tmp/cfg2 "$watch" status ws3 >"$tmp/st.out" 2>&1
has "default_branch=trunk: unmerged branch is reviewed" "$tmp/st.out" "next: review demo.prompt-1 (feat/t, (no status file)), then merge; releases demo.prompt-2"
has "legacy run log: status warns" "$tmp/st.out" "warn: legacy run log at docs/status/runs — move it: git mv docs/status/runs .chirat/runs && git mv docs/status/LATEST .chirat/LATEST"
git -C "$ws3/repos/demo" merge -q --no-edit feat/t
XDG_CONFIG_HOME=$tmp/cfg2 "$watch" status ws3 >"$tmp/st.out" 2>&1
has "default_branch=trunk: merged branch → next is the waiting prompt" "$tmp/st.out" "next: wait (1 pending)"

# W1: two clones on different branches, one per-repo key
ws4=$tmp/ws4
mkdir -p "$ws4/docs/plans" "$ws4/docs/status" "$ws4/.chirat"
for spec in app:dev lib:main; do
  r4=$ws4/repos/${spec%%:*} b4=${spec#*:}
  mkdir -p "$r4"
  git -C "$r4" init -q -b "$b4"
  git -C "$r4" commit -q --allow-empty -m base
  git -C "$r4" checkout -q -b "feat/${spec%%:*}"
  git -C "$r4" commit -q --allow-empty -m work
  git -C "$r4" checkout -q "$b4"
done
cfgprompt "$ws4/docs/plans/two.prompt-1.md" "done" feat/app
"$rp" set "$ws4/docs/plans/two.prompt-1.md" repo app
cfgprompt "$ws4/docs/plans/two.prompt-2.md" "done" feat/lib
"$rp" set "$ws4/docs/plans/two.prompt-2.md" repo lib
printf '%s\n' 'default_branch.app=dev' >"$ws4/.chirat/config"
mkdir -p "$tmp/cfg4/chirat"
printf '%s\n' "$ws4" >"$tmp/cfg4/chirat/workspaces"
st4() { XDG_CONFIG_HOME=$tmp/cfg4 "$watch" status ws4 2>&1 | grep '^  next:'; }
app4="  next: review two.prompt-1 (feat/app, (no status file)), then merge; releases nothing"
lib4="  next: review two.prompt-2 (feat/lib, (no status file)), then merge; releases nothing"
eq "W1: an unmerged branch in each clone is reviewed" "$app4
$lib4" "$(st4 | sort)"
git -C "$ws4/repos/app" merge -q --no-edit feat/app
eq "W1: app merged into dev: its line is gone" "$lib4" "$(st4)"
git -C "$ws4/repos/lib" merge -q --no-edit feat/lib
eq "W1: lib merged into main: nothing to review" "  next: queue empty" "$(st4)"

rmdir "$ws3/docs/status/runs"
XDG_CONFIG_HOME=$tmp/cfg2 "$watch" status ws3 >"$tmp/st.out" 2>&1
has "legacy: only LATEST left" "$tmp/st.out" "move it: git mv docs/status/LATEST .chirat/LATEST"
XDG_CONFIG_HOME=$tmp/cfg2 "$watch" doctor >"$tmp/doc.out" 2>&1
has "legacy run log: doctor warns" "$tmp/doc.out" "warn workspace $ws3: legacy run log at docs/status/runs"
ws=$tmp/ws

# --- upgrading from relay: warnings only ---------------------------------------

lg=$tmp/lg
mkdir -p "$lg/cfg/chirat" "$lg/state"
wsl=$lg/old
mkdir -p "$wsl/docs/plans" "$wsl/docs/status" "$wsl/repos" "$wsl/.relay/runs"
cfgprompt "$wsl/docs/plans/demo.prompt-1.md" pending feat/l
printf '%s\n' "$wsl" >"$lg/cfg/chirat/workspaces"
lgw() { XDG_CONFIG_HOME=$lg/cfg XDG_STATE_HOME=$lg/state "$watch" "$@"; }
mv_hint="legacy .relay/ — move it: git mv .relay .chirat && sed -i.bak 's#^\.relay/#.chirat/#' .gitignore && rm .gitignore.bak"
lgw --once --dry-run >"$tmp/out" 2>&1
absent "legacy .relay/: dry-run writes no state dir" "$lg/state/chirat"
lgw --once >"$tmp/out" 2>&1
eq "legacy .relay/: watcher skips the workspace" pending "$("$rp" get "$wsl/docs/plans/demo.prompt-1.md" status)"
absent "legacy .relay/: no .chirat/ created" "$wsl/.chirat"
has "legacy .relay/: logged" "$lg/state/chirat/watch.log" "$(printf 'legacy\t%s\t.relay/\t' "$wsl")"
lgw --once >"$tmp/out" 2>&1
eq_log "legacy .relay/: logged once" 1 "$(grep -c "	legacy	" "$lg/state/chirat/watch.log")" "$lg/state/chirat/watch.log"
lgw status >"$tmp/st.out" 2>&1
has "legacy .relay/: status warns" "$tmp/st.out" "  warn: $mv_hint"
PATH=$dpath lgw doctor >"$tmp/doc.out" 2>&1
has "legacy .relay/: doctor warns" "$tmp/doc.out" "warn workspace $wsl: $mv_hint"
mkdir "$wsl/.relay/lock"
lgw status >"$tmp/st.out" 2>&1
has "legacy .relay/lock: status says check first" "$tmp/st.out" "a run from the old watcher may still be live: check it first"
if grep -qF "git mv .relay" "$tmp/st.out"; then ko "legacy .relay/lock: no move command"; else ok "legacy .relay/lock: no move command"; fi
rmdir "$wsl/.relay/lock"
mkdir "$wsl/.chirat"
lgw status >"$tmp/st.out" 2>&1
if grep -qF "legacy .relay/" "$tmp/st.out"; then ko "legacy .relay/: quiet once .chirat/ exists"; else ok "legacy .relay/: quiet once .chirat/ exists"; fi
rmdir "$wsl/.chirat"

# old config dir, chirat one missing
mkdir -p "$lg/cfgold/relay"
printf '%s\n' "$wsl" >"$lg/cfgold/relay/workspaces"
XDG_CONFIG_HOME=$lg/cfgold XDG_STATE_HOME=$lg/state "$watch" status >"$tmp/st.out" 2>&1
has "legacy config: status warns" "$tmp/st.out" "warn: legacy config $lg/cfgold/relay/workspaces — move it: mv $lg/cfgold/relay $lg/cfgold/chirat"
XDG_CONFIG_HOME=$lg/cfgold XDG_STATE_HOME=$lg/state PATH=$dpath "$watch" doctor >"$tmp/doc.out" 2>&1
has "legacy config: doctor warns" "$tmp/doc.out" "warn legacy config $lg/cfgold/relay/workspaces — move it: mv $lg/cfgold/relay $lg/cfgold/chirat"
mkdir -p "$lg/home/.config/relay"
printf '%s\n' "$wsl" >"$lg/home/.config/relay/workspaces"
env -u XDG_CONFIG_HOME HOME="$lg/home" XDG_STATE_HOME="$lg/state" "$watch" status >"$tmp/st.out" 2>&1
has "legacy config: default base under HOME" "$tmp/st.out" "mv $lg/home/.config/relay $lg/home/.config/chirat"

# RELAY_* variables
RELAY_NOTIFY=0 lgw status >"$tmp/st.out" 2>&1
has "RELAY_NOTIFY: status warns" "$tmp/st.out" "warn: RELAY_NOTIFY is set and ignored — use CHIRAT_NOTIFY"
has "RELAY_NOTIFY: ignored" "$tmp/st.out" "CHIRAT_NOTIFY=1"
RELAY_STOP_GRACE=3 PATH=$dpath lgw doctor >"$tmp/doc.out" 2>&1
has "RELAY_STOP_GRACE: doctor warns" "$tmp/doc.out" "warn RELAY_STOP_GRACE is set and ignored — use CHIRAT_STOP_GRACE"

# old commands on PATH, old tmux session
mkdir -p "$lg/oldbin"
ln -s "$watch" "$lg/oldbin/relay-watch"
ln -s "$rp" "$lg/oldbin/relay-prompt"
FAKE_TMUX_SESSIONS=relay PATH=$lg/oldbin:$dpath lgw doctor >"$tmp/doc.out" 2>&1
has "old relay-watch: doctor warns" "$tmp/doc.out" "warn relay-watch: old command still on PATH: rm $lg/oldbin/relay-watch"
has "old relay-prompt: doctor warns" "$tmp/doc.out" "warn relay-prompt: old command still on PATH: rm $lg/oldbin/relay-prompt"
has "old tmux session: doctor warns" "$tmp/doc.out" "warn old watcher still running: tmux kill-session -t relay"
PATH=$dpath lgw doctor >"$tmp/doc.out" 2>&1
if grep -qE "old command|old watcher" "$tmp/doc.out"; then ko "doctor: no old-install warnings without them" "$(cat "$tmp/doc.out")"; else ok "doctor: no old-install warnings without them"; fi

# --- --dry-run previews the prompt a real pass would run -----------------------
# A prompt left `running` under a stale lock is re-queued by a real pass and
# then competes with the pending ones in queue order; the preview must name
# the same prompt, and still write nothing.

ws=$tmp/dry
runs=$ws/.chirat/runs
mkdir -p "$ws"/docs/{plans,status} "$ws"/repos
printf '%s\n' "$ws" >"$XDG_CONFIG_HOME/chirat/workspaces"
git init -q -b main "$ws/repos/demo"
git -C "$ws/repos/demo" commit -q --allow-empty -m init
git -C "$ws/repos/demo" checkout -q -b dep
git -C "$ws/repos/demo" commit -q --allow-empty -m dep
git -C "$ws/repos/demo" checkout -q main
p1=$ws/docs/plans/demo.prompt-1.md
p2=$ws/docs/plans/demo.prompt-2.md
would_run() { printf '%s\n' "$1" | grep -o 'claude -p /chirat:next\\ [^ ]*' | sed 's/.*next\\ //'; }
ran() { sed -n '/^-p$/{n;p;}' "$FAKE_ARGV" | sed 's#^/chirat:next ##'; }
rm -f "$XDG_STATE_HOME"/chirat/watcher.*

# The repro: 1 running under a stale lock, 2 pending — preview and real pass say 1.
prompt demo.prompt-1.md sonnet pending
prompt demo.prompt-2.md sonnet pending
pf=$p1
die_mid_run hang
eq "preview: 1 is running under a stale lock" running "$("$rp" get "$p1" status)"
before=$(fs_snapshot "$ws" "$XDG_STATE_HOME")
out=$("$watch" --once --dry-run 2>/dev/null)
has "preview: would re-queue 1" <(printf '%s\n' "$out") "would set docs/plans/demo.prompt-1.md pending"
eq "preview: would run 1, not 2" docs/plans/demo.prompt-1.md "$(would_run "$out")"
eq "preview: wrote nothing" "$before" "$(fs_snapshot "$ws" "$XDG_STATE_HOME")"
: >"$FAKE_ARGV"
"$watch" --once >/dev/null 2>&1
eq "real pass: ran 1" docs/plans/demo.prompt-1.md "$(ran)"
eq "real pass: 1 is done" "done" "$("$rp" get "$p1" status)"
eq "real pass: 2 still pending" pending "$("$rp" get "$p2" status)"

# The mirror: 2 running under a stale lock, 1 pending — both say 1.
prompt demo.prompt-1.md sonnet blocked
prompt demo.prompt-2.md sonnet pending
pf=$p2
die_mid_run hang
"$rp" set "$p1" status pending
out=$("$watch" --once --dry-run 2>/dev/null)
has "preview (mirror): would re-queue 2" <(printf '%s\n' "$out") "would set docs/plans/demo.prompt-2.md pending"
eq "preview (mirror): would run 1" docs/plans/demo.prompt-1.md "$(would_run "$out")"
: >"$FAKE_ARGV"
"$watch" --once >/dev/null 2>&1
eq "real pass (mirror): ran 1" docs/plans/demo.prompt-1.md "$(ran)"
eq "real pass (mirror): 2 re-queued, not run" pending "$("$rp" get "$p2" status)"

# The recovered prompt has an unmet after: — both skip it.
prompt demo.prompt-1.md sonnet pending
prompt demo.prompt-2.md sonnet pending
pf=$p1
die_mid_run hang
"$rp" set "$p1" after dep
out=$("$watch" --once --dry-run 2>/dev/null)
has "preview (after): would re-queue 1" <(printf '%s\n' "$out") "would set docs/plans/demo.prompt-1.md pending"
eq "preview (after): would run 2, 1 waits for dep" docs/plans/demo.prompt-2.md "$(would_run "$out")"
: >"$FAKE_ARGV"
"$watch" --once >/dev/null 2>&1
eq "real pass (after): ran 2" docs/plans/demo.prompt-2.md "$(ran)"
eq "real pass (after): 1 re-queued and waiting" pending "$("$rp" get "$p1" status)"

# --- parallel workspaces: one queue per workspace, --max-parallel ------------
# T<n> follows §5 of the prompt that introduced this (relay.prompt-30). Each
# test gets fresh workspaces under $par and a fresh log; runs last as long as
# their prompt's `fake-sleep:` says.

par=$tmp/par
mkdir -p "$par"
export CHIRAT_NOTIFY=0
mkpws() { # mkpws <name>…: workspaces under $par, each with a clone
  local w
  for w in "$@"; do
    w=$par/$w
    mkdir -p "$w"/docs/{plans,status} "$w/repos" "$w/.chirat"
    git init -q -b main "$w/repos/demo"
    git -C "$w/repos/demo" commit -q --allow-empty -m init
  done
}
pprompt() { # pprompt <ws name> <file> [sleep seconds]
  {
    printf '%s\n' '---' 'model: sonnet' 'status: pending' 'repo: demo' 'branch: feat/x' '---' "# $2"
    [ -z "${3:-}" ] || printf 'fake-sleep: %s\n' "$3"
  } >"$par/$1/docs/plans/$2"
}
pcfg() { # pcfg <ws name>…: the watcher's config, in that order
  printf '%s\n' "$@" | sed "s#^#$par/#" >"$XDG_CONFIG_HOME/chirat/workspaces"
}
preset() { # preset: empty log, no .seen files, no watcher pid files
  rm -f "$XDG_STATE_HOME"/chirat/*.seen "$XDG_STATE_HOME"/chirat/watcher.*
  : >"$log"
}
pst() { "$rp" get "$par/$1/docs/plans/$2" status; }
plock() { printf '%s\n' "$par/$1/.chirat/lock"; }
# foreign_lock <ws name> <runner pid> <prompt>: a live lock this watcher did not
# start — <runner pid> (a helper process) stands in for its runner.
foreign_lock() {
  local l=$par/$1/.chirat/lock
  mkdir -p "$l"
  echo $$ >"$l/watcher.pid"
  echo "$2" >"$l/runner.pid"
  echo "docs/plans/$3" >"$l/prompt"
  echo "${3%.md}.20260101-000000" >"$l/run"
  echo 2026-01-01T00:00:00+0000 >"$l/started"
}
wait_claude_in() { # wait_claude_in <ws name> <file>: until it runs and claude.pid is there
  local _
  for _ in $(seq 1 100); do
    [ "$(pst "$1" "$2")" = running ] && [ -s "$par/$1/.chirat/lock/claude.pid" ] && return 0
    sleep 0.1
  done
  return 1
}
run_lines() { awk -F'\t' '$2 !~ /^(waiting|held|misnamed|legacy)$/' "$log" | wc -l | tr -d ' '; }
runs_at_least() { [ "$(run_lines)" -ge "$1" ]; }
held_at_least() { [ "$(held_lines "$1")" -ge "$2" ]; }
pst_is() { [ "$(pst "$1" "$2")" = "$3" ]; }
run_ws_seq() { awk -F'\t' '$2 !~ /^(waiting|held|misnamed|legacy)$/ { n = split($2, a, "/"); printf "%s%s", (c++ ? " " : ""), a[n] }' "$log"; }
held_lines() { awk -F'\t' -v w="$par/$1" '$2 == "held" && $3 == w' "$log" | wc -l | tr -d ' '; }
log_parses() { # every line is a 7-field run line or a known keyword line
  awk -F'\t' '
    $2 == "held" { if (NF != 6 || $5 !~ /^limit=[0-9]+$/ || $6 !~ /^running=/) bad = 1; next }
    $2 == "waiting" || $2 == "misnamed" { if (NF != 5) bad = 1; next }
    $2 == "legacy" { if (NF != 5) bad = 1; next }
    { if (NF != 7 || $1 !~ /^[0-9]{4}-/) bad = 1 }
    END { exit bad }' "$log"
}
stop_watcher() { kill -TERM "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

# T1: default cap, two workspaces, two pending each — runs alternate, one at
# a time; the held workspace says why, once per wait.
mkpws p1 p2
pprompt p1 demo.prompt-1.md 1; pprompt p1 demo.prompt-2.md 1
pprompt p2 demo.prompt-1.md 1; pprompt p2 demo.prompt-2.md 1
pcfg p1 p2
preset
"$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in p1 demo.prompt-1.md
exists "T1: runner.pid is in the lock" -s "$(plock p1)/runner.pid"
eq "T1: lock's watcher.pid is the watcher" "$wpid" "$(cat "$(plock p1)/watcher.pid")"
rpid=$(cat "$(plock p1)/runner.pid")
if kill -0 "$rpid" 2>/dev/null && [ "$(ps -o ppid= -p "$rpid" | tr -d ' ')" = "$wpid" ]; then ok "T1: the runner is a child of the watcher"; else ko "T1: the runner is a child of the watcher"; fi
"$watch" status p2 >"$tmp/st.out" 2>&1
has "T1: status: watcher line reports the cap" "$tmp/st.out" "parallel: 1)"
has "T1: status: held workspace names the limit and the running one" "$tmp/st.out" "  next: wait (2 pending; limit 1, running: p1)"
until_true 300 runs_at_least 4
eq_log "T1: four runs" 4 "$(run_lines)"
eq_log "T1: runs alternate p1, p2, p1, p2" "p1 p2 p1 p2" "$(run_ws_seq)"
eq "T1: all four done" "done done done done" "$(pst p1 demo.prompt-1.md) $(pst p1 demo.prompt-2.md) $(pst p2 demo.prompt-1.md) $(pst p2 demo.prompt-2.md)"
eq_log "T1: p2 held twice (one line per wait)" 2 "$(held_lines p2)"
eq_log "T1: p1 held once" 1 "$(held_lines p1)"
want=$(printf 'held\t%s/p2\tdocs/plans/demo.prompt-1.md\tlimit=1\trunning=p1' "$par")
case $(grep "	held	" "$log" | head -n 1) in *"$want") ok "T1: held line format" ;; *) ko "T1: held line format" "$(grep "	held	" "$log" | head -n 1)" ;; esac
eq "T1: held lines echoed to stdout" 3 "$(grep -c "	held	" "$tmp/out")"
if log_parses; then ok "T1: every log line parses"; else ko "T1: every log line parses" "$(cat "$log")"; fi
stop_watcher "$wpid"
eq_log "T1: logs filter matches held lines" 2 "$("$watch" logs -n 100 p2 | grep -c "	held	")"

# T2: a finished run wakes the watcher — the next run starts long before the
# interval has elapsed.
mkpws q1
pprompt q1 demo.prompt-1.md 1; pprompt q1 demo.prompt-2.md 1
pcfg q1
preset
t0=$(date +%s)
"$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
until_true 150 runs_at_least 2
t1=$(date +%s)
eq_log "T2: two runs" 2 "$(run_lines)"
if [ $((t1 - t0)) -le 10 ]; then ok "T2: second run started within 10 s of the first, interval 1000"; else ko "T2: second run started within 10 s of the first, interval 1000" "$((t1 - t0)) s"; fi
stop_watcher "$wpid"
eq "T2: watcher exits 130 on TERM with no run live" 130 $?

# T3: --max-parallel 2, two workspaces: both run at once, no held line.
mkpws r1 r2
pprompt r1 demo.prompt-1.md 3; pprompt r2 demo.prompt-1.md 3
pcfg r1 r2
preset
"$watch" --interval 1000 --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in r1 demo.prompt-1.md
wait_claude_in r2 demo.prompt-1.md
if [ -d "$(plock r1)" ] && [ -d "$(plock r2)" ]; then ok "T3: both locks exist at the same time"; else ko "T3: both locks exist at the same time"; fi
"$watch" status >"$tmp/st.out" 2>&1
has "T3: status reports parallel: 2" "$tmp/st.out" "parallel: 2)"
"$watch" tail >"$tmp/out2" 2>"$tmp/stderr2"
eq "T3: tail without a workspace refuses with two live runs" 1 $?
eq "T3: tail lists one command per workspace" "  chirat-watch tail r1
  chirat-watch tail r2" "$(grep 'chirat-watch tail' "$tmp/stderr2")"
until_true 150 runs_at_least 2
eq "T3: both done" "done done" "$(pst r1 demo.prompt-1.md) $(pst r2 demo.prompt-1.md)"
eq_log "T3: two log lines, no held line" 2 "$(wc -l <"$log" | tr -d ' ')"
if log_parses; then ok "T3: every log line parses"; else ko "T3: every log line parses" "$(cat "$log")"; fi
stop_watcher "$wpid"
absent "T3: locks gone" "$(plock r1)"

# T3b: a workspace listed twice is one workspace: its run takes one slot of
# the cap, and status, tail and --dry-run show it once.
mkpws d1 d2
pprompt d1 demo.prompt-1.md 4; pprompt d2 demo.prompt-1.md 1
printf '%s\n%s/  # again\n%s\n' "$par/d1" "$par/d1" "$par/d2" >"$XDG_CONFIG_HOME/chirat/workspaces"
preset
eq "T3b: dry run previews it once" 1 "$("$watch" --once --dry-run 2>/dev/null | grep -c "^cd $par/d1 ")"
"$watch" --interval 1000 --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in d1 demo.prompt-1.md
wait_claude_in d2 demo.prompt-1.md
if [ -d "$(plock d1)" ] && [ "$(pst d2 demo.prompt-1.md)" != pending ]; then ok "T3b: the other workspace gets the second slot"; else ko "T3b: the other workspace gets the second slot" "$(cat "$log")"; fi
until_true 150 runs_at_least 1
eq "T3b: one section in status" 1 "$("$watch" status | grep -cx "$par/d1")"
until_true 150 runs_at_least 2
eq_log "T3b: two log lines, no held line" 2 "$(wc -l <"$log" | tr -d ' ')"
stop_watcher "$wpid"
# T3b, tail: no run, nothing waited for — one live lock made by hand in a
# workspace listed twice is one run.
mkpws t1
pcfg t1 t1
sleep 300 &
hpid=$!
foreign_lock t1 "$hpid" demo.prompt-1.md
"$watch" tail >"$tmp/out2" 2>&1
eq "T3b: tail exits 0 on a workspace listed twice" 0 $?
eq "T3b: tail sees one run" "no transcript yet" "$(cat "$tmp/out2")"
kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
rm -r "$(plock t1)"

# T4: --max-parallel 2, three workspaces: the third is held, then runs.
mkpws s1 s2 s3
pprompt s1 demo.prompt-1.md 2; pprompt s2 demo.prompt-1.md 2; pprompt s3 demo.prompt-1.md 1
pcfg s1 s2 s3
preset
"$watch" --interval 1000 --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in s1 demo.prompt-1.md
wait_claude_in s2 demo.prompt-1.md
until_true 50 held_at_least s3 1
eq_log "T4: third workspace held" 1 "$(held_lines s3)"
has "T4: held line names both running workspaces" "$log" "limit=2	running=s1,s2"
absent "T4: held workspace has no lock" "$(plock s3)"
until_true 150 runs_at_least 3
eq "T4: then it ran" "done" "$(pst s3 demo.prompt-1.md)"
eq_log "T4: three runs" 3 "$(run_lines)"
stop_watcher "$wpid"

# T5: one workspace mid-run, a prompt set pending in another, cap 2 — it
# starts on the next pass (the starvation this fixes).
mkpws u1 u2
pprompt u1 demo.prompt-1.md 4
pcfg u1 u2
preset
"$watch" --interval 1 --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in u1 demo.prompt-1.md
pprompt u2 demo.prompt-1.md 1
if wait_claude_in u2 demo.prompt-1.md && [ -d "$(plock u1)" ] && [ "$(pst u1 demo.prompt-1.md)" = running ]; then
  ok "T5: the second workspace starts while the first is still running"
else
  ko "T5: the second workspace starts while the first is still running" "u1=$(pst u1 demo.prompt-1.md) u2=$(pst u2 demo.prompt-1.md)"
fi
until_true 150 runs_at_least 2
eq "T5: both done" "done done" "$(pst u1 demo.prompt-1.md) $(pst u2 demo.prompt-1.md)"
stop_watcher "$wpid"

# T6: SIGTERM with two runs live: both back to pending, both locks gone.
mkpws v1 v2
pprompt v1 demo.prompt-1.md 30; pprompt v2 demo.prompt-1.md 30
pcfg v1 v2
preset
"$watch" --interval 1000 --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in v1 demo.prompt-1.md
wait_claude_in v2 demo.prompt-1.md
c1=$(cat "$(plock v1)/claude.pid") c2=$(cat "$(plock v2)/claude.pid")
kill -TERM "$wpid"
wait "$wpid"
eq "T6: watcher exits 130" 130 $?
eq "T6: both prompts pending" "pending pending" "$(pst v1 demo.prompt-1.md) $(pst v2 demo.prompt-1.md)"
absent "T6: v1 lock gone" "$(plock v1)"
absent "T6: v2 lock gone" "$(plock v2)"
has "T6: v1 err notes the interruption" "$(first "$par"/v1/.chirat/runs/*.err)" "chirat-watch was interrupted with the prompt still 'running'; set to pending (SIGTERM)"
has "T6: v2 err notes the interruption" "$(first "$par"/v2/.chirat/runs/*.err)" "set to pending (SIGTERM)"
eq_log "T6: two interrupted log lines" 2 "$(grep -c "	interrupted	" "$log")"
if kill -0 "$c1" 2>/dev/null || kill -0 "$c2" 2>/dev/null; then ko "T6: both claudes gone"; else ok "T6: both claudes gone"; fi
absent "T6: watcher.pid gone" "$XDG_STATE_HOME/chirat/watcher.pid"

# T7: --once keeps its meaning: default cap runs the hits one after another in
# config order; cap 2 exits only after both have finished.
mkpws w1 w2
pprompt w1 demo.prompt-1.md 1; pprompt w2 demo.prompt-1.md 1
pcfg w1 w2
preset
t0=$(date +%s)
"$watch" --once >"$tmp/out" 2>"$tmp/stderr"
rc=$?
t1=$(date +%s)
eq "T7: --once exits 0" 0 "$rc"
eq_log "T7: --once ran both, in config order" "w1 w2" "$(run_ws_seq)"
eq "T7: --once: both done at exit" "done done" "$(pst w1 demo.prompt-1.md) $(pst w2 demo.prompt-1.md)"
if [ $((t1 - t0)) -ge 2 ]; then ok "T7: --once under the default cap ran them one after another"; else ko "T7: --once under the default cap ran them one after another" "$((t1 - t0)) s"; fi
eq_log "T7: --once wrote no held line" 0 "$(grep -c "	held	" "$log")"
absent "T7: --once: no lock left" "$(plock w1)"
pprompt w1 demo.prompt-2.md 2; pprompt w2 demo.prompt-2.md 2
preset
t0=$(date +%s)
"$watch" --once --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr"
rc=$?
t1=$(date +%s)
eq "T7: --once --max-parallel 2 exits 0" 0 "$rc"
eq "T7: --once --max-parallel 2: both done at exit" "done done" "$(pst w1 demo.prompt-2.md) $(pst w2 demo.prompt-2.md)"
eq_log "T7: --once --max-parallel 2: two log lines at exit" 2 "$(run_lines)"
if [ $((t1 - t0)) -le 4 ]; then ok "T7: --once --max-parallel 2 ran them at the same time"; else ko "T7: --once --max-parallel 2 ran them at the same time" "$((t1 - t0)) s"; fi
absent "T7: --once --max-parallel 2: no lock left" "$(plock w2)"

# T8: a bad --max-parallel is a usage error and starts nothing.
mkpws x0
pprompt x0 demo.prompt-1.md
pcfg x0
preset
for bad in 0 x; do
  "$watch" --once --max-parallel "$bad" >"$tmp/out" 2>"$tmp/stderr"
  eq "T8: --max-parallel $bad exits 1" 1 $?
  has "T8: --max-parallel $bad says why" "$tmp/stderr" "--max-parallel needs a whole number, 1 or more"
done
"$watch" --once --max-parallel >"$tmp/out" 2>"$tmp/stderr"
eq "T8: --max-parallel without a value exits 64" 64 $?
eq "T8: nothing started" pending "$(pst x0 demo.prompt-1.md)"
absent "T8: no runs/" "$par/x0/.chirat/runs"
absent "T8: no watcher.pid" "$XDG_STATE_HOME/chirat/watcher.pid"
eq_log "T8: nothing logged" 0 "$(wc -l <"$log" | tr -d ' ')"

# T9: restart is refused while any run is live; --force puts every run back
# and keeps the cap.
mkpws x1 x2
pprompt x1 demo.prompt-1.md 30; pprompt x2 demo.prompt-1.md 30
pcfg x1 x2
preset
: >"$FAKE_TMUX_LOG"
"$watch" --interval 1000 --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in x1 demo.prompt-1.md
wait_claude_in x2 demo.prompt-1.md
"$watch" restart >"$tmp/out2" 2>"$tmp/stderr2"
eq "T9: restart refused with two live runs" 1 $?
has "T9: refusal names the first run" "$tmp/stderr2" "x1/docs/plans/demo.prompt-1.md is running"
has "T9: refusal names the second run" "$tmp/stderr2" "x2/docs/plans/demo.prompt-1.md is running"
has "T9: refusal: --force wording for several" "$tmp/stderr2" "--force stops them and puts the prompts back to pending"
eq "T9: refusal stopped nothing" "running running" "$(pst x1 demo.prompt-1.md) $(pst x2 demo.prompt-1.md)"
FAKE_TMUX_RUN=0 "$watch" restart --force >"$tmp/out2" 2>"$tmp/stderr2"
eq "T9: restart --force exits 0" 0 $?
wait "$wpid"
eq "T9: old watcher exited 130" 130 $?
eq "T9: both prompts pending" "pending pending" "$(pst x1 demo.prompt-1.md) $(pst x2 demo.prompt-1.md)"
absent "T9: x1 lock gone" "$(plock x1)"
absent "T9: x2 lock gone" "$(plock x2)"
has "T9: new session keeps --max-parallel" "$FAKE_TMUX_LOG" "--max-parallel 2"

# T10: a 0.2.x lock (no runner.pid) is read, shown by status and recovered
# when stale.
mkpws y1
pprompt y1 demo.prompt-1.md
pcfg y1
preset
sleep 0.01 &
dead=$!
wait "$dead"
"$rp" set "$par/y1/docs/plans/demo.prompt-1.md" status running
mkdir "$(plock y1)"
echo $$ >"$(plock y1)/watcher.pid"
echo "$dead" >"$(plock y1)/claude.pid"
echo docs/plans/demo.prompt-1.md >"$(plock y1)/prompt"
"$watch" status >"$tmp/st.out" 2>&1
eq "T10: 0.2.x lock with a live watcher is not stale" 0 $?
has "T10: status says the watcher holds it" "$tmp/st.out" "lock: held by watcher $$ on docs/plans/demo.prompt-1.md"
"$watch" --once >/dev/null 2>"$tmp/stderr"
has "T10: pass skips it as in progress" "$tmp/stderr" "in progress, lock held by watcher $$"
eq "T10: prompt untouched" running "$(pst y1 demo.prompt-1.md)"
echo 999999 >"$(plock y1)/watcher.pid"
"$watch" status >"$tmp/st.out" 2>&1
eq "T10: 0.2.x lock with a dead watcher is stale" 1 $?
has "T10: status says claude dead" "$tmp/st.out" "lock: STALE: claude $dead dead on docs/plans/demo.prompt-1.md"
"$watch" --once >/dev/null 2>"$tmp/stderr"
has "T10: recovered" "$tmp/stderr" "recovered stale lock (claude $dead dead)"
eq "T10: then the prompt ran" "done" "$(pst y1 demo.prompt-1.md)"
eq "T10: recovered line first" recovered "$(head -n 1 "$log" | cut -f5)"

# T12: watcher alive, runner and claude group killed: the next pass recovers
# the lock and the workspace runs again.
mkpws z1
pprompt z1 demo.prompt-1.md 3
pcfg z1
preset
"$watch" --interval 1 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in z1 demo.prompt-1.md
rpid=$(cat "$(plock z1)/runner.pid") cpid=$(cat "$(plock z1)/claude.pid")
kill -9 "$rpid"
kill -9 -- "-$cpid"
gone "$rpid"
for _ in $(seq 1 50); do ps -o pgid= -A 2>/dev/null | tr -d ' ' | grep -qx "$cpid" || break; sleep 0.1; done
until_true 100 grep -q "	recovered	" "$log"
has "T12: the next pass logs recovered" "$log" "	recovered	"
has "T12: stderr says which claude" "$tmp/stderr" "recovered stale lock (claude $cpid dead)"
has "T12: status.log shows running → pending" "$par/z1/.chirat/status.log" "running	pending"
until_true 150 pst_is z1 demo.prompt-1.md "done"
eq "T12: the workspace ran again" "done" "$(pst z1 demo.prompt-1.md)"
until_true 100 runs_at_least 2 # recovered + run; the log line comes after the run-log commit
if [ "$(grep -n "	recovered	" "$log" | cut -d: -f1)" -lt "$(grep -n "	sonnet	0	" "$log" | head -n 1 | cut -d: -f1)" ]; then ok "T12: recovered line before the run line"; else ko "T12: recovered line before the run line" "$(cat "$log")"; fi
stop_watcher "$wpid"
absent "T12: lock gone" "$(plock z1)"

# T13: restart's KILL path — a watcher that does not react to TERM (stopped
# with SIGSTOP), two runs live: the runners are told to stop, so the prompts
# end pending, not failed, and the locks are gone.
mkpws k1 k2
pprompt k1 demo.prompt-1.md 30; pprompt k2 demo.prompt-1.md 30
pcfg k1 k2
preset
: >"$FAKE_TMUX_LOG"
"$watch" --interval 1000 --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in k1 demo.prompt-1.md
wait_claude_in k2 demo.prompt-1.md
r1=$(cat "$(plock k1)/runner.pid") r2=$(cat "$(plock k2)/runner.pid")
kill -STOP "$wpid"
# (exit code not checked: under the fake tmux no new watcher starts, so the
# killed watcher's pid file stays and the final watcher line reports it stale)
FAKE_TMUX_RUN=0 CHIRAT_STOP_GRACE=0 "$watch" restart --force >"$tmp/out2" 2>"$tmp/stderr2"
has "T13: the watcher had to be killed" "$tmp/stderr2" "did not stop within 10 s, sending KILL"
has "T13: k1's runner was stopped" "$tmp/stderr2" "$par/k1: stopped runner $r1; its prompt is pending again"
has "T13: k2's runner was stopped" "$tmp/stderr2" "$par/k2: stopped runner $r2; its prompt is pending again"
wait "$wpid" 2>/dev/null
eq "T13: prompts pending, not failed" "pending pending" "$(pst k1 demo.prompt-1.md) $(pst k2 demo.prompt-1.md)"
absent "T13: k1 lock gone" "$(plock k1)"
absent "T13: k2 lock gone" "$(plock k2)"
if kill -0 "$r1" 2>/dev/null || kill -0 "$r2" 2>/dev/null; then ko "T13: runners gone"; else ok "T13: runners gone"; fi
eq_log "T13: two interrupted log lines" 2 "$(grep -c "	interrupted	" "$log")"

# T14: a runner whose watcher is gone, with watcher.pid naming another
# process, sends no USR1 and still finishes its run.
mkpws n1
pprompt n1 demo.prompt-1.md 2
pcfg n1
preset
"$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in n1 demo.prompt-1.md
rpid=$(cat "$(plock n1)/runner.pid")
kill -9 "$wpid"
wait "$wpid" 2>/dev/null
rm -f "$tmp/usr1"
bash -c 'trap "echo USR1 >>$0" USR1; while :; do sleep 0.2; done' "$tmp/usr1" &
hpid=$!
echo "$hpid" >"$XDG_STATE_HOME/chirat/watcher.pid"
until_true 100 pst_is n1 demo.prompt-1.md "done"
eq "T14: the orphaned runner finished its run" "done" "$(pst n1 demo.prompt-1.md)"
gone "$rpid"
eq_log "T14: run logged" 1 "$(run_lines)"
absent "T14: lock gone" "$(plock n1)"
if kill -0 "$hpid" 2>/dev/null; then ok "T14: the process named by watcher.pid is still alive"; else ko "T14: the process named by watcher.pid is still alive"; fi
absent "T14: it received no USR1" "$tmp/usr1"
kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
rm -f "$XDG_STATE_HOME/chirat/watcher.pid"

# T15: a stop that arrives in the fork gap (CHIRAT_TEST_FORK_GAP widens it):
# the watcher records the runner before it stops, so the runner is stopped,
# its prompt is pending and no claude ran without a lock.
mkpws g15
pprompt g15 demo.prompt-1.md 30
pcfg g15
preset
rm -f "$tmp/locks"
FAKE_LOCKS=$tmp/locks CHIRAT_TEST_FORK_GAP=3 "$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in g15 demo.prompt-1.md
rpid=$(cat "$(plock g15)/runner.pid")
kill -TERM "$wpid"
wait "$wpid"
eq "T15: watcher exits 130" 130 $?
if gone "$rpid"; then ok "T15: the runner forked in the gap was stopped"; else ko "T15: the runner forked in the gap was stopped"; kill -9 "$rpid" 2>/dev/null; fi
eq "T15: its prompt is pending" pending "$(pst g15 demo.prompt-1.md)"
absent "T15: lock gone" "$(plock g15)"
has "T15: err notes the interruption" "$(first "$par"/g15/.chirat/runs/*.err)" "set to pending (SIGTERM)"
eq "T15: claude never ran without a lock" "lock" "$(sort -u "$tmp/locks" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
eq "T15: claude was stopped, not left to finish" 1 "$(wc -l <"$tmp/locks" | tr -d ' ')"
sleep 1
eq "T15: still pending a moment later" pending "$(pst g15 demo.prompt-1.md)"
# The other outcome: a runner stopped before its traps leaves a lock without
# runner.pid and with a dead watcher.pid; the next watcher recovers it.
pprompt g15 demo.prompt-1.md
mkdir -p "$(plock g15)"
sh -c 'exit 0' &
dead=$!
wait "$dead"
echo "$dead" >"$(plock g15)/watcher.pid"
echo docs/plans/demo.prompt-1.md >"$(plock g15)/prompt"
echo demo.prompt-1.20260101-000000 >"$(plock g15)/run"
echo 2026-01-01T00:00:00+0000 >"$(plock g15)/started"
preset
"$watch" --once >"$tmp/out" 2>"$tmp/stderr"
eq "T15: lock of a runner killed before its traps: --once exits 0" 0 $?
has "T15: it is recovered as stale" "$tmp/stderr" "g15: recovered stale lock ("
eq "T15: then its prompt ran" "done" "$(pst g15 demo.prompt-1.md)"
rm -f "$tmp/locks"

# T16: a live lock this watcher did not start uses the slot: under the default
# cap the other workspace is held (log, stdout, status name the foreign run)
# and starts once that lock is gone.
mkpws f1 f2
pprompt f1 demo.prompt-1.md; "$rp" set "$par/f1/docs/plans/demo.prompt-1.md" status running
pprompt f2 demo.prompt-1.md 1
pcfg f1 f2
preset
sleep 300 &
hpid=$!
foreign_lock f1 "$hpid" demo.prompt-1.md
"$watch" --interval 1 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
until_true 100 held_at_least f2 1
sleep 2.5
eq "T16: the other workspace is not started while the foreign lock is live" pending "$(pst f2 demo.prompt-1.md)"
eq_log "T16: f2 held once" 1 "$(held_lines f2)"
want=$(printf 'held\t%s/f2\tdocs/plans/demo.prompt-1.md\tlimit=1\trunning=f1' "$par")
case $(grep "	held	" "$log" | head -n 1) in *"$want") ok "T16: held line names the foreign run" ;; *) ko "T16: held line names the foreign run" "$(cat "$log")" ;; esac
has "T16: held line echoed to stdout" "$tmp/out" "running=f1"
"$watch" status f2 >"$tmp/st.out" 2>&1
has "T16: status names the foreign run" "$tmp/st.out" "  next: wait (1 pending; limit 1, running: f1)"
eq_log "T16: no run line yet" 0 "$(run_lines)"
rm -rf "$(plock f1)"
kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
until_true 100 runs_at_least 1
eq "T16: it starts after the foreign lock is gone" "done" "$(pst f2 demo.prompt-1.md)"
eq_log "T16: one run, in f2" f2 "$(run_ws_seq)"
eq "T16: the foreign workspace was left alone" running "$(pst f1 demo.prompt-1.md)"
stop_watcher "$wpid"

# T17: --once under the default cap, a foreign live lock that goes away after
# a few seconds: the hit waits for it, then runs, exit 0.
mkpws h1 h2
pprompt h1 demo.prompt-1.md; "$rp" set "$par/h1/docs/plans/demo.prompt-1.md" status running
pprompt h2 demo.prompt-1.md
pcfg h1 h2
preset
mkdir -p "$(plock h1)"
( sleep 3; rm -rf "$par/h1/.chirat/lock" ) &
hpid=$!
foreign_lock h1 "$hpid" demo.prompt-1.md
t0=$(date +%s)
"$watch" --once >"$tmp/out" 2>"$tmp/stderr"
rc=$?
t1=$(date +%s)
wait "$hpid" 2>/dev/null
eq "T17: --once exits 0" 0 "$rc"
eq "T17: the hit ran" "done" "$(pst h2 demo.prompt-1.md)"
if [ $((t1 - t0)) -ge 3 ]; then ok "T17: it waited for the foreign lock"; else ko "T17: it waited for the foreign lock" "$((t1 - t0)) s"; fi
if [ $((t1 - t0)) -le 10 ]; then ok "T17: and ran soon after it went"; else ko "T17: and ran soon after it went" "$((t1 - t0)) s"; fi
eq_log "T17: one run line" 1 "$(run_lines)"

# T18: --once --max-parallel 2, three workspaces, the first run long and the
# second short: the third starts when the second ends, not when the first does.
mkpws s1 s2 s3
pprompt s1 demo.prompt-1.md 8; pprompt s2 demo.prompt-1.md 1; pprompt s3 demo.prompt-1.md 1
pcfg s1 s2 s3
preset
"$watch" --once --max-parallel 2 >"$tmp/out" 2>"$tmp/stderr"
eq "T18: --once exits 0" 0 $?
eq "T18: all three done" "done done done" "$(pst s1 demo.prompt-1.md) $(pst s2 demo.prompt-1.md) $(pst s3 demo.prompt-1.md)"
eq_log "T18: the third finished before the first" "s2 s3 s1" "$(run_ws_seq)"

# T19: the release window. CHIRAT_TEST_RELEASE_GAP stretches the removal of the
# lock; readers all the way through it see a lock or none, never a stale one:
# `status` in the first run, whole passes of a second watcher in the next.
mkpws c1
pcfg c1
n=0
for reader in status --once; do
  n=$((n + 1))
  pprompt c1 "demo.prompt-$n.md" 1
  preset
  CHIRAT_TEST_RELEASE_GAP=1 "$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
  wpid=$!
  wait_claude_in c1 "demo.prompt-$n.md"
  rpid=$(cat "$(plock c1)/runner.pid")
  until_true 100 pst_is c1 "demo.prompt-$n.md" "done"
  polls=0 bad=""
  while [ -d "$(plock c1)" ] && [ "$polls" -lt 200 ]; do
    "$watch" "$reader" >"$tmp/st.out" 2>&1 || bad="$bad exit $?:"
    bad=$bad$(grep -e STALE -e recovered "$tmp/st.out")
    polls=$((polls + 1))
    [ "$reader" = status ] || sleep 0.2
  done
  gone "$rpid"
  if [ "$polls" -ge 3 ]; then ok "T19: $reader ran during the release"; else ko "T19: $reader ran during the release" "$polls times"; fi
  eq "T19: $reader: exits 0, nothing STALE, nothing recovered" "" "$bad"
  eq_log "T19: $reader: no recovered line" 0 "$(grep -c "	recovered	" "$log")"
  eq_log "T19: $reader: one run line" 1 "$(run_lines)"
  if grep -q recovered "$par/c1/.chirat/runs/demo.prompt-$n".*.err; then ko "T19: $reader: nothing in the run's .err" "$(cat "$par/c1/.chirat/runs/demo.prompt-$n".*.err)"; else ok "T19: $reader: nothing in the run's .err"; fi
  absent "T19: $reader: lock gone" "$(plock c1)"
  stop_watcher "$wpid"
done
# A release cut off after its first step: no lock for a reader, cleaned up by
# the next run.
preset
foreign_lock c1 "$rpid" demo.prompt-1.md
chmod +t "$(plock c1)"
"$watch" status >"$tmp/st.out" 2>&1
eq "T19: cut-off release: status exits 0" 0 $?
has "T19: cut-off release: no lock" "$tmp/st.out" "  lock: none"
"$watch" recover >"$tmp/out" 2>&1
has "T19: cut-off release: nothing to recover" "$tmp/out" "nothing to recover"
pprompt c1 demo.prompt-1.md
"$watch" --once >"$tmp/out" 2>"$tmp/stderr"
eq "T19: cut-off release: the next run takes the lock" "done" "$(pst c1 demo.prompt-1.md)"
eq_log "T19: cut-off release: one line, the run" 1 "$(grep -c "	sonnet	0	" "$log")"
eq_log "T19: cut-off release: no recovered line" 0 "$(grep -c "	recovered	" "$log")"
absent "T19: cut-off release: lock gone" "$(plock c1)"

# T20: the exit window. CHIRAT_TEST_READ_GAP stretches the time between reading
# the lock and the liveness checks; the run ends in between.
mkpws e1
pprompt e1 demo.prompt-1.md 2
pcfg e1
preset
"$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude_in e1 demo.prompt-1.md
rpid=$(cat "$(plock e1)/runner.pid")
CHIRAT_TEST_READ_GAP=6 "$watch" status >"$tmp/st.out" 2>&1 &
spid=$!
CHIRAT_TEST_READ_GAP=6 "$watch" --once >"$tmp/out2" 2>"$tmp/stderr2" &
opid=$!
gone "$rpid"
absent "T20: the run has released its lock" "$(plock e1)"
if kill -0 "$spid" 2>/dev/null && kill -0 "$opid" 2>/dev/null; then ok "T20: both readers are still between reads and checks"; else ko "T20: both readers are still between reads and checks"; fi
wait "$spid"
eq "T20: status exits 0" 0 $?
has "T20: status: no lock" "$tmp/st.out" "  lock: none"
wait "$opid"
eq "T20: --once exits 0" 0 $?
if grep -q recovered "$tmp/stderr2"; then ko "T20: the pass recovers nothing" "$(cat "$tmp/stderr2")"; else ok "T20: the pass recovers nothing"; fi
eq_log "T20: no recovered line" 0 "$(grep -c "	recovered	" "$log")"
eq_log "T20: one run line" 1 "$(run_lines)"
if grep -q recovered "$par"/e1/.chirat/runs/*.err; then ko "T20: nothing in the run's .err" "$(cat "$par"/e1/.chirat/runs/*.err)"; else ok "T20: nothing in the run's .err"; fi
stop_watcher "$wpid"

# T21: a stale lock replaced by a newer run while it is being classified: the
# newer run is neither recovered nor touched.
mkpws j1
pprompt j1 demo.prompt-1.md
"$rp" set "$par/j1/docs/plans/demo.prompt-1.md" status running
pcfg j1
preset
foreign_lock j1 "$dead" demo.prompt-1.md
echo "$dead" >"$(plock j1)/claude.pid"
CHIRAT_TEST_READ_GAP=3 "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
opid=$!
CHIRAT_TEST_READ_GAP=3 "$watch" status >"$tmp/st.out" 2>&1 &
spid=$!
sleep 1.5
sleep 300 &
hpid=$!
rm -rf "$(plock j1)"
foreign_lock j1 "$hpid" demo.prompt-1.md
echo demo.prompt-1.20260101-000001 >"$(plock j1)/run"
before=$(fs_snapshot "$(plock j1)")
wait "$spid"
eq "T21: status exits 0" 0 $?
has "T21: status names the newer run's runner" "$tmp/st.out" "lock: held by runner $hpid"
wait "$opid"
eq "T21: --once exits 0" 0 $?
has "T21: the pass leaves the newer run alone" "$tmp/stderr" "in progress, lock held by runner $hpid"
eq_log "T21: no recovered line" 0 "$(grep -c "	recovered	" "$log")"
eq "T21: the newer lock is untouched" "$before" "$(fs_snapshot "$(plock j1)")"
eq "T21: its prompt is untouched" running "$(pst j1 demo.prompt-1.md)"
absent "T21: nothing in its .err" "$par/j1/.chirat/runs/demo.prompt-1.20260101-000001.err"
kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
rm -rf "$(plock j1)"
unset CHIRAT_NOTIFY

# --- summary -------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
