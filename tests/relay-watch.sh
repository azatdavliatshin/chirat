#!/usr/bin/env bash
# Tests for bin/relay-watch with a fake `claude` on PATH and a throwaway
# workspace. Usage: tests/relay-watch.sh

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
watch=$root/bin/relay-watch
rp=$root/plugin/bin/relay-prompt

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
  if grep -qF -- "$3" "$2"; then ok "$1"; else ko "$1" "no [$3] in $2:"$'\n'"$(cat "$2")"; fi
}

exists() { # exists <name> <test flag> <path>
  if test "$2" "$3"; then ok "$1"; else ko "$1" "test $2 $3 is false"; fi
}

absent() { # absent <name> <path>
  if [ -e "$2" ]; then ko "$1" "$2 exists"; else ok "$1"; fi
}

first() { # first <glob...>: print the first existing match, or nothing
  for f in "$@"; do [ -e "$f" ] && { printf '%s\n' "$f"; return; }; done
  return 1
}

wait_claude() { # wait_claude <prompt file>: until it is running and the lock has claude.pid
  local _
  for _ in $(seq 1 100); do
    [ "$("$rp" get "$1" status)" = running ] && [ -s "$ws/docs/status/runs/.lock/claude.pid" ] && return 0
    sleep 0.1
  done
  return 1
}

gone() { # gone <pid>: wait up to 5 s until it no longer exists
  local _
  for _ in $(seq 1 50); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

# --- fake claude -----------------------------------------------------------
# Records argv (one per line) and $PWD, prints a JSON result, and acts on the
# prompt named after `-p "/relay:next <file>"` like the real /relay:next:
# claims it (`running`) and marks it `done`. FAKE_MODE=noflip stops after the
# claim; FAKE_MODE=noclaim touches nothing; FAKE_MODE=sleep claims and then
# sleeps 30 seconds; FAKE_MODE=hang claims and sleeps but prints nothing (the
# .json stays empty); FAKE_MODE=stubborn is sleep with TERM ignored. Exits with
# $FAKE_EXIT (default 0).

mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -u
{ printf '%s\n' "$@"; echo "PWD=$PWD"; } >"$FAKE_ARGV"
file=""
while [ $# -gt 0 ]; do
  case $1 in
    -p) file=${2#/relay:next }; shift 2 ;;
    *) shift ;;
  esac
done
mode=${FAKE_MODE:-done}
if [ "$mode" != hang ]; then
  echo '{"result":"ok"}'
  echo "fake claude stderr" >&2
fi
[ "$mode" = stubborn ] && trap '' TERM
if [ -n "$file" ] && [ "$mode" != noclaim ]; then
  "$RP" set "$file" status running
  case $mode in sleep | hang | stubborn) sleep 30 ;; esac
  case $mode in noflip | sleep | hang | stubborn) ;; *) "$RP" set "$file" status done ;; esac
fi
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$tmp/bin/claude"

# Fake osascript: records its arguments so the notification can be checked.
cat >"$tmp/bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_OSA"
EOF
chmod +x "$tmp/bin/osascript"
export PATH=$tmp/bin:$PATH RP=$rp FAKE_ARGV=$tmp/argv FAKE_OSA=$tmp/osa

# --- workspace + config ---------------------------------------------------

export HOME=$tmp XDG_CONFIG_HOME=$tmp/config XDG_STATE_HOME=$tmp/state
ws=$tmp/ws
mkdir -p "$ws"/docs/{plans,status} "$ws"/repos "$XDG_CONFIG_HOME/relay"
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
cat >"$XDG_CONFIG_HOME/relay/workspaces" <<EOF
# workspaces, one per line; ~ is expanded
~/ws/   # trailing slash and comment on purpose

$tmp/not-a-workspace
EOF
log=$XDG_STATE_HOME/relay/watch.log

# --- version / config -----------------------------------------------------

eq "--version" "relay-watch $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$root/plugin/.claude-plugin/plugin.json")" "$("$watch" --version)"
XDG_CONFIG_HOME=$tmp/nowhere "$watch" --once >/dev/null 2>"$tmp/stderr"
eq "missing config exits 1" 1 $?
has "missing config prints usage" "$tmp/stderr" "relay-watch [--once]"

# --- --dry-run ------------------------------------------------------------

