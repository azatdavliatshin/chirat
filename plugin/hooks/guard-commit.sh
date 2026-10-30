#!/usr/bin/env bash
# PreToolUse guard for Bash (the "commit guard"). Two rules, applied to every
# simple command in the Bash call, not just the first:
#
# 1. Push and publish are the human's step: `git push` in any form (`git -C x
#    push`, `cd x && git push`, `a; git push`, `git -c k=v push`, `$(git push)`,
#    `env A=1 git push`, `/usr/bin/git push`, ...) and `npm publish`,
#    `pnpm publish`, `yarn publish`, `yarn npm publish` are refused.
# 2. `git commit` is refused while workspace files are staged in the repo it
#    would commit to (the dir from `-C`, `--git-dir` / `--work-tree` (also as
#    `GIT_DIR` / `GIT_WORK_TREE`), an earlier `cd` / `pushd` / `env -C`, or
#    the hook's cwd).
#
# Reads the hook JSON on stdin. Exit 0 lets the call through; exit 2 blocks it
# and the message on stderr is shown to Claude.
#
# How the command is read: a small shell-word lexer (below) splits it the way
# the shell would — `"…"`, `'…'`, `\x`, `$'…'` and comments are understood, so
# a quoted path with spaces or `&`/`;` is one word and `git commit -m "a; git
# push"` is a commit, not a push. Operators (`&&`, `||`, `;`, `|`, `&`,
# newlines, `(`, `)`) separate simple commands; `$(…)`, backticks, `${x:-$(…)}`,
# `bash -c '…'` / `eval '…'` bodies and the bodies of here-documents with an
# unquoted delimiter are scanned too, each as its own command scope. Every
# double-quoted region, wherever it appears (a word, the value in `${…}`, a
# heredoc body, a `-c` body), is scanned for `$(…)`, backticks and `${…}`
# — `"${x:-"$(git push)"}"` is a push; only `'…'` is literal. Nothing is ever
# expanded, evaluated or executed: `$VAR`, `${…}`, `$(…)`, backticks, globs
# and `~user` leave a word *unresolved*. Each simple command loses leading
# `VAR=value` assignments and the wrappers `command`, `env`, `exec`, `sudo`,
# `nohup`, `time`, `nice`, `timeout`, `xargs`; for `git`, global options are
# walked to find the subcommand, so `git stash push` and `git log --grep push`
# pass.
#
# The current directory is a SET of candidates, not one value — do not "fix"
# this back to a single cwd. A top-level `cd X` makes the set {X}; a `cd` in a
# pipeline, in `( … )` or in a `-c` body changes nothing outside; a `cd` under
# if/while/until/for/case or behind `&&`/`||` ADDS X to the set, except that
# `cd X && git commit` sees exactly {X}; `cd -`, `popd`, `cd "$VAR"` make the
# set unknown. A commit is checked against every candidate; one dirty or
# unknown candidate refuses it.
#
# A `bash -c` / `sh -c` / `eval` body inherits the context in force at the
# call: the directory set (from `cd`, `env -C`) and `GIT_DIR` /
# `GIT_WORK_TREE` from prefix assignments or `env VAR=…`. A `cd` inside a
# `-c` body stays in the body; inside `eval` it reaches the caller.
#
# Fail closed: when the hook cannot tell which repository a commit targets —
# an unresolved `-C` / `--git-dir` / `--work-tree` value, a `cd` to an
# unresolved dir (or `cd -`, `popd`), a literal path that is not a git
# repository — or cannot tell what a git command does (unresolved
# subcommand), or cannot parse the command at all (unbalanced quotes,
# unterminated `$(`), it refuses with a one-line reason. A false refusal
# costs a retry; a false pass breaks the promise.
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
#
# Bash 3.2 compatible (macOS /bin/bash): no `${var,,}`, no associative arrays.

# shellcheck disable=SC1003,SC2016,SC2059,SC2295 # a lexer: literal quote
# characters, pattern stop sets built from variables, escape decoding
set -uo pipefail

input=$(cat)

push_msg="chirat: git push is the human's step — commit on the branch and stop; the human reviews, merges and pushes."
publish_msg="chirat: publishing is the human's step — commit on the branch and stop; the human reviews, merges and publishes."
unres_msg="chirat: cannot tell which repository this commits to; run git from the repository directory"

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

refuse() { # refuse <message>
  echo "$1" >&2
  exit 2
}

# --- lexer -------------------------------------------------------------------
# Tokens go to the parallel arrays TOK (text) and TYP (kind):
#   w   word                 u   word with an unresolved part
#   ;   command separator    (   )   subshell / group
#   [   ]   a scanned sub-text: `$(…)`, backticks, a heredoc body
# Globals while lexing: s (text), pos, n (length), the word being built
# (word, wu = unresolved, inword = a word is open, even if empty), lex_err,
# and the here-documents announced on the current line (hd_*).

TOK=() TYP=()
s="" pos=0 n=0 word="" wu=0 inword=0 lex_err=""
hd_delim=() hd_quoted=() hd_strip=()
uspecial=$'\\\\"\'$`();|&<*?[~ \t\n' # ends a run of plain characters, unquoted
dspecial=$'\\\\"$`'                  # inside "…"

