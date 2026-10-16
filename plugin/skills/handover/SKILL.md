---
name: handover
description: Write a docs/status/ handover file for the current session — done, not done, open questions, branch and last commit, files touched, git status. Use at the end of an interactive session, or when asked to hand over or write a status note.
argument-hint: "[topic]"
allowed-tools: Bash(git status *) Bash(git log *) Bash(git branch *) Bash(git rev-parse *) Bash(git diff *)
---

# /relay:handover

Write a status file for this session so the next session (or the planning
side) can pick up without re-deriving context. There is no prompt file.

## Where

Workspace root = the directory that contains `docs/` and `repos/` (normally
the current directory; if you are inside `repos/<x>/`, it is two levels up).
Write `docs/status/YYYY-MM-DD-<topic>.md` there, with today's date.

`<topic>`: `$ARGUMENTS` if given; otherwise the current branch of the repo
you worked in, with `/` replaced by `-`; otherwise `session`. If that file
already exists, do not rewrite it: append `## Handover HH:MM` with the same
sections below, and leave the earlier content as it is.

## What

Base it on what actually happened in this conversation. Sections, in order:

- `Done` — what was completed this session
- `Not done` — what was started and left, or planned and skipped
- `Open questions` — decisions needed from the human
- `Branch` — for each repo under `repos/` touched this session: branch name
  and `git log -1 --format=%h` (or "no commits")
- `Files touched` — paths, repo-relative, grouped by repo; workspace files
  under `docs/` listed separately
- `git status --short` — verbatim per repo, in fenced blocks

Do not commit or push anything. Never write this file inside `repos/`.

Finish with one line: the path of the status file.