out=$("$watch" --once --dry-run 2>"$tmp/stderr")
eq "dry-run exits 0" 0 $?
has "dry-run prints the claude command" <(printf '%s\n' "$out") "claude -p /relay:next\\ docs/plans/demo.prompt-1.md --model opus --permission-mode auto --permission-prompts none --output-format json"
eq "dry-run leaves the prompt pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-1.md" status)"
eq "dry-run runs nothing" "" "$(first "$ws"/docs/status/runs/*)"
exists "dry-run creates runs/" -d "$ws/docs/status/runs"
has "dry-run warns about a non-workspace path" "$tmp/stderr" "not a workspace (no docs/plans): $tmp/not-a-workspace"
absent "dry-run does not write LATEST" "$ws/docs/status/LATEST"
eq "dry-run logs one line" 1 "$(wc -l <"$log" | tr -d ' ')"
eq "log: mode column shows auto" auto "$(cut -f7 "$log")"
: >"$log"

# --- permission mode: default auto, flag > env > default -------------------

mode_of() { # mode_of <env value or -> <flag args...>; prints the mode in the dry-run command
  local env=$1; shift
  if [ "$env" = - ]; then
    "$watch" --once --dry-run "$@" 2>/dev/null | grep -o -e '--permission-mode [^ ]*'
  else
    RELAY_PERMISSION_MODE=$env "$watch" --once --dry-run "$@" 2>/dev/null | grep -o -e '--permission-mode [^ ]*'
  fi
}
eq "mode: default is auto" "--permission-mode auto" "$(mode_of -)"
eq "mode: flag overrides default" "--permission-mode acceptEdits" "$(mode_of - --permission-mode acceptEdits)"
eq "mode: env overrides default" "--permission-mode plan" "$(mode_of plan)"
eq "mode: flag beats env" "--permission-mode acceptEdits" "$(mode_of plan --permission-mode acceptEdits)"
"$watch" --once --dry-run --permission-mode >/dev/null 2>&1
eq "mode: flag without value exits 64" 64 $?
: >"$log"

# --- --once: happy path ---------------------------------------------------

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git -C "$ws" init -q
git -C "$ws" add docs/plans
git -C "$ws" commit -q -m "docs: plans"
rm -rf "$ws/docs/status/runs"

out=$("$watch" --once 2>"$tmp/stderr")
eq "once exits 0" 0 $?
json=$(first "$ws"/docs/status/runs/demo.prompt-1.*.json)
err=${json%.json}.err
exists "writes runs/<stem>.<ts>.json" -f "$json"
case ${json##*/} in demo.prompt-1.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].json) ok "timestamp is YYYYMMDD-HHMMSS" ;; *) ko "timestamp is YYYYMMDD-HHMMSS" "$json" ;; esac
eq "json holds claude's stdout" '{"result":"ok"}' "$(cat "$json")"
eq "err holds claude's stderr" "fake claude stderr" "$(cat "$err")"
eq "runs the lower-numbered prompt" "/relay:next docs/plans/demo.prompt-1.md" "$(sed -n '/^-p$/{n;p;}' "$FAKE_ARGV")"
eq "passes the prompt's model" opus "$(sed -n '/^--model$/{n;p;}' "$FAKE_ARGV")"
eq "passes --permission-mode auto by default" auto "$(sed -n '/^--permission-mode$/{n;p;}' "$FAKE_ARGV")"
has "passes --permission-prompts none" "$FAKE_ARGV" "--permission-prompts"
has "passes --output-format json" "$FAKE_ARGV" "--output-format"
eq "runs from the workspace root" "PWD=$ws" "$(grep '^PWD=' "$FAKE_ARGV")"
eq "prompt-1 is done afterwards" "done" "$("$rp" get "$ws/docs/plans/demo.prompt-1.md" status)"
eq "prompt-2 is still pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-2.md" status)"
absent "lock released" "$ws/docs/status/runs/.lock"
eq "run log commit message" "docs: run log demo.prompt-1" "$(git -C "$ws" log -1 --format=%s)"
eq "run log commit holds runs/ files, status.log and LATEST" "docs/status/LATEST
docs/status/runs/${err##*/}
docs/status/runs/${json##*/}
docs/status/runs/status.log" "$(git -C "$ws" show --name-only --format= HEAD | sort)"
eq "LATEST: no pending changes" "" "$(git -C "$ws" status --porcelain -- docs/status/LATEST)"
eq "LATEST: one line after the first run" 1 "$(wc -l <"$ws/docs/status/LATEST" | tr -d ' ')"
IFS=$'\t' read -r a_ts a_stem a_status a_branch a_commit a_exit a_secs <"$ws/docs/status/LATEST"
case $a_ts in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ok "LATEST: iso timestamp" ;; *) ko "LATEST: iso timestamp" "$a_ts" ;; esac
eq "LATEST: stem" demo.prompt-1 "$a_stem"
eq "LATEST: status" "done" "$a_status"
eq "LATEST: branch" feat/x "$a_branch"
eq "LATEST: no repo → commit -" - "$a_commit"
eq "LATEST: exit" 0 "$a_exit"
case $a_secs in '' | *[!0-9]*) ko "LATEST: seconds" "$a_secs" ;; *) ok "LATEST: seconds" ;; esac
eq "run log: no pending runs/ changes" "" "$(git -C "$ws" status --porcelain -- docs/status/runs)"
eq "one log line" 1 "$(wc -l <"$log" | tr -d ' ')"
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
has "notification carries the final status" "$FAKE_OSA" 'title "relay: done"'
rm -f "$FAKE_OSA"

