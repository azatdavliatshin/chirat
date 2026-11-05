#!/usr/bin/env bash
# Tests for bin/chirat-init in a throwaway parent directory.
# Usage: tests/chirat-init.sh

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
init=$root/bin/chirat-init

tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

# A throwaway HOME with no global git identity: whatever identity a commit
# carries, chirat-init gave it.
export HOME=$tmp/home GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME
mkdir -p "$HOME"

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
ko() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "     $2"; }

eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected [$2], got [$3]"; fi
}

has() { # has <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then ok "$1"; else ko "$1" "no [$3] in $2"; fi
}

exists() { # exists <name> <test flag> <path>
  if test "$2" "$3"; then ok "$1"; else ko "$1" "test $2 $3 is false"; fi
}

absent() { # absent <name> <path>
  if [ -e "$2" ]; then ko "$1" "$2 exists"; else ok "$1"; fi
}

# --- usage ---------------------------------------------------------------

if "$init" demo "$tmp" --git-name "Demo User" >/dev/null 2>&1; then
  ko "usage: missing --git-email exits non-zero"
else
  ok "usage: missing --git-email exits non-zero"
fi
absent "usage: nothing created on usage error" "$tmp/demo"

"$init" -h >"$tmp/help.out" 2>&1
eq "-h exits 0" 0 $?
has "-h explains <name>" "$tmp/help.out" "<name>   folder name of the workspace"
has "-h explains [dir]" "$tmp/help.out" "[dir]    parent folder"
has "-h recommends <project>-workspace" "$tmp/help.out" "<project>-workspace (e.g. mvg-workspace)"
has "-h states the --branch limitation" "$tmp/help.out" "one --branch applies to every --repo"

# --- happy path ----------------------------------------------------------

key=$tmp/id_demo
echo "fake key" >"$key"
out=$("$init" demo "$tmp" --git-name "Demo User" --git-email demo@example.com \
  --ssh-key "$key" --description "A & B, \\1 backrefs, {{not a placeholder}}" 2>"$tmp/stderr")
eq "init exits 0" 0 $?
ws=$tmp/demo

exists "CLAUDE.md.in renamed to CLAUDE.md" -f "$ws/CLAUDE.md"
absent "no CLAUDE.md.in left behind" "$ws/CLAUDE.md.in"
has "{{NAME}} filled" "$ws/CLAUDE.md" "# demo — AI workspace"
has "{{DESCRIPTION}} filled verbatim" "$ws/CLAUDE.md" 'A & B, \1 backrefs, {{not a placeholder}}'
if grep -rqF '{{NAME}}' "$ws" || grep -rqF '{{DESCRIPTION}}' "$ws"; then
  ko "no placeholder left anywhere" "$(grep -rlF '{{NAME}}' "$ws"; grep -rlF '{{DESCRIPTION}}' "$ws")"
else
  ok "no placeholder left anywhere"
fi

exists "settings moved to .claude/settings.local.json" -f "$ws/.claude/settings.local.json"
absent "dot-claude removed" "$ws/dot-claude"
for d in docs/plans docs/status docs/scope repos; do
  exists "layout has $d" -d "$ws/$d"
done
exists "layout has docs/WORKFLOW.md" -f "$ws/docs/WORKFLOW.md"

# --- .gitconfig ----------------------------------------------------------

eq ".gitconfig user.name" "Demo User" "$(git config -f "$ws/.gitconfig" user.name)"
eq ".gitconfig user.email" demo@example.com "$(git config -f "$ws/.gitconfig" user.email)"
eq ".gitconfig core.sshCommand" "ssh -i '$key' -o IdentitiesOnly=yes" "$(git config -f "$ws/.gitconfig" core.sshCommand)"
eq ".gitconfig has no other keys" 3 "$(git config -f "$ws/.gitconfig" --list | wc -l | tr -d ' ')"

# --- workspace git repository -------------------------------------------

