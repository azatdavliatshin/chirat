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
# newlines, `(`, `)`) separate simple commands; redirections (`>`, `>>`, `<`,
# `2>&1`, `&>`, `<<<`, `{fd}>`, `<<` with its here-document) are tokens of
# their own, recognised only on unquoted characters, so `git -C '>dir'
# commit` is a commit in `>dir` and `echo '>' > f` writes `>` to `f`; `$(…)`,
# backticks, `${x:-$(…)}`, `bash -c '…'` / `eval '…'` bodies and the bodies
# of here-documents with an unquoted delimiter are scanned too, each as its
# own command scope. Every double-quoted region, wherever it appears (a word,
# the value in `${…}`, a heredoc body, a `-c` body), is scanned for `$(…)`,
# backticks and `${…}` — `"${x:-"$(git push)"}"` is a push; only `'…'` is
# literal. Nothing is ever expanded, evaluated or executed: `$VAR`, `${…}`,
# `$(…)`, backticks, globs and `~user` leave a word *unresolved*. Each simple
# command loses leading `VAR=value` assignments and the wrappers `command`,
# `env`, `exec`, `sudo`, `nohup`, `time`, `nice`, `timeout`, `xargs`; for
# `git`, global options are walked to find the subcommand, so `git stash
# push` and `git log --grep push` pass.
#
# The walker tracks TWO things, in two dimensions that must not be merged:
# the current DIRECTORY (a set of candidates) and the SHELL STATE (known or
# unknown, with the exported git environment). "Directory unknown" and "shell
# unknown" are different, and `-C` cures only the first:
#   - directory unknown (`?` in the set): the hook lost track of the cwd; a
#     commit with an absolute `-C` / `--git-dir` is still checked and may pass.
#   - shell unknown: code the hook did not see has run in this shell —
#     `source` / `.`, `eval` or `trap` of an unresolved string, a call of a
#     function whose body changed the shell, `shopt -s expand_aliases` /
#     `cdable_vars` / `lastpipe`, `enable`, an `alias` for a word this hook
#     interprets, an `export` / `declare -x` / `unset` of a `GIT_*` variable
#     it could not carry (below), an `exec` with no command that redirects
#     stdin. Functions, aliases and the environment may all have changed, so
#     EVERY later `git` / `npm` / `pnpm` / `yarn` in that scope is refused,
#     with or without `-C`, and every later `cd` is unknown. Scoping is the
#     directory's: a `( … )`, a pipeline member, a background job and a `-c`
#     body keep their unknown state to themselves; `eval` and a `trap` body
#     reach the caller.
#   - exported git environment: `export GIT_DIR=…` / `GIT_WORK_TREE=…` (also
#     `declare -x`, `typeset -x`) with a literal value, as its own command in
#     a `;`/newline sequence or a `{ … }` group, is carried like a prefix
#     assignment for every later command in scope — `export
#     GIT_DIR=/clean/.git; git commit` really commits in `clean`. Inside an
#     `&&`/`||` chain of two or more members, under `if`/`case`, or in a
#     loop the export may or may not have run: the shell is unknown after
#     it. An unresolved value, a `GIT_*` variable other than those two
#     (`GIT_INDEX_FILE` replaces the very index the guard inspects;
#     `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY`, `GIT_CONFIG_GLOBAL`,
#     `GIT_CEILING_DIRECTORIES`, …), `export -n`, `unset`, `export GIT_DIR`
#     without a value, and a standalone `GIT_*=…` assignment (exported
#     earlier or not — the hook does not know) all make the shell unknown. A
#     function whose body commits, called while a git environment is
#     exported, is refused (its body was walked without that environment).
#     As a prefix (`GIT_INDEX_FILE=x git commit`, `env GIT_INDEX_FILE=x git
#     commit`) a `GIT_*` variable other than the two refuses that commit.
#
# Shells fed from somewhere the hook cannot read are refused: `sh` / `bash` /
# `zsh` / `dash` (any path spelling) with `-s`, or with `-` or no script
# operand while stdin is a pipe (`… | sh`, `… | bash -`), a here-document or
# here-string (`bash <<EOF`, `sh <<<"$X"`), a `<` redirection, an earlier
# `exec <file`, or `xargs` — directly or through the wrappers above, a `-c`
# body, a `{ … }` / `( … )` / `if` / loop whose stdin is redirected, or a
# function whose body holds such a shell. A shell given a script file (`bash
# tests/run.sh`) stays allowed and the hook does not read the file; a `-c`
# body is walked. `python3 - <<EOF` is not a shell.
#
# The current directory is a SET of candidates, not one value — do not "fix"
# this back to a single cwd. The set is tracked ONLY through:
#   (a) a top-level `cd X` / `pushd X` (or `env -C X` for that one command)
#       in a `;`/newline sequence: the set becomes {X};
#   (b) the same chain of `&&`: `cd X && git commit` sees exactly {X} (had
#       the `cd` failed, the chain would have stopped); what follows a chain
#       of two or more members — after its `;`, or behind `||` — sees the
#       entry set plus every target, {old, X};
#   (c) `if` and `case`, which run a branch at most once: a `cd` in a branch
#       adds its target, {old, X}.
# Every other place a `cd` (`pushd`, `popd`, `cd -`) can appear is one of:
#   - its own scope, no effect outside: a pipeline member, `( … )`, a
#     background job (`… &`, `coproc`), a `bash -c` / `sh -c` body, `$(…)`,
#     backticks, a here-document body;
#   - UNKNOWN (`?`): a loop (`for`/`while`/`until`/`select`) whose body or
#     condition touches the directory — the body may run any number of
#     times, so after it the set is `?`, and a commit inside it is unknown
#     too; a function whose body touches the directory, on every later call
#     (a function body is walked as an unknown directory, so a commit in it
#     without an absolute `-C` is unknown; defining a function named like a
#     word this hook interprets — `cd`, `git`, `command`, `eval`, … —
#     counts as touching); `source` / `.`; `eval` or `trap` of an
#     unresolved string; a `trap` body that moves; `cd -`, `popd`, `pushd`
#     with an option or no directory, `cd` with two operands, `cd "$VAR"`,
#     a relative `cd` while `CDPATH` is set. Once `shopt` turns on
#     `expand_aliases` or `cdable_vars`, `enable` runs, or an `alias` names
#     one of the words above, `cd` and `git` may mean something else: every
#     later `cd` is unknown and every later commit is refused.
# A commit is checked against every candidate; one dirty or unknown
# candidate refuses it. A construct this walker does not model never counts
# as "no effect": only the three tracked paths above move the set to a known
# place.
#
# A `bash -c` / `sh -c` / `eval` body inherits the context in force at the
# call: the directory set (from `cd`, `env -C`), the shell state, and
# `GIT_DIR` / `GIT_WORK_TREE` from an `export`, prefix assignments or
# `env VAR=…`. A `cd` or an `export` inside a `-c` body stays in the body;
# inside `eval` it reaches the caller.
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
opaque_msg="chirat: a shell fed from a pipe, heredoc or stdin runs code the hook cannot see; put it in a script file"

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
#   ;   command separator (text `;`, or a newline for a line break)
#   &   background job       (   )   subshell / group
#   >   a redirection operator, with its fd (`2>&`, `{fd}<`, `<<`); its
#       target is the word that follows (none for `<<`, the here-document)
#   [   ]   a scanned sub-text: `$(…)`, backticks, a heredoc body
# Globals while lexing: s (text), pos, n (length), the word being built
# (word, wu = unresolved, wq = had a quoted or escaped part, inword = a word
# is open, even if empty), lex_err, and the here-documents announced on the
# current line (hd_*).