# --- --once: claude exits without flipping the status ---------------------

RELAY_NOTIFY=0 FAKE_MODE=noflip FAKE_EXIT=3 "$watch" --once >"$tmp/out" 2>"$tmp/stderr"
eq "once still exits 0 when claude fails" 0 $?
absent "RELAY_NOTIFY=0 sends nothing" "$FAKE_OSA"
eq "prompt-2 set to failed" failed "$("$rp" get "$ws/docs/plans/demo.prompt-2.md" status)"
err2=$(first "$ws"/docs/status/runs/demo.prompt-2.*.err)
has "err notes the forced failure" "$err2" "claude exited 3 with the prompt still 'running'; set to failed"
has "err keeps claude's own stderr first" "$err2" "fake claude stderr"
eq "LATEST: second run appends a line" 2 "$(wc -l <"$ws/docs/status/LATEST" | tr -d ' ')"
eq "LATEST: forced failure recorded" "demo.prompt-2	failed	feat/x	-	3" "$(tail -n 1 "$ws/docs/status/LATEST" | cut -f2-6)"
eq "LATEST: first line untouched" demo.prompt-1 "$(head -n 1 "$ws/docs/status/LATEST" | cut -f2)"
eq "log: exit code 3" 3 "$(tail -n 1 "$log" | cut -f5)"
eq "log: model sonnet by default" sonnet "$(tail -n 1 "$log" | cut -f4)"
absent "lock released after failure" "$ws/docs/status/runs/.lock"

# --- --once: claude exits before claiming the prompt ----------------------

prompt demo.prompt-3.md sonnet pending
FAKE_MODE=noclaim FAKE_EXIT=1 "$watch" --once >/dev/null 2>&1
eq "unclaimed prompt set to failed (no retry loop)" failed "$("$rp" get "$ws/docs/plans/demo.prompt-3.md" status)"
err3=$(first "$ws"/docs/status/runs/demo.prompt-3.*.err)
has "err notes the prompt was still pending" "$err3" "claude exited 1 with the prompt still 'pending'; set to failed"
rm -f "$ws/docs/plans/demo.prompt-3.md"

# --- --once: nothing pending ----------------------------------------------

out=$("$watch" --once 2>/dev/null)
eq "once with empty queue exits 0" 0 $?
eq "once with empty queue prints nothing" "" "$out"
eq "once with empty queue logs nothing" 3 "$(wc -l <"$log" | tr -d ' ')"

# --- lock held → skip -----------------------------------------------------

"$rp" set "$ws/docs/plans/demo.prompt-2.md" status pending
mkdir "$ws/docs/status/runs/.lock"
echo $$ >"$ws/docs/status/runs/.lock/watcher.pid" # a live owner: this shell
: >"$FAKE_ARGV"
"$watch" --once >/dev/null 2>"$tmp/stderr"
eq "locked workspace: exit 0" 0 $?
has "locked workspace: says so on stderr" "$tmp/stderr" "in progress, lock held by watcher $$"
eq "locked workspace: claude not called" "" "$(cat "$FAKE_ARGV")"
eq "locked workspace: prompt stays pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-2.md" status)"
exists "locked workspace: lock left alone" -d "$ws/docs/status/runs/.lock"
rm -f "$ws/docs/status/runs/.lock/watcher.pid"
rmdir "$ws/docs/status/runs/.lock"