eq "git rev-parse works in the workspace" "true" "$(git -C "$ws" rev-parse --is-inside-work-tree 2>/dev/null)"
eq "workspace branch is main" main "$(git -C "$ws" symbolic-ref --short HEAD 2>/dev/null)"
eq "first commit is the bootstrap" "docs: workspace bootstrap" "$(git -C "$ws" log --format=%s 2>/dev/null)"
eq "first commit carries --git-name" "Demo User" "$(git -C "$ws" log -1 --format=%an 2>/dev/null)"
eq "first commit carries --git-email" demo@example.com "$(git -C "$ws" log -1 --format=%ae 2>/dev/null)"
eq "first commit leaves the tree clean" "" "$(git -C "$ws" status --porcelain 2>/dev/null)"
eq ".gitignore content" "$(printf 'repos/\n.claude/\n.DS_Store\n.chirat/lock/\n.chirat/review/')" "$(cat "$ws/.gitignore")"
mkdir -p "$ws/repos/x"
echo "y" >"$ws/repos/x/file"
touch "$ws/.DS_Store"
if git -C "$ws" status --porcelain --ignored | grep -q '^!! repos/'; then
  ok "repos/ is ignored by the workspace repo"
else
  ko "repos/ is ignored by the workspace repo" "$(git -C "$ws" status --porcelain --ignored)"
fi
if git -C "$ws" status --porcelain | grep -q 'DS_Store'; then
  ko ".DS_Store is ignored by the workspace repo"
else
  ok ".DS_Store is ignored by the workspace repo"
fi
exists ".chirat/config exists in a new workspace" -f "$ws/.chirat/config"
has ".chirat/config documents plans_dir" "$ws/.chirat/config" "# plans_dir=docs/plans"
has ".gitignore has .chirat/lock/" "$ws/.gitignore" ".chirat/lock/"
has ".gitignore has .chirat/review/" "$ws/.gitignore" ".chirat/review/"
exists "template ships docs/qa/diff2html.py" -f "$ws/docs/qa/diff2html.py"
absent "dot-chirat is renamed" "$ws/dot-chirat"
if git -C "$ws" status --porcelain --ignored | grep -q '^!! .claude/'; then
  ok ".claude/ is ignored by the workspace repo"
else
  ko ".claude/ is ignored by the workspace repo" "$(git -C "$ws" status --porcelain --ignored)"
fi

# --- output --------------------------------------------------------------

says() { # says <name> <text> <fixed string>
  case $2 in *"$3"*) ok "$1" ;; *) ko "$1" "no [$3] in: $2" ;; esac
}
not_says() { # not_says <name> <text> <fixed string>
  case $2 in *"$3"*) ko "$1" "[$3] in: $2" ;; *) ok "$1" ;; esac
}
placeholders() { # placeholders <text>: command lines with < or >, the >> of the register step aside
  printf '%s\n' "$1" | sed 's/^ *//' | grep -E '^(git|mkdir|gh|chirat-watch|echo) ' | sed 's/ >> / /g' | grep '[<>]'
}

says "output: header says one commit" "$out" "Created workspace: $ws (git repository, branch main, 1 commit)"
says "output: includeIf command" "$out" "git config --global --add includeIf.\"gitdir:$ws/\".path \"$ws/.gitconfig\""
says "output: mkdir -p before registering" "$out" "mkdir -p ~/.config/chirat && echo \"$ws\" >> ~/.config/chirat/workspaces"
says "output: doctor closes the steps" "$out" "chirat-watch doctor \"$ws\""
says "output: clone step" "$out" "git clone URL \"$ws/repos/NAME\""
says "output: default_branch hint" "$out" "set default_branch= in \"$ws/.chirat/config\""
says "output: plugin install" "$out" "/plugin install chirat@chirat"
says "output: notify_open hint without --project" "$out" "set notify_open= in \"$ws/.chirat/config\""
says "output: OWNER explained" "$out" "OWNER = your GitHub user or organization"
says "output: remote add" "$out" "git -C \"$ws\" remote add origin git@github.com:OWNER/demo.git"
says "output: create the empty repo first" "$out" "Create an empty private repo first"
says "output: remote hint ends with a manual push" "$out" "git -C \"$ws\" push -u origin main"
says "output: gh alternative" "$out" "gh repo create OWNER/demo --private --source \"$ws\" --remote origin --push"
not_says "output: no BASELINE" "$out" "BASELINE"
not_says "output: no commit step after the commit" "$out" "First commit"
eq "output: no placeholder in a command line" "" "$(placeholders "$out")"
order=$(printf '%s\n' "$out" | grep -oE 'includeIf\.|git clone URL|install$|mkdir -p|root folder|chirat-watch doctor' | tr '\n' ' ')
eq "output: steps in order" "includeIf. git clone URL install mkdir -p root folder chirat-watch doctor " "$order"