TOK=() TYP=()
s="" pos=0 n=0 word="" wu=0 wq=0 inword=0 lex_err=""
hd_delim=() hd_quoted=() hd_strip=()
uspecial=$'\\\\"\'$`();|&<>*?[~ \t\n' # ends a run of plain characters, unquoted
dspecial=$'\\\\"$`'                   # inside "…"

emit_word() {
  [ "$inword" = 1 ] || return 0
  TOK+=("$word")
  if [ "$wu" = 1 ]; then TYP+=(u); else TYP+=(w); fi
  word="" wu=0 wq=0 inword=0
}

emit_op() { # emit_op <kind> [text]
  emit_word
  TOK+=("${2-$1}")
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
      $'\n') emit_op ';' $'\n'; pos=$((pos + 1)); read_heredocs || return 1 ;;
      '#')
        if [ "$inword" = 1 ]; then
          word=$word#; pos=$((pos + 1))
        else
          rest=${s:pos}; plain=${rest%%$'\n'*}; pos=$((pos + ${#plain}))
        fi ;;
      '\')
        nx=${s:pos+1:1}
        if [ $((pos + 1)) -ge "$n" ]; then word=$word\\; pos=$((pos + 1)); inword=1 wq=1
        elif [ "$nx" = $'\n' ]; then pos=$((pos + 2))
        else word=$word$nx; pos=$((pos + 2)); inword=1 wq=1; fi ;;
      "'")
        rest=${s:pos+1}; plain=${rest%%\'*}
        if [ ${#plain} -eq ${#rest} ]; then lex_err="unbalanced single quote"; return 1; fi
        word=$word$plain; pos=$((pos + 2 + ${#plain})); inword=1 wq=1 ;;
      '"') pos=$((pos + 1)); wq=1; lex_dquote || return 1 ;;
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
        elif [ "$nx" = '>' ]; then lex_redir || return 1
        else emit_op '&'; pos=$((pos + 1)); fi ;;
      '<' | '>') lex_redir || return 1 ;;
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

# lex_redir: at an unquoted `>`, `<` or `&>`. The operator becomes a token of
# kind `>`, prefixed with its fd when the open word is one unquoted number or
# `{name}` (`2>&1`, `{fd}>file`); any other open word is a word of its own
# (`echo foo>bar`). The target is lexed as the next word; `<<` queues a
# here-document instead and has no target word. A quoted `>` never gets here.
lex_redir() {
  local fd="" op
  if [ "$inword" = 1 ]; then
    if [ "$wq" = 0 ] && [ "${s:pos:1}" != '&' ]; then
      case $word in
        *[!0-9]*)
          case $word in
            '{'[A-Za-z_]*'}') case ${word:1:${#word}-2} in *[!A-Za-z0-9_]*) ;; *) fd=$word ;; esac ;;
          esac ;;
        ?*) fd=$word ;;
      esac
    fi
    if [ -n "$fd" ]; then word="" wu=0 wq=0 inword=0; else emit_word; fi
  fi
  case ${s:pos:3} in
    '<<<') op='<<<'; pos=$((pos + 3)) ;;
    '<<'*) pos=$((pos + 2)); emit_op '>' "$fd<<"; heredoc_delim || return 1; return 0 ;;
    '&>>') op='&>>'; pos=$((pos + 3)) ;;
    '&>'*) op='&>'; pos=$((pos + 2)) ;;
    '>>'* | '>&'* | '<&'* | '<>'* | '>|'*) op=${s:pos:2}; pos=$((pos + 2)) ;;
    *) op=${s:pos:1}; pos=$((pos + 1)) ;;
  esac
  emit_op '>' "$fd$op"
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
      if [ "$1" = u ]; then pos=$((pos + 2)); wq=1; lex_ansi || return 1
      else word=$word\$; pos=$((pos + 1)); inword=1; fi ;;
    '"')
      if [ "$1" = u ]; then pos=$((pos + 1)); wq=1
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
  local sw=$word swq=$wq
  word="" wu=0 wq=0 inword=0
  TOK+=('['); TYP+=('[')
  lex_until "$1" || return 1
  TOK+=(']'); TYP+=(']')
  word=$sw'$(…)' wu=1 wq=$swq inword=1
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
  word="" wu=0 wq=0 inword=0
  return 0
}