# --- model missing → sonnet; --interval validation -----------------------

prompt demo.prompt-3.md "" pending
sed -i.bak '/^model:/d' "$ws/docs/plans/demo.prompt-3.md" && rm -f "$ws/docs/plans/demo.prompt-3.md.bak"
"$watch" --once >/dev/null 2>&1
eq "runs prompt-2 before prompt-3" "/relay:next docs/plans/demo.prompt-2.md" "$(sed -n '/^-p$/{n;p;}' "$FAKE_ARGV")"
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
lock=$ws/docs/status/runs/.lock
wait_claude "$ws/docs/plans/demo.prompt-9.md"
eq "sleeping run has claimed the prompt" running "$("$rp" get "$ws/docs/plans/demo.prompt-9.md" status)"
cpid=$(cat "$lock/claude.pid" 2>/dev/null)
for f in watcher.pid prompt run started claude.pid; do exists "lock holds $f" -s "$lock/$f"; done
eq "lock: watcher.pid is the watcher" "$wpid" "$(cat "$lock/watcher.pid")"
eq "lock: prompt" docs/plans/demo.prompt-9.md "$(cat "$lock/prompt")"
case $(cat "$lock/run") in demo.prompt-9.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ok "lock: run is <stem>.<stamp>" ;; *) ko "lock: run is <stem>.<stamp>" "$(cat "$lock/run")" ;; esac
exists "lock: run names the .err of this run" -e "$ws/docs/status/runs/$(cat "$lock/run").err"
case $(cat "$lock/started") in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ok "lock: started is iso" ;; *) ko "lock: started is iso" "$(cat "$lock/started")" ;; esac
has "lock: claude.pid is the fake claude" <(ps -o args= -p "$cpid") "bin/claude -p"
kill -TERM "$wpid"
wait "$wpid"
eq "SIGTERM: watcher exits 130" 130 $?
eq "SIGTERM: prompt back to pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-9.md" status)"
err9=$(first "$ws"/docs/status/runs/demo.prompt-9.*.err)
has "SIGTERM: err notes the interruption" "$err9" "relay-watch was interrupted with the prompt still 'running'; set to pending (SIGTERM)"
eq "SIGTERM: one more log line" $((lines_before + 1)) "$(wc -l <"$log" | tr -d ' ')"
eq "SIGTERM: LATEST records interrupted" "demo.prompt-9	pending	feat/x	-	interrupted" "$(tail -n 1 "$ws/docs/status/LATEST" | cut -f2-6)"
eq "SIGTERM: LATEST committed" "" "$(git -C "$ws" status --porcelain -- docs/status/LATEST)"
eq "SIGTERM: log exit column is interrupted" interrupted "$(tail -n 1 "$log" | cut -f5)"
eq "SIGTERM: log names the prompt" docs/plans/demo.prompt-9.md "$(tail -n 1 "$log" | cut -f3)"
absent "SIGTERM: lock released" "$ws/docs/status/runs/.lock"
if kill -0 "$cpid" 2>/dev/null; then ko "SIGTERM: claude is gone"; else ok "SIGTERM: claude is gone"; fi
rm -f "$ws/docs/plans/demo.prompt-9.md"

# --- lock owners, stale locks, stopping claude -----------------------------

runs=$ws/docs/status/runs
pf=$ws/docs/plans/demo.prompt-20.md

# A dead watcher and a dead claude leave the prompt `running` and the lock.
# recover <FAKE_MODE>: start, kill both with -9, leave wpid/cpid/err/json set.
die_mid_run() {
  FAKE_MODE=$1 "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
  wpid=$!
  wait_claude "$pf"
  cpid=$(cat "$runs/.lock/claude.pid")
  run=$(cat "$runs/.lock/run")
  kill -9 "$wpid"
  kill -9 "$cpid"
  wait "$wpid" 2>/dev/null
  gone "$cpid"
}