# --- pasted lines work, also in a path with spaces -----------------------

spaced="$tmp/with space"
sout=$("$init" spaced "$spaced" --git-name "S" --git-email s@example.com 2>&1)
eq "path with a space: exit 0" 0 $?
sws=$spaced/spaced
eval "$(printf '%s\n' "$sout" | grep 'git config --global --add includeIf')"
eq "pasted includeIf line: git sees the identity" s@example.com "$(git -C "$sws" config user.email)"
eval "$(printf '%s\n' "$sout" | grep 'mkdir -p ')"
eq "pasted register line: the workspace is listed" "$sws" "$(cat "$HOME/.config/chirat/workspaces")"
rm -rf "$HOME/.gitconfig" "$HOME/.config"

# --- symlinked parent: includeIf needs the physical path -----------------

mkdir -p "$tmp/real"
ln -s "$tmp/real" "$tmp/link"
lout=$("$init" linked "$tmp/link" --git-name "L" --git-email l@example.com 2>&1)
says "symlinked parent: physical path printed" "$lout" "Created workspace: $tmp/real/linked "
eval "$(printf '%s\n' "$lout" | grep 'git config --global --add includeIf')"
eq "symlinked parent: pasted includeIf line works" l@example.com "$(git -C "$tmp/real/linked" config user.email)"
rm -f "$HOME/.gitconfig"

# --- no ssh key, default description, aliases ----------------------------

"$init" plain "$tmp" --name "P" --email p@example.com >/dev/null 2>&1
eq "init without --ssh-key exits 0" 0 $?
if git config -f "$tmp/plain/.gitconfig" core.sshCommand >/dev/null 2>&1; then
  ko "no core.sshCommand without --ssh-key"
else
  ok "no core.sshCommand without --ssh-key"
fi
has "default description is a TODO" "$tmp/plain/CLAUDE.md" "TODO: one paragraph on what plain is."
"$init" plain2 "$tmp" --git-name "P" --git-email p@example.com >/dev/null 2>&1
eq "--git-name and --name give the same .gitconfig" "$(cat "$tmp/plain/.gitconfig")" "$(cat "$tmp/plain2/.gitconfig")"

# --- first commit: opt-out and failure -----------------------------------

ncout=$("$init" nocommit "$tmp" --git-name "N" --git-email n@example.com --no-commit 2>&1)
eq "--no-commit exits 0" 0 $?
eq "--no-commit leaves no commit" "" "$(git -C "$tmp/nocommit" log --oneline 2>/dev/null)"
eq "--no-commit stages nothing" "" "$(git -C "$tmp/nocommit" diff --cached --name-only 2>/dev/null)"
says "--no-commit: header" "$ncout" "nothing committed yet"
says "--no-commit: commit step" "$ncout" "git -C \"$tmp/nocommit\" add -A && git -C \"$tmp/nocommit\" commit -m \"docs: workspace bootstrap\""

