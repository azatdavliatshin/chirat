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

# --- fake claude -----------------------------------------------------------
# Records argv (one per line) and $PWD, prints a JSON result, and acts on the
# prompt named after `-p "/relay:next <file>"` like the real /relay:next:
# claims it (`running`) and marks it `done`. FAKE_MODE=noflip stops after the
# claim; FAKE_MODE=noclaim touches nothing; FAKE_MODE=sleep claims and then
# sleeps 30 seconds. Exits with $FAKE_EXIT (default 0).

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
echo '{"result":"ok"}'
echo "fake claude stderr" >&2
mode=${FAKE_MODE:-done}
if [ -n "$file" ] && [ "$mode" != noclaim ]; then
  "$RP" set "$file" status running
  [ "$mode" = sleep ] && sleep 30
  [ "$mode" = noflip ] || [ "$mode" = sleep ] || "$RP" set "$file" status done
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
eq "run log commit holds only runs/ files" "docs/status/runs/${err##*/}
docs/status/runs/${json##*/}" "$(git -C "$ws" show --name-only --format= HEAD | sort)"
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
: >"$FAKE_ARGV"
"$watch" --once >/dev/null 2>"$tmp/stderr"
eq "locked workspace: exit 0" 0 $?
has "locked workspace: says so on stderr" "$tmp/stderr" "is locked"
eq "locked workspace: claude not called" "" "$(cat "$FAKE_ARGV")"
eq "locked workspace: prompt stays pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-2.md" status)"
exists "locked workspace: lock left alone" -d "$ws/docs/status/runs/.lock"
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
for _ in $(seq 1 100); do
  [ "$("$rp" get "$ws/docs/plans/demo.prompt-9.md" status)" = running ] && break
  sleep 0.1
done
eq "sleeping run has claimed the prompt" running "$("$rp" get "$ws/docs/plans/demo.prompt-9.md" status)"
kill -TERM "$wpid"
wait "$wpid"
eq "SIGTERM: watcher exits 130" 130 $?
eq "SIGTERM: prompt back to pending" pending "$("$rp" get "$ws/docs/plans/demo.prompt-9.md" status)"
err9=$(first "$ws"/docs/status/runs/demo.prompt-9.*.err)
has "SIGTERM: err notes the interruption" "$err9" "relay-watch was interrupted with the prompt still 'running'; set to pending"
eq "SIGTERM: one more log line" $((lines_before + 1)) "$(wc -l <"$log" | tr -d ' ')"
eq "SIGTERM: log exit column is interrupted" interrupted "$(tail -n 1 "$log" | cut -f5)"
eq "SIGTERM: log names the prompt" docs/plans/demo.prompt-9.md "$(tail -n 1 "$log" | cut -f3)"
absent "SIGTERM: lock released" "$ws/docs/status/runs/.lock"
rm -f "$ws/docs/plans/demo.prompt-9.md"

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

# --- summary -------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