prompt demo.prompt-20.md sonnet pending
: >"$log"
rm -f "$runs/status.log"
die_mid_run hang
eq "dead run: prompt still running" running "$("$rp" get "$pf" status)"
exists "dead run: lock left behind" -d "$runs/.lock"
exists "dead run: .json is empty" -f "$runs/$run.json"
"$watch" --once >"$tmp/out" 2>"$tmp/stderr"
has "heal: stderr says so" "$tmp/stderr" "recovered stale lock (claude $cpid dead)"
has "heal: err holds the note" "$runs/$run.err" "recovered: watcher/claude died with the prompt 'running'; set to pending"
absent "heal: empty .json removed" "$runs/$run.json"
absent "heal: lock gone" "$runs/.lock"
eq "heal: first log line is recovered" recovered "$(head -n 1 "$log" | cut -f5)"
eq "heal: log names the prompt" docs/plans/demo.prompt-20.md "$(head -n 1 "$log" | cut -f3)"
eq "heal: then the prompt ran again" "done" "$("$rp" get "$pf" status)"
eq "heal: two log lines (recovered, run)" 2 "$(wc -l <"$log" | tr -d ' ')"
eq "status.log: pending → running, running → pending (recovery), pending → running, running → done" \
  "pending	running
running	pending
pending	running
running	done" "$(cut -f3,4 "$runs/status.log" | sed -n '1,4p;')"
eq "status.log: recovery's parent is relay-watch" relay-watch "$(sed -n 2p "$runs/status.log" | cut -f7)"
eq "status.log: claude's parent is the fake claude" claude "$(sed -n 4p "$runs/status.log" | cut -f7)"
eq "status.log: file column" docs/plans/demo.prompt-20.md "$(sed -n 1p "$runs/status.log" | cut -f2)"
before=$(wc -l <"$runs/status.log" | tr -d ' ')
"$rp" set "$pf" model opus
eq "status.log: other keys add nothing" "$before" "$(wc -l <"$runs/status.log" | tr -d ' ')"

# A non-empty .json survives recovery.
"$rp" set "$pf" status pending
die_mid_run sleep
"$watch" --once >/dev/null 2>&1
exists "heal: non-empty .json kept" -s "$runs/$run.json"
has "heal: note in err" "$runs/$run.err" "recovered:"
eq "heal (sleep): prompt ran again" "done" "$("$rp" get "$pf" status)"

# Legacy lock: an empty directory and a running prompt.
"$rp" set "$pf" status running
mkdir "$runs/.lock"
rm -f "$runs"/demo.prompt-20.*.err
: >"$log"
"$watch" --once >/dev/null 2>&1
eq "legacy lock: prompt ran again after recovery" "done" "$("$rp" get "$pf" status)"
absent "legacy lock: lock gone" "$runs/.lock"
has "legacy lock: fresh err has the note" "$(first "$runs"/demo.prompt-20.*.err)" "recovered: watcher/claude died with the prompt 'running'; set to pending"
eq "legacy lock: recovered line logged" recovered "$(head -n 1 "$log" | cut -f5)"
eq "legacy lock: log names the prompt" docs/plans/demo.prompt-20.md "$(head -n 1 "$log" | cut -f3)"

# Legacy lock, nothing running: just removed, file column -.
mkdir "$runs/.lock"
: >"$log"
"$watch" --once >/dev/null 2>&1
absent "legacy lock without running prompt: lock gone" "$runs/.lock"
eq "legacy lock without running prompt: file column -" - "$(head -n 1 "$log" | cut -f3)"

# A live lock is respected, even when the prompt reads pending (not retried).
"$rp" set "$pf" status pending
FAKE_MODE="sleep" "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
cpid=$(cat "$runs/.lock/claude.pid")
"$rp" set "$pf" status pending
: >"$FAKE_ARGV"
"$watch" --once >"$tmp/out2" 2>"$tmp/stderr2"
has "live lock: says in progress" "$tmp/stderr2" "in progress, lock held by claude $cpid (docs/plans/demo.prompt-20.md)"
eq "live lock: prompt not retried" pending "$("$rp" get "$pf" status)"
eq "live lock: claude not started again" "" "$(cat "$FAKE_ARGV")"
exists "live lock: lock still there" -d "$runs/.lock"
kill -TERM "$wpid"
wait "$wpid"
eq "live lock: first watcher still exits 130 on TERM" 130 $?
if kill -0 "$cpid" 2>/dev/null; then ko "live lock: claude gone after TERM"; else ok "live lock: claude gone after TERM"; fi
absent "live lock: lock released after TERM" "$runs/.lock"

