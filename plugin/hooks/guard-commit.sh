#!/usr/bin/env bash
# PreToolUse guard for Bash: refuse `git commit` while workspace files are staged.
#
# Reads the hook JSON on stdin. Exit 0 lets the call through; exit 2 blocks it
# and the message on stderr is shown to Claude.
#
# Refused staged paths:
#   - any `.claude/` or `.planning/` directory
#   - in a code repo, anything under `.relay/` (relay's own state belongs to
#     the workspace); in a workspace repo only `.relay/lock/` is refused, the
#     rest of `.relay/` (runs, LATEST, status.log, config) is the run log
#   - `*.local.md`, `settings.local.json`, `.DS_Store`
#   - workspace planning files: `docs/**/*.prompt-*.md`, `docs/WORKFLOW.md`,
#     `docs/PARKED.md`, `docs/scope/BASELINE_*.md` (a repo may carry its own
#     `docs/`; only these workspace-shaped names are refused). Skipped in a
#     workspace repo — one whose HEAD contains `docs/WORKFLOW.md` — where those
#     files are the content.

set -uo pipefail

input=$(cat)

json_field() {
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1 // empty" <<<"$input"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
d = json.loads(sys.argv[2])
for k in sys.argv[1].lstrip(".").split("."):
    d = d.get(k) if isinstance(d, dict) else None
print(d if isinstance(d, str) else "")
' "$1" "$input"
  else
    echo "guard-commit: neither jq nor python3 found; commit guard skipped" >&2
    exit 0
  fi
}

command=$(json_field .tool_input.command)
dir=$(json_field .cwd)
[ -n "$dir" ] || dir=$PWD

# Strip leading whitespace, then one leading `cd <dir> &&`, which is how
# commits are usually issued from a workspace root.
command="${command#"${command%%[![:space:]]*}"}"
if [[ $command =~ ^cd[[:space:]]+([^[:space:]\&\;]+)[[:space:]]*\&\&[[:space:]]*(.*)$ ]]; then
  target=${BASH_REMATCH[1]}
  target=${target/#\~/$HOME}
  case $target in /*) dir=$target ;; *) dir=$dir/$target ;; esac
  command=${BASH_REMATCH[2]}
fi

case $command in
  "git commit" | "git commit "*) ;;
  *) exit 0 ;;
esac

top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
staged=$(git -C "$top" diff --cached --name-only 2>/dev/null) || exit 0
[ -n "$staged" ] || exit 0

# The marker must already be in HEAD (or, in a repo with no commits yet, on
# disk), so staging a WORKFLOW.md does not make a code repo a workspace.
workspace_repo=0
if git -C "$top" rev-parse --verify -q HEAD >/dev/null; then
  git -C "$top" cat-file -e HEAD:docs/WORKFLOW.md 2>/dev/null && workspace_repo=1
elif [ -f "$top/docs/WORKFLOW.md" ]; then
  workspace_repo=1
fi

bad=()
while IFS= read -r path; do
  base=${path##*/}
  case "/$path/" in
    */.claude/* | */.planning/*) bad+=("$path"); continue ;;
  esac
  case $base in
    *.local.md | settings.local.json | .DS_Store) bad+=("$path"); continue ;;
  esac
  case "/$path" in
    */.relay/lock/*) bad+=("$path"); continue ;;
    */.relay/*) [ "$workspace_repo" = 1 ] || { bad+=("$path"); continue; } ;;
  esac
  [ "$workspace_repo" = 1 ] && continue
  case $path in
    docs/*.prompt-*.md | docs/WORKFLOW.md | docs/PARKED.md | docs/scope/BASELINE_*.md)
      bad+=("$path"); continue ;;
  esac
done <<<"$staged"

[ ${#bad[@]} -eq 0 ] && exit 0

{
  echo "Commit refused: workspace files are staged in $top:"
  printf '  %s\n' "${bad[@]}"
  echo "Unstage them (git restore --staged <path>) and keep them out of the repo."
} >&2
exit 2
