#!/usr/bin/env bash
# PreToolUse guard for Bash (the "commit guard"). Two rules, applied to every
# simple command in the Bash call, not just the first:
#
# 1. Push and publish are the human's step: `git push` in any form (`git -C x
#    push`, `cd x && git push`, `a; git push`, `git -c k=v push`, `$(git push)`,
#    `env A=1 git push`, `/usr/bin/git push`, ...) and `npm publish`,
#    `pnpm publish`, `yarn publish`, `yarn npm publish` are refused.
# 2. `git commit` is refused while workspace files are staged in the repo it
#    would commit to (the dir from `-C`, an earlier `cd`, or the hook's cwd).
#
# Reads the hook JSON on stdin. Exit 0 lets the call through; exit 2 blocks it
# and the message on stderr is shown to Claude.
#
# How the command is read: it is split into simple commands on `&&`, `||`,
# `;`, `|`, `&`, newlines, `(`, `)`, `$(` and backticks, so the insides of
# command substitutions and subshells are scanned as well (flatly). Quotes
# are not parsed: a separator inside a quoted string splits too, which errs
# on the side of checking more (`git commit -m "a; git push"` is refused).
# Each simple command loses leading `VAR=value` assignments and the wrappers
# `command`, `env`, `exec`, `sudo`, `nohup`, `time`, `nice`, `timeout`,
# `xargs`, `eval`, `sh -c` / `bash -c` / `zsh -c`; a `cd <dir>` anywhere in
# the chain sets the dir for the git calls after it. For `git`, global options
# (`-C`, `-c`, `--git-dir`, `--work-tree`, `--namespace`, ...) are walked to
# find the subcommand, so `git stash push` and `git log --grep push` pass.
#
# Without jq or python3 the command cannot be read: the commit check is
# skipped (fails open), but anything that looks like `git ... push` or
# `npm/pnpm/yarn ... publish` in the raw input is refused (fails closed).
#
# Refused staged paths:
#   - any `.claude/` or `.planning/` directory
#   - in a code repo, anything under `.chirat/` (chirat's own state belongs to
#     the workspace); in a workspace repo only `.chirat/lock/` is refused, the
#     rest of `.chirat/` (runs, LATEST, status.log, config) is the run log
#   - `*.local.md`, `settings.local.json`, `.DS_Store`
#   - workspace planning files: `docs/**/*.prompt-*.md`, `docs/WORKFLOW.md`,
#     `docs/PARKED.md`, `docs/scope/BASELINE_*.md` (a repo may carry its own
#     `docs/`; only these workspace-shaped names are refused). Skipped in a
#     workspace repo — one whose HEAD contains `docs/WORKFLOW.md` — where those
#     files are the content.

set -uo pipefail

input=$(cat)

push_msg="chirat: git push is the human's step — commit on the branch and stop; the human reviews, merges and pushes."
publish_msg="chirat: publishing is the human's step — commit on the branch and stop; the human reviews, merges and publishes."

if command -v jq >/dev/null 2>&1; then
  parser=jq
elif command -v python3 >/dev/null 2>&1; then
  parser=python3
else
  # Fail closed for push/publish, open for the commit check.
  w='[^[:alnum:]_.-]'
  if grep -Eq "(^|$w)git($w.*)?$w""push($w|\$)" <<<"$input"; then
    echo "$push_msg (No jq or python3 to read the command, so any text like 'git ... push' is refused; this may be a false positive.)" >&2
    exit 2
  fi
  if grep -Eq "(^|$w)(npm|pnpm|yarn)($w.*)?$w""publish($w|\$)" <<<"$input"; then
    echo "$publish_msg (No jq or python3 to read the command, so any text like 'npm ... publish' is refused; this may be a false positive.)" >&2
    exit 2
  fi
  echo "guard-commit: neither jq nor python3 found; commit guard skipped" >&2
  exit 0
fi

json_field() {
  if [ "$parser" = jq ]; then
    jq -r "$1 // empty" <<<"$input"
  else
    python3 -c '
import json, sys
d = json.loads(sys.argv[2])
for k in sys.argv[1].lstrip(".").split("."):
    d = d.get(k) if isinstance(d, dict) else None
print(d if isinstance(d, str) else "")
' "$1" "$input"
  fi
}

command=$(json_field .tool_input.command)
cur=$(json_field .cwd)
[ -n "$cur" ] || cur=$PWD