# SIGHUP behaves like SIGTERM.
"$rp" set "$pf" status pending
FAKE_MODE="sleep" "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
cpid=$(cat "$runs/.lock/claude.pid")
kill -HUP "$wpid"
wait "$wpid"
eq "SIGHUP: watcher exits 130" 130 $?
eq "SIGHUP: prompt back to pending" pending "$("$rp" get "$pf" status)"
absent "SIGHUP: lock released" "$runs/.lock"
if kill -0 "$cpid" 2>/dev/null; then ko "SIGHUP: claude is gone"; else ok "SIGHUP: claude is gone"; fi
has "SIGHUP: err names the signal" "$(find "$runs" -name 'demo.prompt-20.*.err' -print | sort | tail -n 1)" "(SIGHUP)"

# A claude that ignores TERM is killed after the grace period.
FAKE_MODE=stubborn RELAY_STOP_GRACE=2 "$watch" --once >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
cpid=$(cat "$runs/.lock/claude.pid")
t0=$(date +%s)
kill -TERM "$wpid"
wait "$wpid"
eq "stubborn: watcher exits 130" 130 $?
if [ $(($(date +%s) - t0)) -le 20 ]; then ok "stubborn: stopped within 20 s"; else ko "stubborn: stopped within 20 s"; fi
if kill -0 "$cpid" 2>/dev/null; then ko "stubborn: claude PID gone (KILL)"; else ok "stubborn: claude PID gone (KILL)"; fi
eq "stubborn: prompt pending" pending "$("$rp" get "$pf" status)"
absent "stubborn: lock released" "$runs/.lock"
rm -f "$pf"

# --dry-run takes and releases the lock.
prompt demo.prompt-21.md sonnet pending
"$watch" --once --dry-run >/dev/null 2>&1
absent "dry-run: lock absent afterwards" "$runs/.lock"
rm -f "$ws/docs/plans/demo.prompt-21.md"

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
eq "waiting line logged" $((lines_before + 1)) "$(wc -l <"$log" | tr -d ' ')"
out=$("$watch" --once 2>/dev/null)
eq "waiting line not repeated within 10 minutes" "" "$out"
eq "waiting prompt stays pending, claude not run" pending "$("$rp" get "$ws/docs/plans/demo.prompt-5.md" status)"
git -C "$wr" merge -q --no-edit dep
"$watch" --once >/dev/null 2>&1
eq "merged dependency: prompt runs" "done" "$("$rp" get "$ws/docs/plans/demo.prompt-5.md" status)"

lines=$(wc -l <"$ws/docs/status/LATEST" | tr -d ' ')
git -C "$wr" branch feat/x
want=$(git -C "$wr" rev-parse --short feat/x)
prompt demo.prompt-6.md sonnet pending
"$watch" --once >/dev/null 2>&1
eq "LATEST: commit is the short hash of the branch" "$want" "$(tail -n 1 "$ws/docs/status/LATEST" | cut -f5)"
eq "LATEST: one line per run, none for waiting/misnamed" $((lines + 1)) "$(wc -l <"$ws/docs/status/LATEST" | tr -d ' ')"
rm -f "$ws/docs/plans/demo.prompt-6.md"

# --- misnamed pending file, logged once ----------------------------------------

prompt demo.prompt-x.md sonnet pending
lines_before=$(wc -l <"$log" | tr -d ' ')
out=$("$watch" --once 2>/dev/null)
want=$(printf 'misnamed\t%s\tdocs/plans/demo.prompt-x.md\tname does not match <topic>.prompt-<N><suffix>.md' "$ws")
case $out in *"$want") ok "misnamed line printed" ;; *) ko "misnamed line printed" "$out" ;; esac
eq "misnamed line logged" $((lines_before + 1)) "$(wc -l <"$log" | tr -d ' ')"
out=$("$watch" --once 2>/dev/null)
eq "misnamed line not repeated" "" "$out"
rm -f "$ws/docs/plans/demo.prompt-x.md"

# --- install ----------------------------------------------------------------