# lex_text <text> [scoped]: lex a whole text, appending its tokens (inside
# `[` `]` when scoped); the lexer state of the caller is kept.
lex_text() {
  local ss=$s sp=$pos sn=$n sw=$word swu=$wu swq=$wq sin=$inword rc
  local sd=(${hd_delim[@]+"${hd_delim[@]}"}) sq=(${hd_quoted[@]+"${hd_quoted[@]}"}) st=(${hd_strip[@]+"${hd_strip[@]}"})
  s=$1 pos=0 n=${#1} word="" wu=0 wq=0 inword=0
  hd_delim=() hd_quoted=() hd_strip=()
  [ "${2:-}" != scoped ] || { TOK+=('['); TYP+=('['); }
  lex_until ""
  rc=$?
  [ "${2:-}" != scoped ] || { TOK+=(']'); TYP+=(']'); }
  s=$ss pos=$sp n=$sn word=$sw wu=$swu wq=$swq inword=$sin
  hd_delim=(${sd[@]+"${sd[@]}"}) hd_quoted=(${sq[@]+"${sq[@]}"}) hd_strip=(${st[@]+"${st[@]}"})
  return "$rc"
}

# --- walking the commands -----------------------------------------------------
# The current directory is a *set* of candidates (the header's rule), kept in
# `cur` as absolute paths separated by newlines; `?` is the unknown candidate.
# The walker is a small parser over TOK/TYP: sequences of `&&`/`||` chains of
# pipelines of commands; `if`, `while`/`until`, `for`, `case`, `( )`,
# `{ }`, `… &`, `coproc` and function definitions are followed. A command
# that moves the directory leaves the new set in CD_SET for the chain it is
# in, and sets DIR_TOUCHED — loops and function bodies read that flag to
# decide whether what they enclose touched the directory at all.

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
W=() WU=() W_STDIN=0 # the words of one simple command; 1 when it redirects stdin
pi=0 pend=0 CD_SET="" R_SET="" DIR_TOUCHED=0
# The shell state (header): `shu` is 1 once the shell is unknown (`shu_why`
# says since what); ctx_gitdir / ctx_wt / ctx_gu / ctx_genv are the git
# environment in force — exported in this scope, or the prefix a `-c` body
# inherits (ctx_gu: unresolved; ctx_genv: a `GIT_*` other than the two);
# `fed` is 1 when stdin carries something the hook did not see (a pipe, a
# redirection, an earlier `exec <file`). SH_TOUCHED is set when any of these
# changed, as DIR_TOUCHED is for the directory; loops, chains, `if`/`case`
# and function bodies read it. Saved and restored together (sh_save /
# sh_load) wherever the directory set is.
shu=0 shu_why="" ctx_gitdir="" ctx_wt="" ctx_gu=0 ctx_genv="" fed=0 SH_TOUCHED=0
bare_shells=0 # shells seen so far that would read stdin if it were redirected
FN_MOVES=""   # functions whose call makes the set unknown
FN_SHELL=""   # functions whose call makes the shell unknown
FN_BARE=""    # functions whose body holds a shell that reads stdin
FN_COMMITS="" # functions whose body records a commit (read with the environment of the definition)
# Words this hook gives a meaning to; a function of that name shadows it.
interpreted='cd pushd popd git env command builtin exec eval source . trap sh bash zsh dash sudo nohup nice timeout xargs time coproc shopt enable alias export declare typeset local readonly unset npm pnpm yarn'

sh_save() { SH_SAVED=$shu$'\n'$ctx_gu$'\n'$fed$'\n'$ctx_genv$'\n'$ctx_gitdir$'\n'$ctx_wt; }
sh_load() { # sh_load <saved>
  local x=$1
  shu=${x%%$'\n'*}; x=${x#*$'\n'}
  ctx_gu=${x%%$'\n'*}; x=${x#*$'\n'}
  fed=${x%%$'\n'*}; x=${x#*$'\n'}
  ctx_genv=${x%%$'\n'*}; x=${x#*$'\n'}
  ctx_gitdir=${x%%$'\n'*}
  ctx_wt=${x#*$'\n'}
}
unknown_shell() { # unknown_shell <why>: from here on the shell is unknown
  [ "$shu" = 1 ] || shu_why=$1
  shu=1 SH_TOUCHED=1
}
shell_msg() { # shell_msg <tool>
  printf '%s' "chirat: after $shu_why the shell is unknown (functions, aliases and the git environment may have changed), so this $1 command cannot be checked; run it as a fresh command."
}

# scan_text <text> <inline|scoped> <set> <gitdir> <work-tree> <unresolved>
# <genv> <stdin>: lex <text> and walk it with that context — the directory
# set, the shell state in force, the git environment of the call (an export
# or the prefix of this command) and whether its stdin was redirected. A
# scoped body (a child shell) cannot change the caller's directory or shell;
# an inline one (eval, trap) can — a `cd` goes to CD_SET, a shell left
# unknown stays unknown, and a changed git environment makes the caller's
# shell unknown (the hook does not carry an export out of a body).
scan_text() {
  local start end sc=$cur sdt=$DIR_TOUCHED sst=$SH_TOUCHED ss why
  sh_save; ss=$SH_SAVED
  start=${#TOK[@]}
  lex_text "$1" || refuse "chirat: cannot parse this command ($lex_err); fix the quoting or split it."
  end=${#TOK[@]}
  cur=$3 ctx_gitdir=$4 ctx_wt=$5 ctx_gu=$6 ctx_genv=$7 SH_TOUCHED=0
  [ "$8" = 0 ] || fed=1
  walk_top "$start" "$end"
  CD_SET=""
  if [ "$2" = inline ]; then
    [ "$cur" = "$3" ] || CD_SET=$cur
    if [ "$shu" = 1 ]; then why=$shu_why; sh_load "$ss"; unknown_shell "$why"
    elif [ "$SH_TOUCHED" = 1 ]; then sh_load "$ss"; unknown_shell "a body (eval, trap) that changed the git environment"
    else sh_load "$ss"; fi
    [ "$SH_TOUCHED" = 1 ] || SH_TOUCHED=$sst
  else
    sh_load "$ss"
    DIR_TOUCHED=$sdt SH_TOUCHED=$sst
  fi
  cur=$sc
}

# shell_cmd <words from i>: a `sh` / `bash` / `zsh` / `dash` call, in simple().
# Options are walked for `-c` (the body is scanned, with this context) and
# `-s` / `-` (the script comes from stdin: refused). With neither, a script
# operand is allowed unread; no operand means stdin — refused when it is a
# pipe, a redirection or xargs (header), otherwise counted as a bare shell.
# Sets SH_I to the index after the shell's arguments. Returns 1 when done.
shell_cmd() {
  local v u body="" has_c=0 opaque=0
  while [ "$i" -lt "$nw" ]; do
    v=${words[i]} u=${unres[i]}
    case $v in
      --) i=$((i + 1)); break ;;
      -) opaque=1; break ;;
      -o | -O | +O | --rcfile | --init-file) i=$((i + 2)) ;;
      -[!-]* | +?*)
        [ "$u" = 0 ] || refuse "$opaque_msg (an option of the shell is not literal)"
        case $v in -*s*) opaque=1 ;; esac
        case $v in -*c*) has_c=1 ;; esac
        i=$((i + 1)) ;;
      --*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$opaque" = 0 ] || refuse "$opaque_msg"
  if [ "$has_c" = 1 ]; then
    if [ "$i" -lt "$nw" ]; then
      [ "${unres[i]}" = 1 ] || scan_text "${words[i]}" scoped "$scur" "$env_gitdir" "$env_wt" "$envu" "$env_genv" "$cmd_fed"
    elif [ "$via_xargs" = 1 ]; then
      refuse "$opaque_msg (the -c body comes from xargs)"
    fi
    return 1
  fi
  if [ "$i" -ge "$nw" ]; then
    if [ "$cmd_fed" = 1 ] || [ "$via_xargs" = 1 ]; then refuse "$opaque_msg"; fi
    bare_shells=$((bare_shells + 1))
  fi
  return 1 # a script file: allowed, not read
}

# git_env <name> <value> <unresolved>: a `GIT_*` variable in the environment
# of this command (prefix or `env`): GIT_DIR / GIT_WORK_TREE are followed,
# any other refuses a commit of this command.
git_env() {
  case $1 in
    GIT_DIR) env_gitdir=$(tilde "$2"); [ "$3" = 0 ] || envu=1 ;;
    GIT_WORK_TREE) env_wt=$(tilde "$2"); [ "$3" = 0 ] || envu=1 ;;
    *) env_genv=$1 ;;
  esac
}

