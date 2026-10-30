#!/usr/bin/env bash
# Differential test for hooks/guard-commit.sh: the guard against a real shell.
#
# Every line of guard-corpus.txt is (1) given to the guard as the hook input
# and (2) run, as the same text, by a real bash from the same directory, with
# PATH shimmed so that `git`, `npm`, `pnpm` and `yarn` only record where they
# were called (cwd, GIT_DIR, GIT_WORK_TREE, arguments) and exit 0, while
# `cd` / `pushd` / loops / functions / traps are real. From the record, the
# repository each `git commit` would have hit is resolved with the real git.
#
# Only the soundness direction is asserted: whenever the real run would
# commit in a dirty repository, or push or publish anywhere, the guard must
# have refused. A refusal of something the real run shows as harmless is
# counted and printed as "conservative", never failed. Lines marked `allow`
# must pass the guard (the explicit allow-list); lines marked `harm` must be
# seen as harmful by the real run (a self-check of the fixture).
#
# Corpus line: `<cwd> <expect> <command>`; `#` comments and blank lines are
# skipped. <cwd> is one of outer mid inner clean dirty cleansp dirtysp home
# fx; <expect> is `-`, `allow` or `harm`; in <command>, `<NL>` is a newline
# and @OUTER@ @MID@ @INNER@ @CLEAN@ @DIRTY@ @CLEANSP@ @DIRTYSP@ @HOME@ @FX@
# @GIT@ are the fixture paths (`@GIT@` is the shim). Commands must be safe to
# run with the shim: no network, nothing written outside TMPDIR.
#
# Usage: plugin/tests/guard-corpus.sh [corpus-file]; runs under the bash that
# invokes it (Bash 3.2 included), which is also the bash the lines run in.

set -uo pipefail
unset CDPATH

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(dirname "$here")
guard=$plugin/hooks/guard-commit.sh
corpus=${1:-$here/guard-corpus.txt}

fx=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$fx"' EXIT

