---
name: next
description: Run the next pending prompt file from docs/plans/ (or the one given), in the repo and branch its front matter names, then write a status file to docs/status/ and mark the prompt done or failed. Use when asked to take the next prompt, run a relay prompt, or process docs/plans.
argument-hint: "[path/to/topic.prompt-N.md]"
disable-model-invocation: true
allowed-tools: Bash(relay-prompt *) Bash(git status *) Bash(git log *) Bash(git branch *) Bash(git rev-parse *) Bash(git worktree list *)
---

# /relay:next

Run one prompt file end to end. Everything you need is in the prompt file and
the workspace layout below; do not rely on any other project instructions
being loaded.

## Workspace layout

The current directory is the **workspace root** (not a git repository):

- `docs/plans/<topic>.prompt-N.md` — prompt files, YAML front matter + body
- `docs/status/` — status files you write
- `repos/<repo>/` — git repositories; all code work happens there

Front matter keys:

| Key | Values | Meaning |
|---|---|---|
| `model` | `sonnet` \| `opus` \| `fable` | chosen by whoever started this session; informational here |
| `status` | `pending` \| `running` \| `done` \| `failed` | you move it `running` → `done`/`failed` |
| `repo` | folder name under `repos/` | required |
| `branch` | branch name | required |
| `worktree` | suffix, optional | work in `repos/<repo>-<worktree>` instead |

Read and write front matter only with `relay-prompt` (on `PATH` while this
plugin is enabled): `relay-prompt get <file> <key>`,
`relay-prompt set <file> <key> <value>`, `relay-prompt next .`.

## Steps

0. **Pick the file.** Argument given: `$ARGUMENTS` is the prompt file. No
   argument: run `relay-prompt next .`; if it exits non-zero, say "no pending
   prompt" and stop without writing anything. Let `<topic>` be the file name
   without `.md` (e.g. `relay.prompt-3`). Read `repo`, `branch`, `worktree`.
   If `repo` or `branch` is empty or `repos/<repo>` is not a git repository,
   go to step 5 with `failed`.

1. **Claim it.** `relay-prompt set <file> status running`. From here on, every
   exit path ends in step 5 — never leave `running` behind, even on error.

2. **Get to the right tree.** Let `R = repos/<repo>`.
   - `worktree` set: let `W = repos/<repo>-<worktree>`. If `W` does not
     exist, from `R` run `git worktree add ../<repo>-<worktree> -b <branch>`
     (if the branch already exists, `git worktree add ../<repo>-<worktree>
     <branch>`). Work in `W`.
   - `worktree` unset: work in `R`. If `git status --porcelain` is not empty
     and the current branch is not `<branch>`, do not switch — fail with
     "uncommitted changes on <current branch>". Otherwise
     `git checkout <branch>`, or `git checkout -b <branch> main` if it does
     not exist.
   Confirm with `git rev-parse --abbrev-ref HEAD`.

3. **Do the work.** Execute the prompt body exactly, in that tree. Honour its
   own checkpoints and stop where it says to stop. Rules that always apply:
   - Never commit, push, tag or publish unless the prompt body explicitly
     tells you to.
   - Never put planning or status files inside `repos/`; they belong under
     the workspace `docs/`.
   - Never mention AI, Claude or code generation in commit messages or code
     comments.
   - No one may be watching. If you need a human decision to continue,
     stop, and record the question in the status file.

4. **Write the status file** `docs/status/YYYY-MM-DD-<topic>.md` (today's
   date). If it already exists, append a new `## Run HH:MM` section instead
   of overwriting. Sections, in this order:
   - `Done` — what was completed
   - `Not done` — what was skipped or remains, including "stopped at
     checkpoint X, waiting for …"
   - `Open questions` — decisions needed from the human
   - `Branch` — branch name and `git log -1 --format=%h` (or "no commits")
   - `Files touched` — paths relative to the repo
   - `git status --short` — verbatim, in a fenced block

5. **Close it.** `relay-prompt set <file> status done` when the body was
   carried out (including a clean stop at a checkpoint the prompt defines),
   otherwise `relay-prompt set <file> status failed` and put the reason at
   the top of the status file. Write the status file even on failure.

Finish with a three-line summary: prompt file, final status, status file path.