# simple: one simple command, words in W, unresolved flags in WU, W_STDIN
# when it redirects stdin. Sets CD_SET when it moves the directory, changes
# the shell state, records every `git commit`.
simple() {
  local -a words=("${W[@]}") unres=("${WU[@]}")
  local nw=${#W[@]} i=0 w0 argv0 v u sub subu dir gitdir worktree gu prev body via_xargs=0 saw_exec=0 git_assign=0 xp
  local scur=$cur env_gitdir=$ctx_gitdir env_wt=$ctx_wt envu=$ctx_gu env_genv=$ctx_genv cmd_fed=$fed
  [ "$W_STDIN" = 0 ] || cmd_fed=1
  CD_SET=""

  # Drop assignments, shell keywords and wrappers.
  while [ "$i" -lt "$nw" ]; do
    w0=${words[i]}
    case $w0 in
      GIT_*=*) git_env "${w0%%=*}" "${w0#*=}" "${unres[i]}"; git_assign=1; i=$((i + 1)) ;;
      [A-Za-z_]*=* | \{ | \} | \! | if | then | else | elif | do | while | until)
        i=$((i + 1)) ;;
      eval)
        # The string runs in this shell; one we cannot read may do anything.
        body="" u=0
        i=$((i + 1))
        while [ "$i" -lt "$nw" ]; do
          body="$body${body:+ }${words[i]}"; [ "${unres[i]}" = 0 ] || u=1; i=$((i + 1))
        done
        if [ "$u" = 1 ]; then CD_SET='?'; unknown_shell "eval of a string that is not literal"
        elif [ -n "$body" ]; then scan_text "$body" inline "$scur" "$env_gitdir" "$env_wt" "$envu" "$env_genv" "$cmd_fed"; fi
        return 0 ;;
      sh | bash | zsh | dash | */sh | */bash | */zsh | */dash)
        i=$((i + 1))
        shell_cmd || return 0 ;;
      command | builtin | exec | nohup | time | xargs | nice | env | sudo | timeout)
        [ "$w0" != xargs ] || via_xargs=1 # the rest of the arguments come from stdin
        [ "$w0" != exec ] || saw_exec=1
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
            "env GIT_"*=*) git_env "${v%%=*}" "${v#*=}" "$u"; i=$((i + 1)) ;;
            *" -"* | *" "[A-Za-z_]*=*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        # timeout's first operand is the duration.
        [ "$w0" = timeout ] && i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  if [ "$i" -ge "$nw" ]; then
    # Only assignments and wrappers: a standalone `GIT_*=…` may or may not
    # be exported (header); `exec <file` hands stdin to every later command.
    [ "$git_assign" = 0 ] || unknown_shell "a standalone GIT_* assignment"
    if [ "$saw_exec" = 1 ] && [ "$W_STDIN" = 1 ]; then fed=1 SH_TOUCHED=1; fi
    return 0
  fi

  argv0=${words[i]}
  [ "${unres[i]}" = 0 ] || return 0 # an unresolved command name: nothing to see
  i=$((i + 1))
  # A call of a function whose body touches the directory (or that shadows
  # a word this hook interprets) lands anywhere; one whose body changed the
  # shell leaves the shell unknown; one whose body commits was read with the
  # git environment of its definition — called under an exported one, the
  # commit would go elsewhere.
  if set_has "$FN_SHELL" "$argv0"; then unknown_shell "a call of $argv0, whose body changes the shell"; return 0; fi
  if set_has "$FN_MOVES" "$argv0"; then CD_SET='?'; return 0; fi
  if set_has "$FN_BARE" "$argv0"; then
    [ "$cmd_fed" = 0 ] || refuse "$opaque_msg"
    bare_shells=$((bare_shells + 1))
    return 0
  fi
  if set_has "$FN_COMMITS" "$argv0" && [ -n "$ctx_gitdir$ctx_wt$ctx_genv" ]; then
    refuse "chirat: $argv0 commits and is called with an exported git environment its body was read without; run git directly."
  fi
  if [ "$shu" = 1 ]; then case $argv0 in cd | pushd | popd) CD_SET='?'; return 0 ;; esac; fi
  case $argv0 in
    cd)
      # Options `-L -P -e -@` are followed; any other option, `-`, or two
      # operands (an error in Bash 4.4+, the first dir in 3.2) is unknown.
      while [ "$i" -lt "$nw" ]; do
        case ${words[i]} in
          --) i=$((i + 1)); break ;;
          -) break ;;
          -[LPe@]*) case ${words[i]#-} in *[!LPe@]*) CD_SET='?'; return 0 ;; esac; i=$((i + 1)) ;;
          -?*) CD_SET='?'; return 0 ;;
          *) break ;;
        esac
      done
      if [ "$i" -ge "$nw" ]; then CD_SET=$HOME
      elif [ $((i + 1)) -lt "$nw" ] || [ "${words[i]}" = - ]; then CD_SET='?'
      elif [ -n "${CDPATH:-}" ] && [ "${unres[i]}" = 0 ]; then
        # With CDPATH a relative name may land under another directory.
        # shellcheck disable=SC2088 # a literal ~ to expand by hand
        case ${words[i]} in /* | ./* | ../* | . | .. | "~" | "~/"*) dir_apply "$cur" "${words[i]}" 0; CD_SET=$R_SET ;; *) CD_SET='?' ;; esac
      else
        dir_apply "$cur" "${words[i]}" "${unres[i]}"
        CD_SET=$R_SET
      fi ;;
    pushd)
      # `pushd X` is a `cd X`; any option (`-n` does not move), `+N`/`-N`
      # (a rotation) or no directory (a swap) is unknown.
      if [ "$i" -lt "$nw" ] && [ "${words[i]}" = -- ]; then i=$((i + 1)); fi
      if [ "$i" -lt "$nw" ] && [ $((i + 1)) -eq "$nw" ]; then
        case ${words[i]} in
          -* | +*) CD_SET='?' ;;
          *) dir_apply "$cur" "${words[i]}" "${unres[i]}"; CD_SET=$R_SET ;;
        esac
      else
        CD_SET='?'
      fi ;;
    popd) CD_SET='?' ;;
    source | .)
      # The file runs in this shell: the directory and everything else.
      CD_SET='?'
      unknown_shell "source" ;;
    trap)
      # `trap <string> <signal>…`: the string runs in this shell, later.
      while [ "$i" -lt "$nw" ]; do case ${words[i]} in --) i=$((i + 1)); break ;; -?*) i=$((i + 1)) ;; *) break ;; esac; done
      if [ "$i" -lt "$nw" ]; then
        if [ "${unres[i]}" = 1 ]; then CD_SET='?'; unknown_shell "trap of a string that is not literal"
        else
          case ${words[i]} in
            '' | -) ;;
            *) scan_text "${words[i]}" inline "$scur" "$env_gitdir" "$env_wt" "$envu" "$env_genv" "$cmd_fed"; [ -z "$CD_SET" ] || CD_SET='?' ;;
          esac
        fi
      fi ;;
    shopt | enable | alias)
      # Alias expansion, `cdable_vars`, `lastpipe`, a disabled builtin or an
      # alias for a word this hook interprets: from here on `cd X` and `git …`
      # may mean something else — the shell is unknown.
      case $argv0 in
        shopt) case " ${words[*]} " in *" expand_aliases "* | *" cdable_vars "* | *" lastpipe "*) unknown_shell "shopt" ;; esac ;;
        enable) unknown_shell "enable" ;;
        alias)
          while [ "$i" -lt "$nw" ]; do
            case ${words[i]} in
              *=*) case " $interpreted " in *" ${words[i]%%=*} "*) unknown_shell "alias ${words[i]%%=*}" ;; esac ;;
            esac
            i=$((i + 1))
          done ;;
      esac
      i=0
      while [ "$i" -lt "$nw" ]; do [ "${unres[i]}" = 0 ] || unknown_shell "$argv0 with a word that is not literal"; i=$((i + 1)); done ;;
    export | declare | typeset | local | readonly | unset)
      # The exported git environment (header). `export NAME=literal` and
      # `declare -x` / `typeset -x` / `local -x` of GIT_DIR / GIT_WORK_TREE
      # are carried for the rest of the scope; everything else that names a
      # GIT_* variable leaves the shell unknown.
      xp=0
      [ "$argv0" != export ] || xp=1
      while [ "$i" -lt "$nw" ]; do
        case ${words[i]} in
          --) i=$((i + 1)); break ;;
          -*)
            case "$argv0 ${words[i]}" in
              "export -"*n*) xp=0 ;;
              "declare -"*x* | "typeset -"*x* | "local -"*x*) xp=1 ;;
            esac
            i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      while [ "$i" -lt "$nw" ]; do
        v=${words[i]} u=${unres[i]}
        case $v in
          GIT_DIR=* | GIT_WORK_TREE=*)
            if [ "$xp" = 1 ] && [ "$u" = 0 ]; then
              case ${v#*=} in
                *$'\n'*) unknown_shell "$argv0 ${v%%=*}" ;;
                *)
                  if [ "${v%%=*}" = GIT_DIR ]; then ctx_gitdir=$(tilde "${v#*=}"); else ctx_wt=$(tilde "${v#*=}"); fi
                  SH_TOUCHED=1 ;;
              esac
            else
              unknown_shell "$argv0 ${v%%=*}"
            fi ;;
          GIT_*) unknown_shell "$argv0 ${v%%=*}" ;;
          *) case ${v%%=*} in *['$`*?[~']*) unknown_shell "$argv0 of a name that is not literal" ;; esac ;;
        esac
        i=$((i + 1))
      done ;;
    git | */git)
      [ "$shu" = 0 ] || refuse "$(shell_msg git)"
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
      if [ "$subu" = 1 ] || { [ -z "$sub" ] && [ "$via_xargs" = 1 ]; }; then
        refuse "chirat: cannot tell what this git command does (the subcommand is not literal); write it out."
      fi
      case $sub in
        push) refuse "$push_msg" ;;
        commit)
          [ -z "$env_genv" ] || refuse "chirat: $env_genv in the environment changes where this commit goes (git's layout or index); run git without it."
          commit_dir+=("$dir"); commit_gitdir+=("$gitdir"); commit_wt+=("$worktree")
          if [ "$gu" = 0 ] && ! set_has "$dir" '?'; then commit_ok+=(1); else commit_ok+=(0); fi ;;
      esac ;;
    npm | pnpm | yarn | */npm | */pnpm | */yarn)
      [ "$shu" = 0 ] || refuse "$(shell_msg "${argv0##*/}")"
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
      if [ -z "$sub" ] && [ "$via_xargs" = 1 ]; then
        refuse "chirat: cannot tell what this ${argv0##*/} command does (the subcommand comes from xargs); write it out."
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
# cur flows through it: what the sequence leaves is what follows it sees. A
# chain ended by `&` ran in the background, in a shell of its own: nothing
# it did reaches what follows.
walk_seq() {
  local before entry sdt sst ssh
  while [ "$pi" -lt "$pend" ]; do
    case ${TYP[pi]} in
      ';' | '&') pi=$((pi + 1)); continue ;;
      ')' | ';;') return 0 ;;
      w) seq_end "${TOK[pi]}" && return 0 ;;
    esac
    before=$pi entry=$cur sdt=$DIR_TOUCHED sst=$SH_TOUCHED
    sh_save; ssh=$SH_SAVED
    walk_chain
    if [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = '&' ]; then
      cur=$entry DIR_TOUCHED=$sdt SH_TOUCHED=$sst
      sh_load "$ssh"
      pi=$((pi + 1))
    fi
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
  local entry=$cur seen=$cur all=$cur pure=1 chained=0 nxt sst=$SH_TOUCHED
  SH_TOUCHED=0
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
  # A git environment exported inside a chain of two or more members may or
  # may not be in force afterwards (the chain may have stopped before it).
  if [ "$SH_TOUCHED" = 1 ]; then
    [ "$chained" = 0 ] || unknown_shell "a change of the shell inside an && / || chain"
  else
    SH_TOUCHED=$sst
  fi
}