printf '[commit]\n  gpgsign = true\n[gpg]\n  program = false\n' >"$HOME/.gitconfig"
fout=$("$init" gpgfail "$tmp" --git-name "G H" --git-email g@example.com 2>&1)
eq "failed commit still exits 0" 0 $?
says "failed commit warns" "$fout" "warning: first commit failed"
retry="git -C \"$tmp/gpgfail\" -c user.name=\"G H\" -c user.email=\"g@example.com\" commit -m \"docs: workspace bootstrap\""
says "failed commit prints the retry line" "$fout" "$retry"
eq "failed commit: nothing committed" "" "$(git -C "$tmp/gpgfail" log --oneline 2>/dev/null)"
has "failed commit: files stay staged" <(git -C "$tmp/gpgfail" diff --cached --name-only) "CLAUDE.md"
rm -f "$HOME/.gitconfig"
eval "$retry -q"
eq "retry line works" "docs: workspace bootstrap" "$(git -C "$tmp/gpgfail" log --format=%s)"
eq "retry line commits with the identity" "G H" "$(git -C "$tmp/gpgfail" log -1 --format=%an)"

# --- --repo / --branch ---------------------------------------------------

mkbare() { # mkbare <name> [rules file]: <tmp>/remotes/<name>.git, branches main and x
  local src=$tmp/src/$1
  git init -q -b main "$src"
  echo hi >"$src/README"
  [ -z "${2:-}" ] || echo rules >"$src/$2"
  git -C "$src" add -A
  git -C "$src" -c user.name=T -c user.email=t@example.com commit -q -m init
  git -C "$src" branch x
  git clone -q --bare "$src" "$tmp/remotes/$1.git"
}
mkbare app
mkbare withagents AGENTS.md
mkbare withclaude CLAUDE.md

rout=$("$init" r1 "$tmp" --git-name "R" --git-email r@example.com --repo "$tmp/remotes/app.git" 2>&1)
eq "--repo exits 0" 0 $?
exists "--repo clones into repos/<name>" -d "$tmp/r1/repos/app/.git"
eq "--repo checks out the default" main "$(git -C "$tmp/r1/repos/app" symbolic-ref --short HEAD)"
has "without --branch default_branch stays commented" "$tmp/r1/.chirat/config" "# default_branch=main"
not_says "--repo ok: no clone step" "$rout" "git clone"
not_says "--repo ok: no clone wording" "$rout" "Clone "
if grep -q '^## The code repository' "$tmp/r1/CLAUDE.md"; then ko "no rules file: no section"; else ok "no rules file: no section"; fi
eq "--repo: still one commit" 1 "$(git -C "$tmp/r1" rev-list --count HEAD)"

bad=$tmp/remotes/missing.git
rout=$("$init" r2 "$tmp" --git-name "R" --git-email r@example.com --repo "$bad" 2>&1)
eq "bad url exits 0" 0 $?
says "bad url warns" "$rout" "warning: clone failed: $bad"
says "bad url: manual clone line" "$rout" "git clone \"$bad\" \"$tmp/r2/repos/missing\""
exists "bad url: the workspace is complete" -f "$tmp/r2/CLAUDE.md"

rout=$("$init" r3 "$tmp" --git-name "R" --git-email r@example.com --repo "$tmp/remotes/app.git" --branch x 2>&1)
eq "--branch exits 0" 0 $?
eq "--branch clones that branch" x "$(git -C "$tmp/r3/repos/app" symbolic-ref --short HEAD)"
eq "--branch: default_branch line uncommented" "default_branch=x" "$(grep -E '^default_branch=' "$tmp/r3/.chirat/config")"
eq "--branch: the config change is in the commit" "" "$(git -C "$tmp/r3" status --porcelain)"
if "$init" r4 "$tmp" --git-name "R" --git-email r@example.com --branch x >/dev/null 2>&1; then
  ko "--branch without --repo is refused"
else
  ok "--branch without --repo is refused"
fi
absent "--branch without --repo: nothing created" "$tmp/r4"
rout=$("$init" r5 "$tmp" --git-name "R" --git-email r@example.com --repo "$bad" --branch x 2>&1)
says "bad url with --branch: manual line carries it" "$rout" "git clone --branch \"x\" \"$bad\" \"$tmp/r5/repos/missing\""

