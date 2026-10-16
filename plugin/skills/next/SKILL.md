---
name: next
description: Run the next pending prompt file from docs/plans/ (or the one given), in the repo and branch its front matter names, then write a status file to docs/status/ and mark the prompt done, blocked or failed. Use when asked to take the next prompt, run a relay prompt, or process docs/plans.
argument-hint: "[path/to/topic.prompt-N.md]"
disable-model-invocation: true
allowed-tools: Bash(relay-prompt *) Bash(git status *) Bash(git log *) Bash(git branch *) Bash(git rev-parse *) Bash(git worktree list *)
---

# /relay:next

Run one prompt file end to end. Everything you need is in the prompt file and
the workspace layout below; do not rely on any other project instructions
being loaded.

## Workspace layout

The current directory is the **workspace root** (its own private git
repository, or no repository at all — never the code repository):

- `docs/plans/<topic>.prompt-N.md` — prompt files, YAML front matter + body
- `docs/status/` — status files you write
- `repos/<repo>/` — git repositories; all code work happens there

Front matter keys:

| Key | Values | Meaning |
|---|---|---|
| `model` | `sonnet` \| `opus` \| `fable` | chosen by whoever started this session; informational here |
| `status` | `pending` \| `running` \| `blocked` \| `done` \| `failed` | you move it `running` → `done`/`blocked`/`failed` |
| `repo` | folder name under `repos/` | required |
| `branch` | branch name | required |
| `worktree` | suffix, optional | work in `repos/<repo>-<worktree>` instead |

Statuses: `pending` waits in the queue; `running` is claimed; `done` means
the body was carried out; `blocked` means a human decision is needed before
work can continue (the question is at the top of the status file); `failed`
means the run could not do the work. Only `pending` files are ever picked
up — a `blocked` prompt is re-queued by a human setting it back to `pending`.

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
   - Commit protocol: commit at each checkpoint the prompt defines, on the
     prompt's branch; do not push; do not touch `main`. Before each commit
     run `git status` and make sure only intended files are staged. Never
     tag or publish. If the prompt defines no checkpoints, do not commit.
   - Never put planning or status files inside `repos/`; they belong under
     the workspace `docs/`.
   - Never mention AI, Claude or code generation in commit messages or code
     comments.
   - No one may be watching. If you need a human decision to continue,
     stop: the prompt ends `blocked` (step 5) and the question goes at the
     top of the status file.

4. **Write the status file** `docs/status/YYYY-MM-DD-<topic>.md` (today's
   date). If it already exists, append a new `## Run HH:MM` section instead
   of overwriting. When the run ends `blocked` or `failed`, the first line
   after the title is the question or the reason. Sections, in this order:
   - `Done` — what was completed
   - `Not done` — what was skipped or remains, including "stopped at
     checkpoint X, waiting for …"
   - `Open questions` — decisions needed from the human
   - `Branch` — branch name and `git log -1 --format=%h` (or "no commits")
   - `Files touched` — paths relative to the repo
   - `git status --short` — verbatim, in a fenced block

5. **Close it.** `relay-prompt set <file> status <final>` where `<final>`
   is `done` when the body was carried out (including a clean stop at a
   checkpoint the prompt defines), `blocked` when a human decision is
   needed to continue, otherwise `failed`. Write the status file in every
   case. Then, if the workspace root is a git repository (`git -C <ws>
   rev-parse --git-dir` succeeds), record the run there:
   `git -C <ws> add docs && git -C <ws> commit -m "docs: <topic> <final>"`.
   Stage only `docs/`; ignore a failure of this commit (for example nothing
   to commit); never push the workspace.

Finish with a three-line summary: prompt file, final status, status file path.