# walk_pipeline: `a | b`; every member of a real pipeline runs in a subshell
walk_pipeline() {
  local save=$cur nseg=0 sdt=$DIR_TOUCHED sst=$SH_TOUCHED ssh
  sh_save; ssh=$SH_SAVED
  walk_cmd
  while [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = '|' ]; do
    pi=$((pi + 1)); nseg=$((nseg + 1))
    while [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = ';' ]; do pi=$((pi + 1)); done
    cur=$save
    sh_load "$ssh"
    fed=1 # this member reads the one before it
    walk_cmd
  done
  cur=$save
  if [ "$nseg" -gt 0 ]; then
    sh_load "$ssh"
    CD_SET="" DIR_TOUCHED=$sdt SH_TOUCHED=$sst
  fi
}

# walk_cmd: a compound command or a simple one; CD_SET is its effect
walk_cmd() {
  local save sdt sst ssh bare=$bare_shells compound=1
  CD_SET=""
  [ "$pi" -lt "$pend" ] || return 0
  case ${TYP[pi]} in
    '(')
      save=$cur sdt=$DIR_TOUCHED sst=$SH_TOUCHED
      sh_save; ssh=$SH_SAVED
      pi=$((pi + 1))
      walk_seq
      [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = ')' ] && pi=$((pi + 1))
      cur=$save CD_SET="" DIR_TOUCHED=$sdt SH_TOUCHED=$sst
      sh_load "$ssh" ;;
    w)
      case ${TOK[pi]} in
        if) pi=$((pi + 1)); walk_if ;;
        while | until) pi=$((pi + 1)); walk_loop ;;
        for | select) pi=$((pi + 1)); walk_for ;;
        case) pi=$((pi + 1)); walk_case ;;
        '{') pi=$((pi + 1)); walk_group ;;
        coproc) pi=$((pi + 1)); walk_coproc ;;
        function)
          pi=$((pi + 1))
          [ "$pi" -lt "$pend" ] || return 0
          save=${TOK[pi]}; pi=$((pi + 1))
          if [ $((pi + 1)) -lt "$pend" ] && [ "${TYP[pi]}" = '(' ] && [ "${TYP[pi + 1]}" = ')' ]; then pi=$((pi + 2)); fi
          walk_function "$save" ;;
        *=*) compound=0 ;; # an assignment word followed by `(` is an array, `a=(…)`
        *)
          # `name() body`: a word followed by `()`
          if [ $((pi + 2)) -lt "$pend" ] && [ "${TYP[pi + 1]}" = '(' ] && [ "${TYP[pi + 2]}" = ')' ]; then
            save=${TOK[pi]}; pi=$((pi + 3)); walk_function "$save"
          else
            compound=0
          fi ;;
      esac ;;
    *) compound=0 ;;
  esac
  [ "$compound" = 1 ] || { walk_simple; return 0; }
  # Redirections after a compound command: one on stdin feeds every shell
  # inside it that would otherwise read the hook's stdin.
  while [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = '>' ]; do
    if redir_stdin "${TOK[pi]}" && [ "$bare_shells" -gt "$bare" ]; then refuse "$opaque_msg"; fi
    redir_skip
  done
}

