---
name: handover
description: Write a handover file in the status directory (docs/status/ by default) for the current session — done, not done, open questions, branch and last commit, files touched, git status. Use at the end of an interactive session, or when asked to hand over or write a status note.
argument-hint: "[topic]"
allowed-tools: Bash(tail *) Bash(git status *) Bash(git log *) Bash(git branch *) Bash(git rev-parse *) Bash(git diff *)
---

# /relay:handover

Write a status file for this session so the next session (or the planning
side) can pick up without re-deriving context. There is no prompt file.

## Where

Workspace root = the directory that contains `docs/` and `repos/` (normally
the current directory; if you are inside `repos/<x>/`, it is two levels up).
Read `<ws>/.relay/config` if it exists (`key=value` lines, `#` comments);
`plans_dir`, `status_dir`, `default_branch` default to `docs/plans`,
`docs/status`, `main`. Write `<status_dir>/YYYY-MM-DD-<topic>.md` there, with
today's date.

`<topic>`: `$ARGUMENTS` if given; otherwise the current branch of the repo
you worked in, with `/` replaced by `-`; otherwise `session`. If that file
already exists, do not rewrite it: append `## Handover HH:MM` with the same
sections below, and leave the earlier content as it is.

## What

Base it on what actually happened in this conversation. Sections, in order:

- `Done` — what was completed this session
- `Not done` — what was started and left, or planned and skipped
- `Open questions` — decisions needed from the human
- `State` — the last line of `.relay/LATEST` quoted verbatim (omit if
  the file does not exist), so a new planning chat starts from it
- `Branch` — for each repo under `repos/` touched this session: branch name
  and `git log -1 --format=%h` (or "no commits")
- `Files touched` — paths, repo-relative, grouped by repo; workspace files
  under `docs/` (or `.relay/`) listed separately
- `git status --short` — verbatim per repo, in fenced blocks
- `Next for the human` — last, after the `git status` blocks: for each branch
  with commits not yet in `<default_branch>`, the review and merge commands
  (`git -C repos/<repo> diff <default_branch>..<branch>`, `git -C repos/<repo> merge
  --no-edit <branch>`), then the landing steps: if the workspace `CLAUDE.md`
  has a `## Landing` section (bullets `- <glob or path prefix> → <command>`),
  apply its rules to the "Files touched" list and print only the steps that
  match, as commands; then `Releases:` the prompts that `relay-prompt waiting .`
  lists with `after=<that branch>`, or `nothing waiting`. A `done` prompt is a
  branch waiting for your review and merge; nothing lands on `<default_branch>` by itself,
  and the next `after:` prompt waits for that merge.

Do not commit or push anything. Never write this file inside `repos/`.

Finish with one line: the path of the status file.