# resolve <base> <dir>: print <dir> made absolute against <base>.
resolve() {
  local d=$2
  # shellcheck disable=SC2088 # a literal ~ to expand by hand
  case $d in "~") d=$HOME ;; "~/"*) d=$HOME/${d#"~/"} ;; esac
  case $d in /*) printf '%s' "$d" ;; *) printf '%s' "$1/$d" ;; esac
}

# Split into simple commands, one per line.
s=$command
# shellcheck disable=SC2016 # literal separators
for sep in '$(' '`' '(' ')' '&&' '||' ';' '|' '&'; do
  s=${s//"$sep"/$'\n'}
done

commit_dirs=()
while IFS= read -r seg; do
  read -ra raw <<<"$seg"
  words=()
  for word in ${raw[@]+"${raw[@]}"}; do
    word=${word//\"/}
    word=${word//\'/}
    words+=("$word")
  done
  n=${#words[@]}
  i=0

  # Drop assignments, redirections, shell keywords and wrappers.
  while [ "$i" -lt "$n" ]; do
    w0=${words[i]}
    case $w0 in
      [A-Za-z_]*=* | [0-9]\>* | [0-9]\<* | \>* | \<* | \{ | \} | \! | if | then | else | elif | do | while | until)
        i=$((i + 1)) ;;
      command | exec | nohup | eval | time | xargs | nice | env | sudo | timeout | sh | bash | zsh | dash | */sh | */bash | */zsh)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "$w0 ${words[i]}" in
            # Wrapper options that take a value.
            "env -u" | "env -C" | "env -P" | "nice -n" | "timeout -s" | "timeout -k" | \
              "sudo -u" | "sudo -g" | "sudo -U" | "sudo -C" | "sudo -D" | "sudo -h" | \
              "sudo -p" | "sudo -r" | "sudo -t" | "sudo -T" | "xargs -I" | "xargs -L" | \
              "xargs -n" | "xargs -P" | "xargs -s" | "xargs -d" | "xargs -E" | "xargs -a")
              i=$((i + 2)) ;;
            *" -"* | *" "[A-Za-z_]*=*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        # timeout's first operand is the duration.
        [ "$w0" = timeout ] && i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || continue

  argv0=${words[i]}
  i=$((i + 1))
  case $argv0 in
    cd)
      if [ "$i" -lt "$n" ]; then
        [ "${words[i]}" = - ] || cur=$(resolve "$cur" "${words[i]}")
      else
        cur=$HOME
      fi ;;
    git | */git)
      dir=$cur
      sub=
      while [ "$i" -lt "$n" ]; do
        case ${words[i]} in
          -C) [ $((i + 1)) -lt "$n" ] && dir=$(resolve "$dir" "${words[i + 1]}"); i=$((i + 2)) ;;
          -c | --git-dir | --work-tree | --namespace | --config-env | --super-prefix) i=$((i + 2)) ;;
          -*) i=$((i + 1)) ;;
          *) sub=${words[i]}; break ;;
        esac
      done
      case $sub in
        push) echo "$push_msg" >&2; exit 2 ;;
        commit) commit_dirs+=("$dir") ;;
      esac ;;
    npm | pnpm | yarn | */npm | */pnpm | */yarn)
      sub=
      prev=
      while [ "$i" -lt "$n" ]; do
        case ${words[i]} in
          -*) prev=${words[i]}; i=$((i + 1)) ;;
          *) sub=${words[i]}; break ;;
        esac
      done
      # `yarn npm publish`, and `npm --tag next publish` where the first
      # non-option word is really the value of a `--long` option.
      if { [ "$sub" = npm ] && [ "${argv0##*/}" = yarn ]; } ||
        { case $prev in --*=*) false ;; --?*) true ;; *) false ;; esac; }; then
        [ "${words[i + 1]:-}" = publish ] && sub=publish
      fi
      if [ "$sub" = publish ]; then
        echo "$publish_msg" >&2
        exit 2
      fi ;;
  esac
done <<<"$s"

[ ${#commit_dirs[@]} -gt 0 ] || exit 0

# check_commit <dir>: print the refused staged paths of the repo at <dir>.
check_commit() {
  local top staged workspace_repo path base
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  staged=$(git -C "$top" diff --cached --name-only 2>/dev/null) || return 0
  [ -n "$staged" ] || return 0

  # The marker must already be in HEAD (or, in a repo with no commits yet, on
  # disk), so staging a WORKFLOW.md does not make a code repo a workspace.
  workspace_repo=0
  if git -C "$top" rev-parse --verify -q HEAD >/dev/null; then
    git -C "$top" cat-file -e HEAD:docs/WORKFLOW.md 2>/dev/null && workspace_repo=1
  elif [ -f "$top/docs/WORKFLOW.md" ]; then
    workspace_repo=1
  fi

  local bad=()
  while IFS= read -r path; do
    base=${path##*/}
    case "/$path/" in
      */.claude/* | */.planning/*) bad+=("$path"); continue ;;
    esac
    case $base in
      *.local.md | settings.local.json | .DS_Store) bad+=("$path"); continue ;;
    esac
    case "/$path" in
      */.chirat/lock/*) bad+=("$path"); continue ;;
      */.chirat/*) [ "$workspace_repo" = 1 ] || { bad+=("$path"); continue; } ;;
    esac
    [ "$workspace_repo" = 1 ] && continue
    case $path in
      docs/*.prompt-*.md | docs/WORKFLOW.md | docs/PARKED.md | docs/scope/BASELINE_*.md)
        bad+=("$path"); continue ;;
    esac
  done <<<"$staged"

  [ ${#bad[@]} -eq 0 ] && return 0
  echo "Commit refused: workspace files are staged in $top:"
  printf '  %s\n' "${bad[@]}"
  echo "Unstage them (git restore --staged <path>) and keep them out of the repo."
}

refused=
for d in "${commit_dirs[@]}"; do
  out=$(check_commit "$d")
  case $refused in *"$out"*) ;; *) refused=$refused$out ;; esac
done

[ -n "$refused" ] || exit 0
printf '%s\n' "$refused" >&2
exit 2