emit_word() {
  [ "$inword" = 1 ] || return 0
  TOK+=("$word")
  if [ "$wu" = 1 ]; then TYP+=(u); else TYP+=(w); fi
  word="" wu=0 inword=0
}

emit_op() { # emit_op <kind>
  emit_word
  TOK+=("$1")
  TYP+=("$1")
}

# lex_until <stop>: lex from pos; with stop `)`, return after the unquoted
# `)` that closes the enclosing `$(`; with an empty stop, lex to the end.
lex_until() {
  local stop=$1 depth=0 c nx rest plain
  while [ "$pos" -lt "$n" ]; do
    c=${s:pos:1}
    case $c in
      ' ' | $'\t') emit_word; pos=$((pos + 1)) ;;
      $'\n') emit_op ';'; pos=$((pos + 1)); read_heredocs || return 1 ;;
      '#')
        if [ "$inword" = 1 ]; then
          word=$word#; pos=$((pos + 1))
        else
          rest=${s:pos}; plain=${rest%%$'\n'*}; pos=$((pos + ${#plain}))
        fi ;;
      '\')
        nx=${s:pos+1:1}
        if [ $((pos + 1)) -ge "$n" ]; then word=$word\\; pos=$((pos + 1)); inword=1
        elif [ "$nx" = $'\n' ]; then pos=$((pos + 2))
        else word=$word$nx; pos=$((pos + 2)); inword=1; fi ;;
      "'")
        rest=${s:pos+1}; plain=${rest%%\'*}
        if [ ${#plain} -eq ${#rest} ]; then lex_err="unbalanced single quote"; return 1; fi
        word=$word$plain; pos=$((pos + 2 + ${#plain})); inword=1 ;;
      '"') pos=$((pos + 1)); lex_dquote || return 1 ;;
      '$') lex_dollar u || return 1 ;;
      '`') lex_backtick || return 1 ;;
      '(') emit_op '('; depth=$((depth + 1)); pos=$((pos + 1)) ;;
      ')')
        if [ -n "$stop" ] && [ "$depth" -eq 0 ]; then pos=$((pos + 1)); emit_word; return 0; fi
        emit_op ')'; [ "$depth" -gt 0 ] && depth=$((depth - 1)); pos=$((pos + 1)) ;;
      ';')
        case ${s:pos+1:1} in
          ';') pos=$((pos + 2)); [ "${s:pos:1}" = '&' ] && pos=$((pos + 1)); emit_op ';;' ;;
          '&') pos=$((pos + 2)); emit_op ';;' ;;
          *) emit_op ';'; pos=$((pos + 1)) ;;
        esac ;;
      '|')
        if [ "${s:pos+1:1}" = '|' ]; then emit_op '||'; pos=$((pos + 2))
        else emit_op '|'; pos=$((pos + 1)); [ "${s:pos:1}" = '&' ] && pos=$((pos + 1)); fi ;;
      '&')
        nx=${s:pos+1:1}
        if [ "$nx" = '&' ]; then emit_op '&&'; pos=$((pos + 2))
        elif [ "$nx" = '>' ]; then word=$word\&; pos=$((pos + 1)); inword=1
        else
          case $inword$word in 1*'>' | 1*'<') word=$word\&; pos=$((pos + 1)) ;; *) emit_op ';'; pos=$((pos + 1)) ;; esac
        fi ;;
      '<')
        case ${s:pos+1:2} in
          '<<') word=$word'<<<'; pos=$((pos + 3)); inword=1 ;;
          '<'*) emit_word; pos=$((pos + 2)); heredoc_delim || return 1 ;;
          *) word=$word\<; pos=$((pos + 1)); inword=1 ;;
        esac ;;
      '*' | '?' | '[') word=$word$c; wu=1; inword=1; pos=$((pos + 1)) ;;
      '~')
        if [ "$inword" = 0 ]; then
          case ${s:pos+1:1} in '' | '/' | ' ' | $'\t' | $'\n' | ';' | '&' | '|' | ')' | '<' | '>') ;; *) wu=1 ;; esac
        fi
        word=$word\~; inword=1; pos=$((pos + 1)) ;;
      *)
        rest=${s:pos}; plain=${rest%%[$uspecial]*}
        if [ -z "$plain" ]; then word=$word$c; pos=$((pos + 1)); else word=$word$plain; pos=$((pos + ${#plain})); fi
        inword=1 ;;
    esac
  done
  if [ -n "$stop" ]; then lex_err="unterminated command substitution"; return 1; fi
  emit_word
  return 0
}

# lex_dquote: inside "…", pos just past the opening quote
lex_dquote() {
  local c nx rest plain
  inword=1
  while [ "$pos" -lt "$n" ]; do
    c=${s:pos:1}
    case $c in
      '"') pos=$((pos + 1)); return 0 ;;
      '\')
        nx=${s:pos+1:1}
        case $nx in
          '$' | '`' | '"' | '\') word=$word$nx; pos=$((pos + 2)) ;;
          $'\n') pos=$((pos + 2)) ;;
          *) word=$word\\; pos=$((pos + 1)) ;;
        esac ;;
      '$') lex_dollar d || return 1 ;;
      '`') lex_backtick || return 1 ;;
      *)
        rest=${s:pos}; plain=${rest%%[$dspecial]*}
        if [ -z "$plain" ]; then word=$word$c; pos=$((pos + 1)); else word=$word$plain; pos=$((pos + ${#plain})); fi ;;
    esac
  done
  lex_err="unbalanced double quote"
  return 1
}

# lex_dollar <u|d>: at a `$`, unquoted (u) or inside "…" (d)
lex_dollar() {
  local nx=${s:pos+1:1}
  case $nx in
    '(') pos=$((pos + 2)); lex_sub ')' || return 1 ;;
    '{') pos=$((pos + 2)); lex_brace || return 1 ;;
    "'")
      if [ "$1" = u ]; then pos=$((pos + 2)); lex_ansi || return 1
      else word=$word\$; pos=$((pos + 1)); inword=1; fi ;;
    '"')
      if [ "$1" = u ]; then pos=$((pos + 1))
      else word=$word\$; pos=$((pos + 1)); inword=1; fi ;;
    [A-Za-z_])
      pos=$((pos + 2))
      while :; do case ${s:pos:1} in [A-Za-z0-9_]) pos=$((pos + 1)) ;; *) break ;; esac; done
      word=$word'$…'; wu=1; inword=1 ;;
    [0-9@*#?!$-]) pos=$((pos + 2)); word=$word'$…'; wu=1; inword=1 ;;
    *) word=$word\$; pos=$((pos + 1)); inword=1 ;;
  esac
}