fail=0
ko() { fail=$((fail + 1)); echo "FAIL corpus: $1"; [ $# -gt 1 ] && echo "     $2"; }

# --- fixture ------------------------------------------------------------------
# Three nested repos (outer dirty, mid and inner clean), a clean and a dirty
# repo, the same two at paths with spaces, a dirty HOME, a dir that is no repo.

mkrepo() { # mkrepo <path> <clean|dirty>
  git init -q -b main "$1"
  echo "code" >"$1/main.sh"
  git -C "$1" add main.sh
  git -C "$1" -c user.name=t -c user.email=t@t commit -q -m init
  echo "more" >>"$1/main.sh"
  git -C "$1" add main.sh
  if [ "$2" = dirty ]; then
    mkdir -p "$1/.claude"
    echo "{}" >"$1/.claude/settings.local.json"
    git -C "$1" add -f .claude/settings.local.json
  fi
}
outer=$fx/nest/outer mid=$fx/nest/outer/mid inner=$fx/nest/outer/mid/inner
clean=$fx/clean dirty=$fx/dirty cleansp="$fx/clean dir" dirtysp="$fx/dirty dir" home=$fx/home
mkrepo "$outer" dirty
mkrepo "$mid" clean
mkrepo "$inner" clean
mkrepo "$clean" clean
mkrepo "$dirty" dirty
mkrepo "$cleansp" clean
mkrepo "$dirtysp" dirty
mkrepo "$home" dirty
mkdir -p "$fx/tmp" "$fx/plain"
printf 'cd "%s"\n' "$dirty" >"$fx/cd-dirty.sh"

# The git dirs that count as dirty, resolved the same way the records are.
gitdir_of() { git -C "$1" rev-parse --absolute-git-dir 2>/dev/null; }
dirty_dirs=$(gitdir_of "$outer")$'\n'$(gitdir_of "$dirty")$'\n'$(gitdir_of "$dirtysp")$'\n'$(gitdir_of "$home")

# --- shims ----------------------------------------------------------------------
shim=$fx/shim
mkdir -p "$shim"
log=$fx/calls.log
# One record per call, NUL-separated: pwd, GIT_DIR, GIT_WORK_TREE, argc, tool, args…
for t in git npm pnpm yarn; do
  cat >"$shim/$t" <<'EOF'
#!/bin/bash
printf '%s\0' "$PWD" "${GIT_DIR-}" "${GIT_WORK_TREE-}" "$(($# + 1))" "${0##*/}" "$@" >>"$CORPUS_LOG"
exit 0
EOF
done
printf '#!/bin/bash\nexit 0\n' >"$shim/npx"
# sudo and timeout run the rest of their arguments here; bash is the harness's bash.
cat >"$shim/sudo" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case $1 in
    -u | -g | -U | -C | -D | -h | -p | -r | -t | -T) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
EOF
cat >"$shim/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case $1 in -s | -k) shift 2 ;; -*) shift ;; *) break ;; esac
done
shift # the duration
exec "$@"
EOF
# shellcheck disable=SC2016 # the shim's own $CORPUS_BASH and $@
printf '#!/bin/bash\nexec "$CORPUS_BASH" "$@"\n' >"$shim/bash"
chmod +x "$shim"/*

# --- the two runs -----------------------------------------------------------------

json_escape() { # json_escape <text>: the text as the inside of a JSON string
  local c=$1
  c=${c//\\/\\\\}
  c=${c//\"/\\\"}
  c=${c//$'\n'/\\n}
  c=${c//$'\t'/\\t}
  c=${c//$'\r'/\\r}
  printf '%s' "$c"
}

guard_rc() { # guard_rc <cwd> <command>: the guard's exit code
  local json
  json=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' \
    "$(json_escape "$1")" "$(json_escape "$2")")
  HOME=$home "$BASH" "$guard" <<<"$json" >/dev/null 2>"$fx/guard.err"
  echo $?
}

real_run() { # real_run <cwd> <command>: run it, 5 s at most; the log fills
  : >"$log"
  (
    cd "$1" && exec env PATH="$shim:$PATH" HOME="$home" TMPDIR="$fx/tmp" OLDPWD="$dirty" \
      CORPUS_LOG="$log" CORPUS_BASH="$BASH" GIT_PAGER=cat "$BASH" -c "$2"
  ) </dev/null >/dev/null 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid" 2>/dev/null
  return 0
}

# resolve_record <pwd> <GIT_DIR> <GIT_WORK_TREE> <tool> <args…>: prints
# `push`, `publish`, `commit <absolute git dir>` or nothing.
resolve_record() {
  local pwd=$1 gd=$2 wt=$3 tool=$4 sub="" a
  shift 4
  local -a opts=() e=(env)
  case $tool in
    npm | pnpm | yarn)
      for a in "$@"; do [ "$a" = publish ] && { echo publish; return 0; }; done
      return 0 ;;
  esac
  # git's global options, up to the subcommand
  while [ $# -gt 0 ]; do
    a=$1
    case $a in
      -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env | --exec-path | --attr-source)
        [ $# -ge 2 ] || return 0
        opts+=("$a" "$2"); shift 2 ;;
      -*) opts+=("$a"); shift ;;
      *) sub=$a; break ;;
    esac
  done
  case $sub in
    push) echo push ;;
    commit)
      [ -z "$gd" ] || e+=("GIT_DIR=$gd")
      [ -z "$wt" ] || e+=("GIT_WORK_TREE=$wt")
      a=$("${e[@]}" GIT_PAGER=cat git -C "$pwd" ${opts[@]+"${opts[@]}"} rev-parse --absolute-git-dir 2>/dev/null)
      echo "commit ${a:-none}" ;;
  esac
}

# harm_of_log: prints the harmful effects the recorded calls would have had
harm_of_log() {
  local pwd gd wt argc tool a i hit
  local -a args
  while IFS= read -r -d '' pwd && IFS= read -r -d '' gd && IFS= read -r -d '' wt && IFS= read -r -d '' argc; do
    args=() i=0
    while [ "$i" -lt "$argc" ]; do IFS= read -r -d '' a || break; args+=("$a"); i=$((i + 1)); done
    tool=${args[0]}
    hit=$(resolve_record "$pwd" "$gd" "$wt" "${args[@]}")
    case $hit in
      push | publish) echo "$hit" ;;
      "commit "*)
        case $'\n'$dirty_dirs$'\n' in *$'\n'"${hit#commit }"$'\n'*) echo "commit in dirty ${hit#commit }" ;; esac ;;
    esac
  done <"$log"
}

# --- the corpus -------------------------------------------------------------------

lines=0 refused=0 allowed=0 harmful=0 conservative=0
while IFS= read -r line || [ -n "$line" ]; do
  case $line in '' | '#'*) continue ;; esac
  cwdname=${line%%[[:space:]]*}
  rest=${line#"$cwdname"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  expect=${rest%%[[:space:]]*}
  cmd=${rest#"$expect"}
  cmd=${cmd#"${cmd%%[![:space:]]*}"}
  case $cwdname in
    outer) cwd=$outer ;; mid) cwd=$mid ;; inner) cwd=$inner ;; clean) cwd=$clean ;; dirty) cwd=$dirty ;;
    cleansp) cwd=$cleansp ;; dirtysp) cwd=$dirtysp ;; home) cwd=$home ;; fx) cwd=$fx ;;
    *) ko "unknown cwd '$cwdname' in: $line"; continue ;;
  esac
  case $expect in - | allow | harm) ;; *) ko "unknown expectation '$expect' in: $line"; continue ;; esac
  cmd=${cmd//<NL>/$'\n'}
  cmd=${cmd//@OUTER@/$outer}; cmd=${cmd//@MID@/$mid}; cmd=${cmd//@INNER@/$inner}
  cmd=${cmd//@CLEAN@/$clean}; cmd=${cmd//@DIRTY@/$dirty}
  cmd=${cmd//@CLEANSP@/$cleansp}; cmd=${cmd//@DIRTYSP@/$dirtysp}
  cmd=${cmd//@HOME@/$home}; cmd=${cmd//@FX@/$fx}; cmd=${cmd//@GIT@/$shim/git}
  lines=$((lines + 1))
  show="$cwdname: ${cmd//$'\n'/<NL>}"

  rc=$(guard_rc "$cwd" "$cmd")
  case $rc in
    0) allowed=$((allowed + 1)) ;;
    2) refused=$((refused + 1)) ;;
    *) ko "guard exited $rc on: $show" "$(cat "$fx/guard.err")"; continue ;;
  esac

  if ! real_run "$cwd" "$cmd"; then
    ko "the real run timed out on: $show"
    continue
  fi
  harm=$(harm_of_log)

  if [ -n "$harm" ]; then
    harmful=$((harmful + 1))
    if [ "$rc" != 2 ]; then
      ko "UNSOUND — the real run would ${harm//$'\n'/; } but the guard allowed: $show"
    fi
  elif [ "$rc" = 2 ]; then
    conservative=$((conservative + 1))
    echo "conservative: $show"
  fi
  case $expect in
    allow) [ "$rc" = 0 ] || ko "false refusal on an allow-list line: $show" "$(cat "$fx/guard.err")" ;;
    harm) [ -n "$harm" ] || ko "expected harm, the real run showed none (fixture or corpus bug): $show" ;;
  esac
done <"$corpus"

echo "corpus: $lines lines, $refused refused, $allowed allowed; $harmful harmful (all refused), $conservative conservative; bash ${BASH_VERSION%%(*}"
[ "$lines" -ge 80 ] || ko "corpus has $lines lines, fewer than 80"
[ "$fail" -eq 0 ] || echo "corpus: $fail failures"
[ "$fail" -eq 0 ]