# --- rules files in the clones -------------------------------------------

"$init" r6 "$tmp" --git-name "R" --git-email r@example.com \
  --repo "$tmp/remotes/withagents.git" --repo "$tmp/remotes/app.git" --repo "$tmp/remotes/withclaude.git" >/dev/null 2>&1
eq "two rules files: one section" 1 "$(grep -c '^## The code repository' "$tmp/r6/CLAUDE.md")"
eq "two rules files: two lines" 2 "$(grep -c 'is canonical; read it first' "$tmp/r6/CLAUDE.md")"
# shellcheck disable=SC2016 # literal backticks
has "AGENTS.md pointer" "$tmp/r6/CLAUDE.md" '- `repos/withagents/` — its own rules file `repos/withagents/AGENTS.md` is canonical; read it first.'
# shellcheck disable=SC2016 # literal backticks
has "CLAUDE.md pointer names the file found" "$tmp/r6/CLAUDE.md" '`repos/withclaude/CLAUDE.md`'
eq "section is in the one bootstrap commit" 1 "$(git -C "$tmp/r6" rev-list --count HEAD)"
eq "section leaves the tree clean" "" "$(git -C "$tmp/r6" status --porcelain)"
eq "amended commit keeps the identity" r@example.com "$(git -C "$tmp/r6" log -1 --format=%ae)"
"$init" r7 "$tmp" --git-name "R" --git-email r@example.com --no-commit --repo "$tmp/remotes/withagents.git" >/dev/null 2>&1
eq "section with --no-commit: still no commit" "" "$(git -C "$tmp/r7" log --oneline 2>/dev/null)"
has "section with --no-commit: written" "$tmp/r7/CLAUDE.md" "## The code repository"

# --ssh-key reaches the clone although includeIf is not in place yet
mkdir -p "$tmp/fakebin"
cat >"$tmp/fakebin/ssh" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/ssh.log"
exit 1
EOF
chmod +x "$tmp/fakebin/ssh"
PATH=$tmp/fakebin:$PATH "$init" r8 "$tmp" --git-name "R" --git-email r@example.com --ssh-key "$key" \
  --repo git@example.invalid:owner/app.git >"$tmp/r8.out" 2>&1
eq "ssh clone failure exits 0" 0 $?
has "--ssh-key is used for the clone" "$tmp/ssh.log" "-i $key -o IdentitiesOnly=yes"
has "scp-style url: folder name" "$tmp/r8.out" "\"$tmp/r8/repos/app\""

# --- --project -----------------------------------------------------------

id=00000000-0000-4000-8000-000000000000
"$init" p1 "$tmp" --git-name "P" --git-email p@example.com --project "$id" >"$tmp/p1.out" 2>&1
eq "--project uuid: notify_open" "notify_open=claude://claude.ai/project/$id" "$(grep -E '^notify_open=' "$tmp/p1/.chirat/config")"
if grep -q 'set notify_open=' "$tmp/p1.out"; then ko "--project: no notify_open hint"; else ok "--project: no notify_open hint"; fi
"$init" p2 "$tmp" --git-name "P" --git-email p@example.com --project "https://claude.ai/project/$id" >/dev/null 2>&1
eq "--project url: notify_open" "notify_open=claude://claude.ai/project/$id" "$(grep -E '^notify_open=' "$tmp/p2/.chirat/config")"
if "$init" p3 "$tmp/newparent" --git-name "P" --git-email p@example.com --project "not-a-uuid" >/dev/null 2>"$tmp/stderr"; then
  ko "--project: non-uuid is rejected"
else
  ok "--project: non-uuid is rejected"
fi
has "--project: the error says why" "$tmp/stderr" "not a project uuid"
absent "--project: rejected before anything is created" "$tmp/newparent"

# --- template ------------------------------------------------------------