# lex_sub <stop>: `$(` was consumed; scan the substitution as its own scope,
# then go on with the word that contains it (now unresolved).
lex_sub() {
  local sw=$word swu=$wu sin=$inword
  word="" wu=0 inword=0
  TOK+=('['); TYP+=('[')
  lex_until "$1" || return 1
  TOK+=(']'); TYP+=(']')
  word=$sw'$(…)' wu=1 inword=1
}

# lex_brace: `${` was consumed; skip to the matching `}`, scanning any `$(…)`,
# backticks or nested `${…}` inside (`${x:-$(git push)}`). A double-quoted
# region in the value (`${x:-"$(git push)"}`) is scanned the same way, through
# lex_dollar: quotes never make a substitution opaque, only `'…'` does.
lex_brace() {
  local depth=1 c
  while [ "$pos" -lt "$n" ] && [ "$depth" -gt 0 ]; do
    c=${s:pos:1}
    case $c in
      '{') depth=$((depth + 1)); pos=$((pos + 1)) ;;
      '}') depth=$((depth - 1)); pos=$((pos + 1)) ;;
      '\') pos=$((pos + 2)) ;;
      '$')
        case ${s:pos+1:1} in
          '(') pos=$((pos + 2)); lex_sub ')' || return 1 ;;
          '{') pos=$((pos + 2)); lex_brace || return 1 ;;
          *) pos=$((pos + 1)) ;;
        esac ;;
      '`') lex_backtick || return 1 ;;
      '"')
        pos=$((pos + 1))
        while [ "$pos" -lt "$n" ]; do
          c=${s:pos:1}
          case $c in
            '"') break ;;
            '\') pos=$((pos + 2)) ;;
            '$') lex_dollar d || return 1 ;;
            '`') lex_backtick || return 1 ;;
            *) pos=$((pos + 1)) ;;
          esac
        done
        if [ "$pos" -ge "$n" ]; then lex_err="unbalanced double quote"; return 1; fi
        pos=$((pos + 1)) ;;
      *) pos=$((pos + 1)) ;;
    esac
  done
  if [ "$depth" -gt 0 ]; then lex_err='unbalanced ${'; return 1; fi
  word=$word'${…}' wu=1 inword=1
}

# lex_ansi: `$'` was consumed; decode the escapes up to the closing quote
lex_ansi() {
  local c nx out="" h ch
  while [ "$pos" -lt "$n" ]; do
    c=${s:pos:1}
    case $c in
      "'") pos=$((pos + 1)); word=$word$out; inword=1; return 0 ;;
      '\')
        nx=${s:pos+1:1}
        case $nx in
          n) out=$out$'\n' ;; t) out=$out$'\t' ;; r) out=$out$'\r' ;; a) out=$out$'\a' ;;
          b) out=$out$'\b' ;; e | E) out=$out$'\e' ;; f) out=$out$'\f' ;; v) out=$out$'\v' ;;
          '\') out=$out\\ ;; "'") out=$out\' ;; '"') out=$out\" ;; '?') out=$out\? ;;
          x)
            h=${s:pos+2:2}
            case $h in [0-9A-Fa-f][0-9A-Fa-f]) ;; [0-9A-Fa-f]*) h=${h:0:1} ;; *) h="" ;; esac
            if [ -n "$h" ]; then printf -v ch "\\x$h"; out=$out$ch; pos=$((pos + 2 + ${#h})); else out=$out'\x'; pos=$((pos + 2)); fi
            continue ;;
          [0-7])
            h=${s:pos+1:3}
            case $h in [0-7][0-7][0-7]) ;; [0-7][0-7]*) h=${h:0:2} ;; *) h=${h:0:1} ;; esac
            printf -v ch "\\$h"; out=$out$ch; pos=$((pos + 1 + ${#h}))
            continue ;;
          '') out=$out\\ ;;
          *) out=$out\\$nx ;;
        esac
        pos=$((pos + 2)) ;;
      *) out=$out$c; pos=$((pos + 1)) ;;
    esac
  done
  lex_err="unbalanced \$'"
  return 1
}

