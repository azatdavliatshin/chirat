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
# unquoted delimiter are scanned too, in their own scope. Nothing is ever
# expanded, evaluated or executed: `$VAR`, `${…}`, `$(…)`, backticks, globs
# and `~user` leave a word *unresolved*. Each simple command loses leading
# `VAR=value` assignments and the wrappers `command`, `env`, `exec`, `sudo`,
# `nohup`, `time`, `nice`, `timeout`, `xargs`; for `git`, global options are
# walked to find the subcommand, so `git stash push` and `git log --grep push`
# pass.
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
cur_known=1 # 0 once a `cd` went somewhere the hook cannot name

refuse() { # refuse <message>
  echo "$1" >&2
  exit 2
}

# resolve <base> <dir>: print <dir> made absolute against <base>.
resolve() {
  local d=$2
  # shellcheck disable=SC2088 # a literal ~ to expand by hand
  case $d in "~") d=$HOME ;; "~/"*) d=$HOME/${d#"~/"} ;; esac
  case $d in /*) printf '%s' "$d" ;; *) printf '%s' "$1/$d" ;; esac
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
      ';') emit_op ';'; pos=$((pos + 1)); [ "${s:pos:1}" = ';' ] && pos=$((pos + 1)) ;;
      '|') emit_op ';'; pos=$((pos + 1)); case ${s:pos:1} in '|' | '&') pos=$((pos + 1)) ;; esac ;;
      '&')
        nx=${s:pos+1:1}
        if [ "$nx" = '&' ]; then emit_op ';'; pos=$((pos + 2))
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

# lex_brace: `${` was consumed; skip to the matching `}`, scanning any `$(…)`
# or backticks inside (`${x:-$(git push)}`).
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
          *) pos=$((pos + 1)) ;;
        esac ;;
      '`') lex_backtick || return 1 ;;
      '"')
        pos=$((pos + 1))
        while [ "$pos" -lt "$n" ]; do
          c=${s:pos:1}
          case $c in '"') break ;; '\') pos=$((pos + 2)); continue ;; esac
          pos=$((pos + 1))
        done
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

# --- walking the simple commands ---------------------------------------------

commit_dir=() commit_gitdir=() commit_wt=() commit_ok=()
cur_stack=()
W=() WU=()

# dir_apply <known> <base> <value> <unresolved>: sets R_KNOWN and R_DIR to
# <value> taken against <base>
dir_apply() {
  if [ "$4" = 1 ]; then R_KNOWN=0 R_DIR=""
  elif [ "$1" = 1 ]; then R_KNOWN=1 R_DIR=$(resolve "$2" "$3")
  else case $3 in /*) R_KNOWN=1 R_DIR=$3 ;; *) R_KNOWN=0 R_DIR="" ;; esac
  fi
}

# scan_text <text> <inline|scoped>: lex <text> and walk it; scoped (a child
# shell) cannot change the caller's directory, inline (eval) can
scan_text() {
  local start end sc sk
  start=${#TOK[@]}
  lex_text "$1" || refuse "chirat: cannot parse this command ($lex_err); fix the quoting or split it."
  end=${#TOK[@]}
  sc=$cur sk=$cur_known
  walk "$start" "$end"
  [ "$2" = inline ] || { cur=$sc; cur_known=$sk; }
}

# simple: one simple command, words in W, unresolved flags in WU
simple() {
  local -a words=(${W[@]+"${W[@]}"}) unres=(${WU[@]+"${WU[@]}"})
  local nw=${#words[@]} i=0 w0 argv0 v u sub subu dir known gitdir worktree gu prev body
  local scur=$cur sknown=$cur_known env_gitdir="" env_wt="" envu=0

  # Drop assignments, redirections, shell keywords and wrappers.
  while [ "$i" -lt "$nw" ]; do
    w0=${words[i]}
    case $w0 in
      GIT_DIR=*) env_gitdir=${w0#*=}; [ "${unres[i]}" = 0 ] || envu=1; i=$((i + 1)) ;;
      GIT_WORK_TREE=*) env_wt=${w0#*=}; [ "${unres[i]}" = 0 ] || envu=1; i=$((i + 1)) ;;
      [A-Za-z_]*=* | [0-9]\>* | [0-9]\<* | \>* | \<* | \{ | \} | \! | if | then | else | elif | do | while | until)
        i=$((i + 1)) ;;
      eval)
        body=""
        i=$((i + 1))
        while [ "$i" -lt "$nw" ]; do body="$body${body:+ }${words[i]}"; i=$((i + 1)); done
        [ -z "$body" ] || scan_text "$body" inline
        return 0 ;;
      command | exec | nohup | time | xargs | nice | env | sudo | timeout | sh | bash | zsh | dash | */sh | */bash | */zsh)
        i=$((i + 1))
        while [ "$i" -lt "$nw" ]; do
          v=${words[i]} u=${unres[i]}
          case "$w0 $v" in
            "env -C" | "env --chdir")
              if [ $((i + 1)) -lt "$nw" ]; then
                dir_apply "$sknown" "$scur" "${words[i + 1]}" "${unres[i + 1]}"
                sknown=$R_KNOWN scur=$R_DIR
              fi
              i=$((i + 2)) ;;
            "env --chdir="*)
              dir_apply "$sknown" "$scur" "${v#*=}" "$u"
              sknown=$R_KNOWN scur=$R_DIR
              i=$((i + 1)) ;;
            # Wrapper options that take a value.
            "env -u" | "env -P" | "nice -n" | "timeout -s" | "timeout -k" | \
              "sudo -u" | "sudo -g" | "sudo -U" | "sudo -C" | "sudo -D" | "sudo -h" | \
              "sudo -p" | "sudo -r" | "sudo -t" | "sudo -T" | "xargs -I" | "xargs -L" | \
              "xargs -n" | "xargs -P" | "xargs -s" | "xargs -d" | "xargs -E" | "xargs -a")
              i=$((i + 2)) ;;
            # `sh -c <body>`, also `-lc`, `-ec`: the body is a script of its own.
            *"sh -"[!-]*)
              case $v in
                *c*)
                  [ $((i + 1)) -lt "$nw" ] && scan_text "${words[i + 1]}" scoped
                  return 0 ;;
              esac
              i=$((i + 1)) ;;
            "env GIT_DIR="*) env_gitdir=${v#*=}; [ "$u" = 0 ] || envu=1; i=$((i + 1)) ;;
            "env GIT_WORK_TREE="*) env_wt=${v#*=}; [ "$u" = 0 ] || envu=1; i=$((i + 1)) ;;
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
          cur_known=0
        else
          dir_apply "$cur_known" "$cur" "${words[i]}" "${unres[i]}"
          cur_known=$R_KNOWN cur=$R_DIR
        fi
      else
        cur=$HOME cur_known=1
      fi ;;
    popd) cur_known=0 ;;
    git | */git)
      dir=$scur known=$sknown gitdir=$env_gitdir worktree=$env_wt gu=$envu
      sub="" subu=0
      while [ "$i" -lt "$nw" ]; do
        v=${words[i]} u=${unres[i]}
        case $v in
          -C)
            if [ $((i + 1)) -lt "$nw" ]; then
              dir_apply "$known" "$dir" "${words[i + 1]}" "${unres[i + 1]}"
              known=$R_KNOWN dir=$R_DIR
            fi
            i=$((i + 2)) ;;
          -C?*)
            dir_apply "$known" "$dir" "${v#-C}" "$u"
            known=$R_KNOWN dir=$R_DIR
            i=$((i + 1)) ;;
          --git-dir=*)
            dir_apply "$known" "$dir" "${v#*=}" "$u"
            [ "$R_KNOWN" = 1 ] && gitdir=$R_DIR || gu=1
            i=$((i + 1)) ;;
          --work-tree=*)
            dir_apply "$known" "$dir" "${v#*=}" "$u"
            [ "$R_KNOWN" = 1 ] && worktree=$R_DIR || gu=1
            i=$((i + 1)) ;;
          --git-dir | --work-tree)
            if [ $((i + 1)) -lt "$nw" ]; then
              dir_apply "$known" "$dir" "${words[i + 1]}" "${unres[i + 1]}"
              if [ "$R_KNOWN" = 1 ]; then
                if [ "$v" = --git-dir ]; then gitdir=$R_DIR; else worktree=$R_DIR; fi
              else gu=1; fi
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
          if [ "$known" = 1 ] && [ "$gu" = 0 ]; then commit_ok+=(1); else commit_ok+=(0); fi ;;
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