settings=$ws/.claude/settings.local.json
for noise in 'bin/*' shellcheck 'plugin validate' 'tmux ls'; do
  if grep -qF -- "$noise" "$settings"; then ko "settings: no [$noise]"; else ok "settings: no [$noise]"; fi
done
has "settings: base list has git" "$settings" '"Bash(git *)"'
has "settings: base list has npm test" "$settings" '"Bash(npm test)"'
has "settings: base list has chirat-prompt" "$settings" '"Bash(chirat-prompt *)"'
has "CLAUDE.md: says where to add commands" "$ws/CLAUDE.md" 'permissions.allow'
has "settings: deny git push" "$settings" '"Bash(git push *)"'
has "settings: deny git -C push" "$settings" '"Bash(git -C * push*)"'
has "settings: deny npm publish" "$settings" '"Bash(npm publish*)"'
has "settings: deny skip-permissions" "$settings" '"Bash(claude --dangerously-skip-permissions*)"'
if command -v python3 >/dev/null 2>&1; then
  if python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$settings"; then ok "settings: valid JSON"; else ko "settings: valid JSON"; fi
  eq "settings: top-level keys are exactly permissions" "permissions" "$(python3 -I -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])))))' "$settings")"
  eq "settings: deny rules" "Bash(npm publish*)|Bash(git push)|Bash(git push *)|Bash(git -C * push*)|Bash(claude --dangerously-skip-permissions*)" "$(python3 -I -c 'import json,sys; print("|".join(json.load(open(sys.argv[1]))["permissions"]["deny"]))' "$settings")"
fi
if grep -qF 'chirat@chirat' "$ws/CLAUDE.md"; then ko "CLAUDE.md Landing: no chirat@chirat"; else ok "CLAUDE.md Landing: no chirat@chirat"; fi
has "CLAUDE.md Landing: heading kept" "$ws/CLAUDE.md" "## Landing"
has "CLAUDE.md Landing: format line" "$ws/CLAUDE.md" "- <path prefix> → <command>"
has "WORKFLOW: docs/scope is optional" "$ws/docs/WORKFLOW.md" "optional: dated BASELINE"

# --- refuses overwrite ---------------------------------------------------

echo "keep" >"$ws/marker"
if "$init" demo "$tmp" --name "Demo User" --email demo@example.com >/dev/null 2>"$tmp/stderr"; then
  ko "refuses to overwrite an existing workspace"
else
  ok "refuses to overwrite an existing workspace"
fi
has "overwrite refusal names the path" "$tmp/stderr" "already exists, not overwriting: $ws"
eq "existing workspace untouched" keep "$(cat "$ws/marker")"

# --- invalid names -------------------------------------------------------

for bad in "a/b" ".hidden" "two words"; do
  if "$init" "$bad" "$tmp" --name "P" --email p@example.com >/dev/null 2>&1; then
    ko "rejects name [$bad]"
  else
    ok "rejects name [$bad]"
  fi
done

# --- poll fingerprint ----------------------------------------------------

fpline=$(grep '^W=' "$root/plugin/skills/poll/SKILL.md")
fp() { bash -c "$(printf '%s' "$fpline" | sed "s|^W=[^;]*;|W=$ws;|")"; }
mkdir -p "$ws/.chirat/runs"
printf -- '---\nmodel: sonnet\nstatus: pending\nrepo: r\nbranch: b\n---\n' >"$ws/docs/plans/t.prompt-1.md"
fp1=$(fp)
eq "fingerprint is stable" "$fp1" "$(fp)"
if [ -n "$fp1" ]; then ok "fingerprint is not empty"; else ko "fingerprint is not empty"; fi
sed -i.bak 's/^status: pending/status: running/' "$ws/docs/plans/t.prompt-1.md"
rm -f "$ws/docs/plans/t.prompt-1.md.bak"
if [ "$fp1" != "$(fp)" ]; then ok "fingerprint changes with a status flip"; else ko "fingerprint changes with a status flip"; fi

# --- summary -------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