# lex_backtick: at the opening backquote; the inside is scanned as its own scope
lex_backtick() {
  local inner="" c nx
  pos=$((pos + 1))
  while [ "$pos" -lt "$n" ]; do
    c=${s:pos:1}
    case $c in
      '`') break ;;
      '\')
        nx=${s:pos+1:1}
        case $nx in '`' | '\' | '$') inner=$inner$nx; pos=$((pos + 2)) ;; *) inner=$inner\\; pos=$((pos + 1)) ;; esac ;;
      *) inner=$inner$c; pos=$((pos + 1)) ;;
    esac
  done
  if [ "$pos" -ge "$n" ]; then lex_err="unbalanced backquote"; return 1; fi
  pos=$((pos + 1))
  lex_text "$inner" scoped || return 1
  word=$word'`…`' wu=1 inword=1
}

# heredoc_delim: `<<` was consumed; read `-` and the delimiter word, queue it
heredoc_delim() {
  local d="" q=0 c strip=0 rest plain
  [ "${s:pos:1}" = '-' ] && { strip=1; pos=$((pos + 1)); }
  while :; do case ${s:pos:1} in ' ' | $'\t') pos=$((pos + 1)) ;; *) break ;; esac; done
  while [ "$pos" -lt "$n" ]; do
    c=${s:pos:1}
    case $c in
      ' ' | $'\t' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>') break ;;
      "'")
        q=1; rest=${s:pos+1}; plain=${rest%%\'*}
        if [ ${#plain} -eq ${#rest} ]; then lex_err="unbalanced single quote"; return 1; fi
        d=$d$plain; pos=$((pos + 2 + ${#plain})) ;;
      '"')
        q=1; pos=$((pos + 1))
        while [ "$pos" -lt "$n" ]; do
          c=${s:pos:1}
          case $c in '"') break ;; '\') d=$d${s:pos+1:1}; pos=$((pos + 2)); continue ;; esac
          d=$d$c; pos=$((pos + 1))
        done
        if [ "$pos" -ge "$n" ]; then lex_err="unbalanced double quote"; return 1; fi
        pos=$((pos + 1)) ;;
      '\') q=1; d=$d${s:pos+1:1}; pos=$((pos + 2)) ;;
      *) d=$d$c; pos=$((pos + 1)) ;;
    esac
  done
  if [ -z "$d" ]; then lex_err="here-document without a delimiter"; return 1; fi
  hd_delim+=("$d"); hd_quoted+=("$q"); hd_strip+=("$strip")
}

# read_heredocs: at the start of a line, consume the bodies announced on the
# line before. A body with an unquoted delimiter is scanned for `$(…)` and
# backticks; a quoted one is text. End of input ends an open body (as bash).
read_heredocs() {
  [ ${#hd_delim[@]} -gt 0 ] || return 0
  local delims=("${hd_delim[@]}") quoted=("${hd_quoted[@]}") strips=("${hd_strip[@]}")
  local i=0 d q strip rest line cmp body_start body_end found save_pos
  hd_delim=() hd_quoted=() hd_strip=()
  while [ "$i" -lt ${#delims[@]} ]; do
    d=${delims[i]} q=${quoted[i]} strip=${strips[i]}
    body_start=$pos body_end=$n found=0
    while [ "$pos" -lt "$n" ]; do
      rest=${s:pos}; line=${rest%%$'\n'*}
      cmp=$line
      if [ "$strip" = 1 ]; then
        while case $cmp in $'\t'*) cmp=${cmp#?} ;; *) false ;; esac; do :; done
      fi
      if [ "$cmp" = "$d" ]; then
        body_end=$pos found=1
        pos=$((pos + ${#line}))
        [ "$pos" -lt "$n" ] && pos=$((pos + 1))
        break
      fi
      pos=$((pos + ${#line}))
      [ "$pos" -lt "$n" ] && pos=$((pos + 1))
    done
    if [ "$q" = 0 ]; then
      save_pos=$pos
      pos=$body_start
      lex_body "$body_end" || return 1
      pos=$save_pos
    fi
    i=$((i + 1))
  done
  [ "$found" = 1 ] || [ "$i" -gt 0 ] # keep shellcheck quiet about found
  return 0
}

# lex_body <end>: scan an unquoted heredoc body up to <end> for substitutions
lex_body() {
  local save_n=$n c rest plain
  n=$1
  while [ "$pos" -lt "$n" ]; do
    c=${s:pos:1}
    case $c in
      '\') pos=$((pos + 2)) ;;
      '$') lex_dollar d || { n=$save_n; return 1; } ;;
      '`') lex_backtick || { n=$save_n; return 1; } ;;
      *)
        rest=${s:pos:n-pos}; plain=${rest%%[\\\$\`]*}
        if [ -z "$plain" ]; then pos=$((pos + 1)); else pos=$((pos + ${#plain})); fi ;;
    esac
  done
  n=$save_n
  word="" wu=0 inword=0
  return 0
}

# lex_text <text> [scoped]: lex a whole text, appending its tokens (inside
# `[` `]` when scoped); the lexer state of the caller is kept.
lex_text() {
  local ss=$s sp=$pos sn=$n sw=$word swu=$wu sin=$inword rc
  local sd=(${hd_delim[@]+"${hd_delim[@]}"}) sq=(${hd_quoted[@]+"${hd_quoted[@]}"}) st=(${hd_strip[@]+"${hd_strip[@]}"})
  s=$1 pos=0 n=${#1} word="" wu=0 inword=0
  hd_delim=() hd_quoted=() hd_strip=()
  [ "${2:-}" != scoped ] || { TOK+=('['); TYP+=('['); }
  lex_until ""
  rc=$?
  [ "${2:-}" != scoped ] || { TOK+=(']'); TYP+=(']'); }
  s=$ss pos=$sp n=$sn word=$sw wu=$swu inword=$sin
  hd_delim=(${sd[@]+"${sd[@]}"}) hd_quoted=(${sq[@]+"${sq[@]}"}) hd_strip=(${st[@]+"${st[@]}"})
  return "$rc"
}

# --- walking the commands -----------------------------------------------------
# The current directory is a *set* of candidates (the header's rule), kept in
# `cur` as absolute paths separated by newlines; `?` is the unknown candidate.
# The walker is a small parser over TOK/TYP: sequences of `&&`/`||` chains of
# pipelines of commands; `if`, `while`/`until`, `for`, `case`, `( )` and
# `{ }` are followed. A command that moves the directory leaves the new set
# in CD_SET for the chain it is in.

set_has() { # set_has <set> <member>
  case $'\n'$1$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}

set_union() { # set_union <a> <b>: R_SET = a ∪ b, in order
  local out=$1 m IFS=$'\n'
  for m in $2; do set_has "$out" "$m" || out=$out${out:+$'\n'}$m; done
  R_SET=$out
}

# dir_apply <set> <value> <unresolved>: R_SET = <set> moved to <value>
dir_apply() {
  local d=$2 m out="" IFS=$'\n'
  if [ "$3" = 1 ]; then R_SET='?'; return 0; fi
  # shellcheck disable=SC2088 # a literal ~ to expand by hand
  case $d in "~") d=$HOME ;; "~/"*) d=$HOME/${d#"~/"} ;; esac
  case $d in /*) R_SET=$d; return 0 ;; esac
  for m in $1; do
    if [ "$m" = '?' ]; then out=$out${out:+$'\n'}'?'; else out=$out${out:+$'\n'}$m/$d; fi
  done
  R_SET=$out
}

# tilde <value>: a leading ~ or ~/ expanded (what the shell does unquoted)
tilde() {
  # shellcheck disable=SC2088
  case $1 in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s' "$HOME/${1#"~/"}" ;; *) printf '%s' "$1" ;; esac
}

commit_dir=() commit_gitdir=() commit_wt=() commit_ok=()
W=() WU=()
pi=0 pend=0 CD_SET="" R_SET=""
ctx_gitdir="" ctx_wt="" ctx_gu=0 # GIT_DIR / GIT_WORK_TREE a `-c` body inherits

# scan_text <text> <inline|scoped> <set> <gitdir> <work-tree> <unresolved>:
# lex <text> and walk it with that context. A scoped body (a child shell)
# cannot change the caller's directory; an inline one (eval) can — its
# effect goes to CD_SET like a `cd`.
scan_text() {
  local start end sc=$cur sg=$ctx_gitdir sw=$ctx_wt su=$ctx_gu
  start=${#TOK[@]}
  lex_text "$1" || refuse "chirat: cannot parse this command ($lex_err); fix the quoting or split it."
  end=${#TOK[@]}
  cur=$3 ctx_gitdir=$4 ctx_wt=$5 ctx_gu=$6
  walk_top "$start" "$end"
  CD_SET=""
  if [ "$2" = inline ] && [ "$cur" != "$3" ]; then CD_SET=$cur; fi
  cur=$sc ctx_gitdir=$sg ctx_wt=$sw ctx_gu=$su
}

# simple: one simple command, words in W, unresolved flags in WU. Sets
# CD_SET when it moves the directory; records every `git commit`.
simple() {
  local -a words=(${W[@]+"${W[@]}"}) unres=(${WU[@]+"${WU[@]}"})
  local nw=${#words[@]} i=0 w0 argv0 v u sub subu dir gitdir worktree gu prev body
  local scur=$cur env_gitdir=$ctx_gitdir env_wt=$ctx_wt envu=$ctx_gu
  CD_SET=""

  # Drop assignments, redirections, shell keywords and wrappers.
  while [ "$i" -lt "$nw" ]; do
    w0=${words[i]}
    case $w0 in
      GIT_DIR=*) env_gitdir=$(tilde "${w0#*=}"); [ "${unres[i]}" = 0 ] || envu=1; i=$((i + 1)) ;;
      GIT_WORK_TREE=*) env_wt=$(tilde "${w0#*=}"); [ "${unres[i]}" = 0 ] || envu=1; i=$((i + 1)) ;;
      [A-Za-z_]*=* | [0-9]\>* | [0-9]\<* | \>* | \<* | \{ | \} | \! | if | then | else | elif | do | while | until)
        i=$((i + 1)) ;;
      eval)
        body=""
        i=$((i + 1))
        while [ "$i" -lt "$nw" ]; do body="$body${body:+ }${words[i]}"; i=$((i + 1)); done
        [ -z "$body" ] || scan_text "$body" inline "$scur" "$env_gitdir" "$env_wt" "$envu"
        return 0 ;;
      command | exec | nohup | time | xargs | nice | env | sudo | timeout | sh | bash | zsh | dash | */sh | */bash | */zsh)
        i=$((i + 1))
        while [ "$i" -lt "$nw" ]; do
          v=${words[i]} u=${unres[i]}
          case "$w0 $v" in
            "env -C" | "env --chdir")
              if [ $((i + 1)) -lt "$nw" ]; then
                dir_apply "$scur" "${words[i + 1]}" "${unres[i + 1]}"
                scur=$R_SET
              fi
              i=$((i + 2)) ;;
            "env --chdir="*)
              dir_apply "$scur" "${v#*=}" "$u"
              scur=$R_SET
              i=$((i + 1)) ;;
            # Wrapper options that take a value.
            "env -u" | "env -P" | "nice -n" | "timeout -s" | "timeout -k" | \
              "sudo -u" | "sudo -g" | "sudo -U" | "sudo -C" | "sudo -D" | "sudo -h" | \
              "sudo -p" | "sudo -r" | "sudo -t" | "sudo -T" | "xargs -I" | "xargs -L" | \
              "xargs -n" | "xargs -P" | "xargs -s" | "xargs -d" | "xargs -E" | "xargs -a")
              i=$((i + 2)) ;;
            # `sh -c <body>`, also `-lc`, `-ec`: the body is a script of its
            # own, run with the context in force here.
            *"sh -"[!-]*)
              case $v in
                *c*)
                  [ $((i + 1)) -lt "$nw" ] && scan_text "${words[i + 1]}" scoped "$scur" "$env_gitdir" "$env_wt" "$envu"
                  return 0 ;;
              esac
              i=$((i + 1)) ;;
            "env GIT_DIR="*) env_gitdir=$(tilde "${v#*=}"); [ "$u" = 0 ] || envu=1; i=$((i + 1)) ;;
            "env GIT_WORK_TREE="*) env_wt=$(tilde "${v#*=}"); [ "$u" = 0 ] || envu=1; i=$((i + 1)) ;;
            *" -"* | *" "[A-Za-z_]*=*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        # timeout's first operand is the duration.
        [ "$w0" = timeout ] && i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$nw" ] || return 0

  argv0=${words[i]}
  [ "${unres[i]}" = 0 ] || return 0 # an unresolved command name: nothing to see
  i=$((i + 1))
  case $argv0 in
    cd | pushd)
      while [ "$i" -lt "$nw" ]; do
        case ${words[i]} in
          --) i=$((i + 1)); break ;;
          -?*) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      if [ "$i" -lt "$nw" ]; then
        if [ "${words[i]}" = - ]; then
          CD_SET='?'
        else
          dir_apply "$cur" "${words[i]}" "${unres[i]}"
          CD_SET=$R_SET
        fi
      else
        CD_SET=$HOME
      fi ;;
    popd) CD_SET='?' ;;
    git | */git)
      dir=$scur gitdir=$env_gitdir worktree=$env_wt gu=$envu
      sub="" subu=0
      while [ "$i" -lt "$nw" ]; do
        v=${words[i]} u=${unres[i]}
        case $v in
          -C)
            if [ $((i + 1)) -lt "$nw" ]; then
              dir_apply "$dir" "${words[i + 1]}" "${unres[i + 1]}"
              dir=$R_SET
            fi
            i=$((i + 2)) ;;
          -C?*)
            dir_apply "$dir" "${v#-C}" "$u"
            dir=$R_SET
            i=$((i + 1)) ;;
          # --git-dir / --work-tree stay as written (git takes a relative one
          # against the -C directory, so every candidate gets its own).
          --git-dir=*) [ "$u" = 1 ] && gu=1 || gitdir=$(tilde "${v#*=}"); i=$((i + 1)) ;;
          --work-tree=*) [ "$u" = 1 ] && gu=1 || worktree=$(tilde "${v#*=}"); i=$((i + 1)) ;;
          --git-dir | --work-tree)
            if [ $((i + 1)) -lt "$nw" ]; then
              if [ "${unres[i + 1]}" = 1 ]; then gu=1
              elif [ "$v" = --git-dir ]; then gitdir=$(tilde "${words[i + 1]}")
              else worktree=$(tilde "${words[i + 1]}"); fi
            fi
            i=$((i + 2)) ;;
          -c | --namespace | --config-env | --super-prefix) i=$((i + 2)) ;;
          -*) i=$((i + 1)) ;;
          *) sub=$v subu=$u; break ;;
        esac
      done
      if [ "$subu" = 1 ]; then
        refuse "chirat: cannot tell what this git command does (the subcommand is not literal); write it out."
      fi
      case $sub in
        push) refuse "$push_msg" ;;
        commit)
          commit_dir+=("$dir"); commit_gitdir+=("$gitdir"); commit_wt+=("$worktree")
          if [ "$gu" = 0 ] && ! set_has "$dir" '?'; then commit_ok+=(1); else commit_ok+=(0); fi ;;
      esac ;;
    npm | pnpm | yarn | */npm | */pnpm | */yarn)
      sub=""
      prev=""
      while [ "$i" -lt "$nw" ]; do
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
      [ "$sub" != publish ] || refuse "$publish_msg" ;;
  esac
  return 0
}

# --- the parser: pi is the next token, pend the end of the range ---------------

# walk_top <start> <end>: the tokens in [start, end) as a script
walk_top() {
  local spi=$pi spend=$pend
  pi=$1 pend=$2
  while [ "$pi" -lt "$pend" ]; do
    walk_seq
    [ "$pi" -lt "$pend" ] && pi=$((pi + 1)) # a stray `)`, `;;` or keyword
  done
  pi=$spi pend=$spend
}

# seq_end <word>: a reserved word that ends the current sequence
seq_end() {
  case $1 in then | elif | else | fi | do | done | 'esac' | '}') return 0 ;; esac
  return 1
}

# expect <word>: consume that reserved word if it is next
expect() {
  [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = w ] && [ "${TOK[pi]}" = "$1" ] && pi=$((pi + 1))
  return 0
}

# walk_seq: a `;`-sequence up to a token the enclosing construct owns.
# cur flows through it: what the sequence leaves is what follows it sees.
walk_seq() {
  local before
  while [ "$pi" -lt "$pend" ]; do
    case ${TYP[pi]} in
      ';') pi=$((pi + 1)); continue ;;
      ')' | ';;') return 0 ;;
      w) seq_end "${TOK[pi]}" && return 0 ;;
    esac
    before=$pi
    walk_chain
    [ "$pi" -gt "$before" ] || pi=$((pi + 1))
  done
  return 0
}

# walk_chain: `a && b || c`. `seen` is what the next member sees, `all`
# everything any member may have seen. A member after `&&` in a chain of only
# `&&` sees exactly the set a `cd` before it produced (`cd X && git commit`:
# had the `cd` failed, the chain would have stopped); after a `||` every
# `cd` only adds its target. What follows a chain of two or more members sees
# the entry set plus every target (the chain may have stopped anywhere); a
# lone command passes its own effect on.
walk_chain() {
  local entry=$cur seen=$cur all=$cur pure=1 chained=0 nxt
  while :; do
    cur=$seen
    walk_pipeline
    nxt=""
    if [ "$pi" -lt "$pend" ]; then
      case ${TYP[pi]} in
        '&&' | '||')
          nxt=${TYP[pi]}; pi=$((pi + 1)); chained=1
          while [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = ';' ]; do pi=$((pi + 1)); done ;;
      esac
    fi
    if [ -n "$CD_SET" ]; then
      if [ "$pure" = 1 ] && [ "$nxt" = '&&' ]; then seen=$CD_SET
      else set_union "$seen" "$CD_SET"; seen=$R_SET; fi
      set_union "$all" "$seen"; all=$R_SET
    fi
    if [ "$nxt" = '||' ]; then pure=0; seen=$all; fi
    [ -n "$nxt" ] || break
  done
  if [ "$chained" = 1 ]; then cur=$all
  elif [ -n "$CD_SET" ]; then cur=$CD_SET
  else cur=$entry; fi
  CD_SET=""
}

# walk_pipeline: `a | b`; every member of a real pipeline runs in a subshell
walk_pipeline() {
  local save=$cur nseg=0
  walk_cmd
  while [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = '|' ]; do
    pi=$((pi + 1)); nseg=$((nseg + 1))
    while [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = ';' ]; do pi=$((pi + 1)); done
    cur=$save
    walk_cmd
  done
  cur=$save
  [ "$nseg" -eq 0 ] || CD_SET=""
}

# walk_cmd: a compound command or a simple one; CD_SET is its effect
walk_cmd() {
  local save
  CD_SET=""
  [ "$pi" -lt "$pend" ] || return 0
  case ${TYP[pi]} in
    '(')
      save=$cur
      pi=$((pi + 1))
      walk_seq
      [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = ')' ] && pi=$((pi + 1))
      cur=$save CD_SET=""
      return 0 ;;
    w)
      case ${TOK[pi]} in
        if) pi=$((pi + 1)); walk_if; return 0 ;;
        while | until) pi=$((pi + 1)); walk_loop; return 0 ;;
        for | select) pi=$((pi + 1)); walk_for; return 0 ;;
        case) pi=$((pi + 1)); walk_case; return 0 ;;
        '{') pi=$((pi + 1)); walk_group; return 0 ;;
      esac ;;
  esac
  walk_simple
}

# compound_done <entry> <exit>: cur back to <entry>; CD_SET = <exit> if it moved
compound_done() {
  cur=$1
  if [ "$2" = "$1" ]; then CD_SET=""; else CD_SET=$2; fi
}

# skip_one: step over one token; a scanned sub-text (`[`…`]`) is walked, scoped
skip_one() {
  local j depth save
  if [ "${TYP[pi]}" = '[' ]; then
    j=$((pi + 1)) depth=1
    while [ "$j" -lt "$pend" ] && [ "$depth" -gt 0 ]; do
      case ${TYP[j]} in '[') depth=$((depth + 1)) ;; ']') depth=$((depth - 1)) ;; esac
      j=$((j + 1))
    done
    save=$cur
    walk_top $((pi + 1)) $((j - 1))
    cur=$save
    pi=$j
  else
    pi=$((pi + 1))
  fi
}

# skip_to <word>: step over tokens up to that reserved word
skip_to() {
  while [ "$pi" -lt "$pend" ]; do
    [ "${TYP[pi]}" = w ] && [ "${TOK[pi]}" = "$1" ] && return 0
    skip_one
  done
}

# walk_if: `if … then … [elif … then …] [else …] fi`; the exit set is the
# union of the entry set and what every branch leaves
walk_if() {
  local entry=$cur acc=$cur
  walk_seq
  expect 'then'
  walk_seq
  set_union "$acc" "$cur"; acc=$R_SET
  while [ "$pi" -lt "$pend" ]; do
    case ${TYP[pi]}:${TOK[pi]} in
      w:elif) pi=$((pi + 1)); cur=$entry; walk_seq; expect 'then'; walk_seq; set_union "$acc" "$cur"; acc=$R_SET ;;
      w:else) pi=$((pi + 1)); cur=$entry; walk_seq; set_union "$acc" "$cur"; acc=$R_SET ;;
      w:fi) pi=$((pi + 1)); break ;;
      *) break ;;
    esac
  done
  compound_done "$entry" "$acc"
}

# walk_loop: `while|until … do … done`
walk_loop() {
  local entry=$cur acc
  walk_seq
  expect 'do'
  walk_seq
  set_union "$entry" "$cur"; acc=$R_SET
  expect 'done'
  compound_done "$entry" "$acc"
}

# walk_for: `for x in … do … done`
walk_for() {
  local entry=$cur acc
  skip_to 'do'
  expect 'do'
  walk_seq
  set_union "$entry" "$cur"; acc=$R_SET
  expect 'done'
  compound_done "$entry" "$acc"
}

# walk_case: `case … in pat) … ;; … esac`
walk_case() {
  local entry=$cur acc=$cur
  skip_to in
  expect in
  while [ "$pi" -lt "$pend" ]; do
    case ${TYP[pi]} in
      ';' | ';;') pi=$((pi + 1)); continue ;;
      w) [ "${TOK[pi]}" = 'esac' ] && { pi=$((pi + 1)); break; } ;;
    esac
    while [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" != ')' ]; do skip_one; done
    pi=$((pi + 1))
    cur=$entry
    walk_seq
    set_union "$acc" "$cur"; acc=$R_SET
  done
  compound_done "$entry" "$acc"
}

# walk_group: `{ …; }` runs in this shell: what it leaves is what follows sees
walk_group() {
  local entry=$cur
  walk_seq
  expect '}'
  compound_done "$entry" "$cur"
}

# walk_simple: collect the words of one simple command, walking any scanned
# sub-text (`$(…)`, backticks, a heredoc body) in its own scope
walk_simple() {
  local -a cw=() cwu=()
  while [ "$pi" -lt "$pend" ]; do
    case ${TYP[pi]} in
      w) cw+=("${TOK[pi]}"); cwu+=(0); pi=$((pi + 1)) ;;
      u) cw+=("${TOK[pi]}"); cwu+=(1); pi=$((pi + 1)) ;;
      '[') skip_one ;;
      ']') pi=$((pi + 1)) ;;
      *) break ;;
    esac
  done
  CD_SET=""
  [ ${#cw[@]} -gt 0 ] || return 0
  W=("${cw[@]}") WU=("${cwu[@]}")
  simple
}

lex_text "$command" || refuse "chirat: cannot parse this command ($lex_err); fix the quoting or split it."
walk_top 0 ${#TOK[@]}

[ ${#commit_dir[@]} -gt 0 ] || exit 0

# check_commit <dir> <git-dir> <work-tree>: print the refused staged paths of
# that repo, or the reason the repo cannot be read.
check_commit() {
  local g=(git -C "$1") top staged workspace_repo path base
  [ -z "$2" ] || g+=("--git-dir=$2")
  [ -z "$3" ] || g+=("--work-tree=$3")
  if ! top=$("${g[@]}" rev-parse --show-toplevel 2>/dev/null) || [ -z "$top" ]; then
    if ! top=$("${g[@]}" rev-parse --absolute-git-dir 2>/dev/null) || [ -z "$top" ]; then
      echo "$unres_msg (${2:-$1} is not a git repository)"
      return 0
    fi
  fi
  staged=$("${g[@]}" diff --cached --name-only 2>/dev/null) || return 0
  [ -n "$staged" ] || return 0

  # The marker must already be in HEAD (or, in a repo with no commits yet, on
  # disk), so staging a WORKFLOW.md does not make a code repo a workspace.
  workspace_repo=0
  if "${g[@]}" rev-parse --verify -q HEAD >/dev/null; then
    "${g[@]}" cat-file -e HEAD:docs/WORKFLOW.md 2>/dev/null && workspace_repo=1
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

# Every commit is checked against every candidate directory; one refusal is
# enough.
refused=""
k=0
while [ "$k" -lt ${#commit_dir[@]} ]; do
  [ "${commit_ok[k]}" = 1 ] || refuse "$unres_msg (the target is not literal: a variable, substitution, glob or an unknown current directory)."
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    out=$(check_commit "$d" "${commit_gitdir[k]}" "${commit_wt[k]}")
    case $refused in *"$out"*) ;; *) refused=$refused$out ;; esac
  done <<<"${commit_dir[k]}"
  k=$((k + 1))
done

[ -n "$refused" ] || exit 0
printf '%s\n' "$refused" >&2
exit 2