# walk <start> <end>: the tokens in [start, end)
walk() {
  local i=$1 end=$2 t j depth sc sk top
  local -a cw=() cwu=()
  flush() {
    [ ${#cw[@]} -gt 0 ] || return 0
    W=("${cw[@]}") WU=("${cwu[@]}")
    cw=() cwu=()
    simple
  }
  while [ "$i" -lt "$end" ]; do
    t=${TYP[i]}
    case $t in
      w) cw+=("${TOK[i]}"); cwu+=(0) ;;
      u) cw+=("${TOK[i]}"); cwu+=(1) ;;
      ';') flush ;;
      '(') flush; cur_stack+=("$cur_known $cur") ;;
      ')')
        flush
        if [ ${#cur_stack[@]} -gt 0 ]; then
          top=${cur_stack[${#cur_stack[@]} - 1]}
          unset 'cur_stack[${#cur_stack[@]}-1]'
          cur_known=${top%% *} cur=${top#* }
        fi ;;
      '[')
        j=$((i + 1)) depth=1
        while [ "$j" -lt "$end" ] && [ "$depth" -gt 0 ]; do
          case ${TYP[j]} in '[') depth=$((depth + 1)) ;; ']') depth=$((depth - 1)) ;; esac
          j=$((j + 1))
        done
        sc=$cur sk=$cur_known
        walk $((i + 1)) $((j - 1))
        cur=$sc cur_known=$sk
        i=$((j - 1)) ;;
      ']') ;;
    esac
    i=$((i + 1))
  done
  flush
}

lex_text "$command" || refuse "chirat: cannot parse this command ($lex_err); fix the quoting or split it."
walk 0 ${#TOK[@]}

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

refused=""
k=0
while [ "$k" -lt ${#commit_dir[@]} ]; do
  [ "${commit_ok[k]}" = 1 ] || refuse "$unres_msg (the target is not literal: a variable, substitution, glob or an unknown current directory)."
  out=$(check_commit "${commit_dir[k]}" "${commit_gitdir[k]}" "${commit_wt[k]}")
  case $refused in *"$out"*) ;; *) refused=$refused$out ;; esac
  k=$((k + 1))
done

[ -n "$refused" ] || exit 0
printf '%s\n' "$refused" >&2
exit 2