inst=$tmp/inst/bin
"$watch" install "$inst" >"$tmp/out" 2>"$tmp/stderr"
eq "install exits 0" 0 $?
eq "install links relay-watch" "$watch" "$(readlink "$inst/relay-watch")"
eq "install links relay-prompt" "$rp" "$(readlink "$inst/relay-prompt")"
has "install hints at PATH when needed" "$tmp/out" "is not on PATH"
"$watch" install "$inst" >"$tmp/out" 2>&1
eq "install is repeatable" 0 $?
eq "installed symlink finds the plugin" "$("$watch" --version)" "$("$inst/relay-watch" --version)"
PATH=$inst:$PATH "$watch" install "$inst" >"$tmp/out" 2>&1
if grep -qF "not on PATH" "$tmp/out"; then ko "no PATH hint when dir is on PATH"; else ok "no PATH hint when dir is on PATH"; fi
rm "$inst/relay-prompt"
echo "mine" >"$inst/relay-prompt"
"$watch" install "$inst" >"$tmp/out" 2>"$tmp/stderr"
eq "install refuses to overwrite a regular file" 1 $?
has "install says why" "$tmp/stderr" "not a symlink"
eq "install left the regular file alone" mine "$(cat "$inst/relay-prompt")"

# --- status / recover / restart ------------------------------------------------

# Fake tmux: has-session succeeds for names in $FAKE_TMUX_SESSIONS, new-session
# records and (unless FAKE_TMUX_RUN=0) runs its command in the background,
# list-panes prints $FAKE_TMUX_PANE_PID, a session killed (and logged) is gone, everything is appended to $FAKE_TMUX_LOG.
cat >"$tmp/bin/tmux" <<'EOT'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_TMUX_LOG"
case $1 in
  has-session)
    ! grep -qxF "kill-session -t ${3}" "$FAKE_TMUX_LOG" || exit 1 # killed since it was listed
    for s in ${FAKE_TMUX_SESSIONS:-}; do [ "$s" = "${3#=}" ] && exit 0; done
    exit 1 ;;
  new-session)
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
runs=$ws/docs/status/runs
mkdir -p "$ws"/docs/{plans,status} "$ws"/repos
printf '%s\n' "$ws" >"$XDG_CONFIG_HOME/relay/workspaces"
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
rm -f "$XDG_STATE_HOME"/relay/watcher.*

st() { "$watch" status "$@" >"$tmp/st.out" 2>"$tmp/st.err"; return $?; }

st
eq "status: clean workspace exits 0" 0 $?
has "status: no watcher" "$tmp/st.out" "watcher: not running"
has "status: tmux session absent" "$tmp/st.out" "tmux: session 'relay' absent"
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
FAKE_TMUX_SESSIONS=relay st
eq "status: session without watcher is stale" 1 $?
has "status: says so" "$tmp/st.out" "STALE: tmux: session 'relay' present but no live watcher"

# A watcher and its claude killed with -9.
: >"$log"
die_mid_run hang
st
eq "status: dead run exits 1" 1 $?
has "status: stale lock" "$tmp/st.out" "STALE: claude $cpid dead on docs/plans/demo.prompt-1.md"
has "status: dead watcher" "$tmp/st.out" "watcher: dead (stale pid file, pid $wpid)"
snap() { find "$ws" "$XDG_STATE_HOME" -type f -exec cksum {} + | sort; ls -A "$runs/.lock"; }
before=$(snap)
"$watch" recover --dry-run >"$tmp/out" 2>"$tmp/stderr"
eq "recover --dry-run exits 0" 0 $?
has "dry-run: would set pending" "$tmp/out" "would set docs/plans/demo.prompt-1.md pending"
has "dry-run: would remove the empty json" "$tmp/out" "would remove empty $runs/$run.json"
has "dry-run: would remove the lock" "$tmp/out" "would remove lock $runs/.lock"
eq "dry-run: nothing changed" "$before" "$(snap)"
eq "dry-run: prompt still running" running "$("$rp" get "$pf" status)"
"$watch" recover >"$tmp/out" 2>"$tmp/stderr"
eq "recover exits 0" 0 $?
has "recover: stderr line" "$tmp/stderr" "recovered stale lock (claude $cpid dead)"
has "recover: err note" "$runs/$run.err" "recovered: watcher/claude died with the prompt 'running'; set to pending"
eq "recover: prompt pending" pending "$("$rp" get "$pf" status)"
absent "recover: lock gone" "$runs/.lock"
absent "recover: empty json gone" "$runs/$run.json"
eq "recover: logged" recovered "$(head -n 1 "$log" | cut -f5)"
"$watch" recover >"$tmp/out" 2>&1
eq "recover with nothing to do exits 0" 0 $?
has "recover: says so" "$tmp/out" "nothing to recover"
rm -f "$XDG_STATE_HOME"/relay/watcher.*

