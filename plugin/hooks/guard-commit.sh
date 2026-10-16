#!/usr/bin/env bash
# PreToolUse guard for Bash: refuse `git commit` while workspace files are staged.
#
# Reads the hook JSON on stdin. Exit 0 lets the call through; exit 2 blocks it
# and the message on stderr is shown to Claude.
#
# Refused staged paths:
#   - any `.claude/` or `.planning/` directory
#   - `*.local.md`, `settings.local.json`, `.DS_Store`
#   - `docs/...` when the repo is `<ws>/repos/<x>` and `<ws>/docs/WORKFLOW.md`
#     exists (the workspace's own docs must never reach the repo)

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

in_workspace=0
parent=$(dirname "$top")
if [ "$(basename "$parent")" = repos ] && [ -f "$(dirname "$parent")/docs/WORKFLOW.md" ]; then
  in_workspace=1
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
  if [ "$in_workspace" = 1 ]; then
    case $path in docs/*) bad+=("$path"); continue ;; esac
  fi
done <<<"$staged"

[ ${#bad[@]} -eq 0 ] && exit 0

{
  echo "Commit refused: workspace files are staged in $top:"
  printf '  %s\n' "${bad[@]}"
  echo "Unstage them (git restore --staged <path>) and keep them out of the repo."
} >&2
exit 2