# redir_stdin <operator>: 0 when the redirection changes stdin
redir_stdin() {
  case $1 in '<'* | '0<'*) return 0 ;; esac
  return 1
}

# redir_skip: step over the redirection at pi and its target word (`<<` has
# none: the here-document is a scanned sub-text of its own)
redir_skip() {
  local op=${TOK[pi]}
  pi=$((pi + 1))
  case $op in *'<<<') ;; *'<<') return 0 ;; esac
  while [ "$pi" -lt "$pend" ]; do
    case ${TYP[pi]} in
      w | u) pi=$((pi + 1)); return 0 ;;
      '[') skip_one ;;
      ']') pi=$((pi + 1)) ;;
      *) return 0 ;;
    esac
  done
}

# walk_function <name>: the body runs later, from wherever the call is made,
# so it is walked as an unknown directory (a commit in it without an
# absolute `-C` is unknown); a body that touches the directory, or a name
# that shadows a word this hook interprets, makes every later call unknown.
walk_function() {
  local save=$cur sdt=$DIR_TOUCHED sst=$SH_TOUCHED ssh moved shell bare=$bare_shells nc=${#commit_dir[@]}
  sh_save; ssh=$SH_SAVED
  while [ "$pi" -lt "$pend" ] && [ "${TYP[pi]}" = ';' ] && [ "${TOK[pi]}" = $'\n' ]; do pi=$((pi + 1)); done
  cur='?' DIR_TOUCHED=0 SH_TOUCHED=0
  walk_cmd
  moved=$DIR_TOUCHED shell=$SH_TOUCHED
  cur=$save DIR_TOUCHED=$sdt SH_TOUCHED=$sst CD_SET=""
  sh_load "$ssh"
  if [ ${#commit_dir[@]} -gt "$nc" ]; then
    set_has "$FN_COMMITS" "$1" || FN_COMMITS=$FN_COMMITS${FN_COMMITS:+$'\n'}$1
  fi
  case " $interpreted " in *" $1 "*) moved=1 ;; esac
  if [ "$moved" = 1 ]; then
    set_has "$FN_MOVES" "$1" || FN_MOVES=$FN_MOVES${FN_MOVES:+$'\n'}$1
    DIR_TOUCHED=1 # a loop that (re)defines it may call it on a later pass
  fi
  if [ "$shell" = 1 ]; then
    set_has "$FN_SHELL" "$1" || FN_SHELL=$FN_SHELL${FN_SHELL:+$'\n'}$1
    SH_TOUCHED=1
  fi
  if [ "$bare_shells" -gt "$bare" ]; then
    set_has "$FN_BARE" "$1" || FN_BARE=$FN_BARE${FN_BARE:+$'\n'}$1
  fi
}

# walk_coproc: `coproc [NAME] command` runs in the background, in its own
# shell: nothing it does reaches the caller.
walk_coproc() {
  local save=$cur sdt=$DIR_TOUCHED sst=$SH_TOUCHED ssh
  sh_save; ssh=$SH_SAVED
  if [ $((pi + 1)) -lt "$pend" ] && [ "${TYP[pi]}" = w ]; then
    case ${TYP[pi + 1]}:${TOK[pi + 1]} in
      '(':* | w:'{' | w:if | w:while | w:until | w:for | w:select | w:case) pi=$((pi + 1)) ;;
    esac
  fi
  walk_cmd
  cur=$save CD_SET="" DIR_TOUCHED=$sdt SH_TOUCHED=$sst
  sh_load "$ssh"
}

# compound_done <entry> <exit>: cur back to <entry>; CD_SET = <exit> if it moved
compound_done() {
  cur=$1
  if [ "$2" = "$1" ]; then CD_SET=""; else CD_SET=$2; fi
}

# skip_one: step over one token; a scanned sub-text (`[`…`]`) is walked, scoped
skip_one() {
  local j depth save sdt sst ssh
  if [ "${TYP[pi]}" = '[' ]; then
    j=$((pi + 1)) depth=1
    while [ "$j" -lt "$pend" ] && [ "$depth" -gt 0 ]; do
      case ${TYP[j]} in '[') depth=$((depth + 1)) ;; ']') depth=$((depth - 1)) ;; esac
      j=$((j + 1))
    done
    save=$cur sdt=$DIR_TOUCHED sst=$SH_TOUCHED
    sh_save; ssh=$SH_SAVED
    walk_top $((pi + 1)) $((j - 1))
    cur=$save DIR_TOUCHED=$sdt SH_TOUCHED=$sst
    sh_load "$ssh"
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
  local entry=$cur acc=$cur sst=$SH_TOUCHED
  SH_TOUCHED=0
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
  branch_done "$sst" if
}

