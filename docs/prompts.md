# Prompt files

What a prompt file is: naming and order, front matter, statuses, `after:`,
checkpoints, worktrees and the recorded result commit. Back to the
[README](../README.md); related: [commands](commands.md) (`chirat-prompt`,
how the watcher picks one), [workflow](workflow.md),
[configuration](configuration.md).

## Naming and order

A prompt file is `<plans_dir>/<topic>.prompt-<N><suffix>.md`: `N` is digits,
`suffix` is empty, lowercase letters (`5b`) or a dash and `[a-z0-9-]`
(`5-fix`); nothing else is picked up. Order: `N` numerically, plain `N`
first, suffixes in byte order, then oldest file — `5`, `5-fix`, `5b`, `6` —
which is how a prompt is inserted between two existing ones.

## Front matter

A prompt is YAML front matter followed by the body, which is what Claude Code
is asked to carry out.

| Key | Values | Meaning |
|---|---|---|
| `model` | `sonnet` \| `opus` \| `fable` | model the watcher passes to `claude` (`sonnet` if absent) |
| `status` | `pending` \| `running` \| `blocked` \| `done` \| `failed` | queue state; only `pending` is picked up |
| `repo` | folder under `repos/` | required |
| `branch` | branch name | required |
| `worktree` | suffix | optional; work in `repos/<repo>-<suffix>` |
| `after` | branch name | optional; wait until that branch is merged into `default_branch` of `repos/<repo>` (see below). A dependent prompt is enqueued `pending` with `after:`, never parked as `blocked`; `/chirat:next <file>` with an unmet `after:` ends `blocked`, so an explicit path cannot bypass it |
| `after_mode` | `merged` (default) \| `done` | optional; `done` means "satisfied as soon as the prompt that built `after`'s branch is `done`" — for squash merges and prompts from before `commit:` existed; `chirat-prompt check` / `waiting` and the watcher warn that this proves no merge. Any other value: unmet |
| `commit` | full sha | written when a run ends `done`, `blocked` or `failed`: the head of `branch` in `repos/<repo>` (`/chirat:next` records it before the final status; the watcher fills or corrects it, and removes it when the branch is gone). `after:` reads it once the branch is deleted |

## Statuses

Statuses go `pending` → `running` → `done` | `blocked` | `failed`. A `done`
prompt is a branch waiting for your review and merge; nothing lands on `main`
by itself, and the next `after:` prompt waits for that merge. `blocked`: a
human decision is needed (the question tops the status file); set `pending` to
re-queue. `failed`: the run could not do the work; read the run's `.err`
(see [troubleshooting](troubleshooting.md)), fix or re-plan, then set
`pending`. `draft` is inert, for prompts under review: the planning side
writes a new prompt as `draft` and sets `pending` after your "go"
(`prompt_review: on` in the workspace `CLAUDE.md`; see the template's
`docs/WORKFLOW.md`, §4).

Change a status with `chirat-prompt set <file> status pending`, not by hand,
so the change is logged in `.chirat/status.log`.

## Checkpoints, branches and worktrees

The body can define checkpoints — points at which Claude Code commits on the
prompt's `branch` and, if the prompt says so, stops. A run commits only at
the checkpoints the prompt defines; it never pushes, never tags and does not
touch the default branch. With no `worktree`, the run works in `repos/<repo>`
itself: it creates `branch` from `default_branch` (or checks it out), and
after the run returns the repository to `default_branch` if the tree is clean.
If the tree was dirty, or the run failed before it could switch back, the
repository stays on the prompt's branch and the status file says so.
With `worktree: <suffix>`, the run works in `repos/<repo>-<suffix>`, created
from `default_branch` on first use, and leaves it as is.

## `after:` and merges

While the branch exists, `git merge-base --is-ancestor` decides. Once it is
deleted, only the recorded result can: the prompt that built it (same `repo:`
and `branch:`; the last in queue order if several) carries `commit:`, and
that commit must be in `default_branch`. Without it the dependency stays
unmet — `chirat-prompt waiting` says `branch X is gone and no result commit
is recorded; merge it or set \`after_mode: done\``. A branch that no prompt
built is a planning error (warning).

**`merged` vs. `done`, and squash merges.** Squash merges rewrite the commit,
so the ancestry check cannot see them: set `after_mode: done` on the
dependent prompt; it is then released by the `done` status alone (checked
before the branch is looked at, so it also covers a squash-merged branch that
still exists), with a warning on every check and on the run that it does not
prove a merge.