# A live watcher with a dead claude is between claude's exit and release_lock.
mkdir "$runs/.lock"
echo $$ >"$runs/.lock/watcher.pid"
echo "$cpid" >"$runs/.lock/claude.pid"
echo docs/plans/demo.prompt-1.md >"$runs/.lock/prompt"
echo "$run" >"$runs/.lock/run"
date +%Y-%m-%dT%H:%M:%S%z >"$runs/.lock/started"
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
rm -f "$runs/.lock"/*
rmdir "$runs/.lock"

# running prompt without a lock
st
eq "status: running prompt without lock exits 1" 1 $?
has "status: says so" "$tmp/st.out" "STALE: docs/plans/demo.prompt-1.md is running but there is no lock"
"$rp" set "$pf" status pending

# live run
: >"$FAKE_TMUX_LOG"
env FAKE_MODE=sleep "$watch" --interval 1000 >"$tmp/out" 2>"$tmp/stderr" &
wpid=$!
wait_claude "$pf"
eq "watcher.pid while running" "$wpid" "$(cat "$XDG_STATE_HOME/relay/watcher.pid")"
eq "watcher.flags while running" "--interval
1000" "$(cat "$XDG_STATE_HOME/relay/watcher.flags")"
st
eq "status: live run exits 0" 0 $?
has "status: watcher alive with flags" "$tmp/st.out" "watcher: alive (pid $wpid, flags: --interval 1000)"
has "status: claude alive since" "$tmp/st.out" "alive since"
has "status: running prompt listed" "$tmp/st.out" "1 running (demo.prompt-1)"
cpid=$(cat "$runs/.lock/claude.pid")
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
absent "watcher.pid gone after exit" "$XDG_STATE_HOME/relay/watcher.pid"
absent "watcher.flags gone after exit" "$XDG_STATE_HOME/relay/watcher.flags"
has "restart --force: new session with the original flags" "$FAKE_TMUX_LOG" "--interval 1000"
has "restart --force: new-session" "$FAKE_TMUX_LOG" "new-session -d -s relay"

# restart with no watcher starts one (nothing pending, so it idles)
"$rp" set "$pf" status "done"
"$rp" set "$ws/docs/plans/demo.prompt-2.md" status "done"
: >"$FAKE_TMUX_LOG"
"$watch" restart >"$tmp/out" 2>"$tmp/stderr"
eq "restart without a watcher exits 0" 0 $?
has "restart: says no watcher" "$tmp/out" "no watcher running"
has "restart: prints the new watcher line" "$tmp/out" "watcher: alive (pid "
wpid=$(cat "$XDG_STATE_HOME/relay/watcher.pid")
exists "new watcher wrote watcher.flags" -e "$XDG_STATE_HOME/relay/watcher.flags"
eq "no flags: empty watcher.flags" "" "$(cat "$XDG_STATE_HOME/relay/watcher.flags")"
kill -TERM "$wpid"
gone "$wpid"
absent "watcher.pid gone after TERM" "$XDG_STATE_HOME/relay/watcher.pid"
absent "watcher.flags gone after TERM" "$XDG_STATE_HOME/relay/watcher.flags"

# no pid file: the pane of the tmux session is the fallback; the session is killed
sleep 100 &
spid=$!
: >"$FAKE_TMUX_LOG"
FAKE_TMUX_SESSIONS=relay FAKE_TMUX_PANE_PID=$spid FAKE_TMUX_RUN=0 "$watch" restart >"$tmp/out" 2>"$tmp/stderr"
eq "restart via pane pid exits 0" 0 $?
wait "$spid" 2>/dev/null
if kill -0 "$spid" 2>/dev/null; then ko "restart: pane process stopped"; else ok "restart: pane process stopped"; fi
has "restart: leftover session killed" "$FAKE_TMUX_LOG" "kill-session -t =relay"
has "restart: new session started" "$FAKE_TMUX_LOG" "new-session -d -s relay"

# --once leaves nothing behind
"$watch" --once >/dev/null 2>&1
absent "--once leaves no watcher.pid" "$XDG_STATE_HOME/relay/watcher.pid"
ws=$tmp/ws

# --- summary -------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