# branch_done <touched before> <construct>: a branch that ran at most once
# changed the shell (an export, say) — whether it ran is unknown.
branch_done() {
  if [ "$SH_TOUCHED" = 1 ]; then unknown_shell "a change of the shell under $2"; else SH_TOUCHED=$1; fi
}

# loop_done <entry> <first commit index> <touched before>: a loop body may
# run any number of times. When the body (or the condition) touched the
# directory, the set after the loop is unknown, and so is every commit
# recorded inside it — the walk saw one pass, the second starts elsewhere.
loop_done() { # loop_done <entry> <first commit index> <dir touched before> <shell touched before>
  local k=$2
  if [ "$DIR_TOUCHED" = 1 ] || [ "$SH_TOUCHED" = 1 ]; then
    while [ "$k" -lt ${#commit_dir[@]} ]; do commit_ok[k]=0; k=$((k + 1)); done
  fi
  if [ "$DIR_TOUCHED" = 1 ]; then compound_done "$1" '?'; else compound_done "$1" "$1"; DIR_TOUCHED=$3; fi
  # The same for the shell: a body that changed it may have run any number
  # of times, so what is in force after the loop is unknown.
  if [ "$SH_TOUCHED" = 1 ]; then unknown_shell "a loop that changed the shell"; else SH_TOUCHED=$4; fi
}

# walk_loop: `while|until … do … done`
walk_loop() {
  local entry=$cur sdt=$DIR_TOUCHED sst=$SH_TOUCHED nc=${#commit_dir[@]}
  DIR_TOUCHED=0 SH_TOUCHED=0
  walk_seq
  expect 'do'
  walk_seq
  expect 'done'
  loop_done "$entry" "$nc" "$sdt" "$sst"
}

# walk_for: `for x in … do … done`
walk_for() {
  local entry=$cur sdt=$DIR_TOUCHED sst=$SH_TOUCHED nc=${#commit_dir[@]}
  DIR_TOUCHED=0 SH_TOUCHED=0
  skip_to 'do'
  expect 'do'
  walk_seq
  expect 'done'
  loop_done "$entry" "$nc" "$sdt" "$sst"
}

# walk_case: `case … in pat) … ;; … esac`
walk_case() {
  local entry=$cur acc=$cur sst=$SH_TOUCHED
  SH_TOUCHED=0
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
  branch_done "$sst" case
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
  local stdin=0
  while [ "$pi" -lt "$pend" ]; do
    case ${TYP[pi]} in
      w) cw+=("${TOK[pi]}"); cwu+=(0); pi=$((pi + 1)) ;;
      u) cw+=("${TOK[pi]}"); cwu+=(1); pi=$((pi + 1)) ;;
      '>') redir_stdin "${TOK[pi]}" && stdin=1; redir_skip ;;
      '[') skip_one ;;
      ']') pi=$((pi + 1)) ;;
      *) break ;;
    esac
  done
  CD_SET=""
  [ ${#cw[@]} -gt 0 ] || return 0
  W=("${cw[@]}") WU=("${cwu[@]}") W_STDIN=$stdin
  simple
  [ -z "$CD_SET" ] || DIR_TOUCHED=1
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
