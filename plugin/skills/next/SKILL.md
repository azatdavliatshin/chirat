---
name: next
description: Run the next pending prompt file from the plans directory (docs/plans/ by default), or the one given, in the repo and branch its front matter names, then write a status file to the status directory (docs/status/ by default) and mark the prompt done, blocked or failed. Use when asked to take the next prompt, run a chirat prompt, or process the plans directory.
argument-hint: "[path/to/topic.prompt-N.md]"
disable-model-invocation: true
allowed-tools: Bash(chirat-prompt *) Bash(git -C *)
---

# /chirat:next

Run one prompt file end to end. Everything you need is in the prompt file and
the workspace layout below; do not rely on any other project instructions
being loaded.

## Workspace layout

The current directory is the **workspace root** (its own private git
repository, or no repository at all — never the code repository):

- `<plans_dir>/<topic>.prompt-N.md` — prompt files, YAML front matter + body
- `<status_dir>/` — status files you write
- `repos/<repo>/` — git repositories; all code work happens there
- `.chirat/` — chirat's own state (run log, lock); never write there yourself

Read `<ws>/.chirat/config` if it exists (`key=value` lines, `#` comments);
`plans_dir`, `status_dir`, `default_branch` default to `docs/plans`,
`docs/status`, `main`. Use those names wherever this text says
`<plans_dir>`, `<status_dir>`, `<default_branch>`.

Front matter keys:

| Key | Values | Meaning |
|---|---|---|
| `model` | `sonnet` \| `opus` \| `fable` | chosen by whoever started this session; informational here |
| `status` | `pending` \| `running` \| `blocked` \| `done` \| `failed` | you move it `running` → `done`/`blocked`/`failed` |
| `repo` | folder name under `repos/` | required |
| `branch` | branch name | required |
| `worktree` | suffix, optional | work in `repos/<repo>-<worktree>` instead |
| `after` | branch name, optional | eligible only once that branch is merged into `<default_branch>` of `repos/<repo>`; once the branch is deleted, the `commit:` recorded by the prompt that built it must be in `<default_branch>` — a deleted branch alone proves nothing |
| `after_mode` | `merged` (default) \| `done`, optional | `done` opts out for squash merges and old prompts: satisfied as soon as the prompt that built `after`'s branch is `done`; `chirat-prompt check` then warns that this proves no merge — quote that warning in the status file |
| `commit` | full sha, optional | the head of `branch` when the run ended; you record it in step 5, `after:` of later prompts reads it |

Statuses: `pending` waits in the queue; `running` is claimed; `done` means
the body was carried out; `blocked` means a human decision is needed before
work can continue (the question is at the top of the status file); `failed`
means the run could not do the work. Only `pending` files are ever picked
up — a `blocked` prompt is re-queued by a human setting it back to `pending`.

Read and write front matter only with `chirat-prompt` (on `PATH` while this
plugin is enabled): `chirat-prompt get <file> <key>`,
`chirat-prompt set <file> <key> <value>`, `chirat-prompt next .`.

## Steps

0. **Pick the file.** Argument given: `$ARGUMENTS` is the prompt file. No
   argument: run `chirat-prompt next .`; if it exits non-zero, say "no pending
   prompt" and stop without writing anything. Let `<topic>` be the file name
   without `.md` (e.g. `chirat.prompt-3`). Read `repo`, `branch`, `worktree`.
   If the prompt has `after:`, run `chirat-prompt check . <file>`; when it
   exits non-zero the dependency is unmet even for an explicit path: write the
   status file (reason first line) and go to step 5 with `blocked`, without
   claiming it or touching any tree. When it exits 0 but prints a warning
   (`after_mode: done`), keep that warning for the status file's
   `Open questions`.
   If `repo` or `branch` is empty or `repos/<repo>` is not a git repository,
   go to step 5 with `failed`.

1. **Claim it.** `chirat-prompt set <file> status running`. From here on, every
   exit path ends in step 5 — never leave `running` behind, even on error.

2. **Get to the right tree.** Let `R = repos/<repo>`.
   - `worktree` set: let `W = repos/<repo>-<worktree>`. If `W` does not
     exist, create it from `<default_branch>`: if `git -C R rev-parse --verify
     <default_branch>` fails, fail with "branch <default_branch> not found
     in <R>"; otherwise run
     `git -C R worktree add ../<repo>-<worktree> -b <branch> <default_branch>`
     (if the branch already exists, `git -C R worktree add
     ../<repo>-<worktree> <branch>`). Work in `W`.
   - `worktree` unset: work in `R`. If `git -C R status --porcelain` is not
     empty and the current branch is not `<branch>`, do not switch — fail
     with "uncommitted changes on <current branch>". Otherwise
     `git -C R checkout <branch>`, or `git -C R checkout -b <branch> <default_branch>`
     if it does not exist.
   Confirm with `git -C <tree> rev-parse --abbrev-ref HEAD`.

3. **Do the work.** Execute the prompt body exactly, in that tree. Honour its
   own checkpoints and stop where it says to stop. Rules that always apply:
   - Never `cd`. Stay in the workspace root for the whole run; run tools with
     paths from the root or with `-C`/`--prefix` flags (`git -C <tree> …`,
     `bash repos/<repo>/tests/x.sh`). Under headless runs a `cd <dir> && …`
     command matches no allow rule and is denied. Execute the prompt body the
     same way; if something truly needs a working directory, say so in the
     status file instead of guessing.
   - Commit protocol: commit at each checkpoint the prompt defines, on the
     prompt's branch; do not push; do not touch `<default_branch>`. Before each commit
     run `git -C <tree> status` and make sure only intended files are staged. Never
     tag or publish. If the prompt defines no checkpoints, do not commit.
   - Never put planning, status or `.chirat/` files inside `repos/`; they
     belong under the workspace (`<plans_dir>`, `<status_dir>`, `.chirat/`).
   - Never mention AI, Claude or code generation in commit messages or code
     comments.
   - No one may be watching. If you need a human decision to continue,
     stop: the prompt ends `blocked` (step 5) and the question goes at the
     top of the status file.

4. **Write the status file** `<status_dir>/YYYY-MM-DD-<topic>.md` (today's
   date). If that file already exists, do not rewrite it: append
   `## Run HH:MM` with the same sections below, and leave the earlier runs
   as they are. When the run ends `blocked` or `failed`, the first line
   after the title is the question or the reason. Sections, in this order:
   - `Done` — what was completed
   - `Not done` — what was skipped or remains, including "stopped at
     checkpoint X, waiting for …"
   - `Open questions` — decisions needed from the human
   - `Branch` — branch name and `git -C <tree> log -1 --format=%h` (or "no commits")
   - `Files touched` — paths relative to the repo
   - `git -C <tree> status --short` — verbatim, in a fenced block
   - `Next for the human` — last, after the `git status` block, for every
     final status (see below)

   ### Next for the human

   A `done` prompt is a branch waiting for your review and merge; nothing
   lands on `<default_branch>` by itself, and the next `after:` prompt waits for that
   merge.

   - `done`: (1) review this file and `git -C repos/<repo> diff
     <default_branch>..<branch>`; (2) `git -C repos/<repo> merge --no-edit <branch>`;
     (3) the landing steps: if the workspace `CLAUDE.md` has a `## Landing`
     section, apply its rules to the "Files touched" list and print only the
     steps that match, as commands; (4) `Releases:` the prompts that
     `chirat-prompt waiting .` lists with `after=<this branch>`, or
     `nothing waiting`.
   - `blocked`: "answer the question at the top of this file, then set the
     prompt back to `pending`: `chirat-prompt set <file> status pending`".
   - `failed`: "read `.chirat/runs/<stem>.<stamp>.err`, fix or re-plan,
     then set `pending`".

   `## Landing` convention: a bullet list, each
   `- <glob or path prefix> → <command>`; a step is included when any touched
   path matches. Example:

   ```
   ## Landing
   - plugin/ → claude plugin update chirat@chirat
   - bin/chirat-watch → chirat-watch restart
   ```

5. **Record the result, then close it.** First the result: if the branch
   exists — `git -C repos/<repo> rev-parse --verify -q refs/heads/<branch>`
   prints a sha — run `chirat-prompt set <file> commit <that full sha>`
   (always for `done`; for `blocked`/`failed` too, the branch has commits);
   if it does not exist, `chirat-prompt unset <file> commit`, so a retry
   never keeps a stale value. Only then `chirat-prompt set <file> status
   <final>`, where `<final>` is `done` when the body was carried out
   (including a clean stop at a checkpoint the prompt defines), `blocked`
   when a human decision is needed to continue, otherwise `failed`. Write
   the status file in every case. Then, when the run used `repos/<repo>` directly (no `worktree`),
   return it to `<default_branch>` so a human `git merge` lands there: if
   `git -C repos/<repo> status --porcelain` is empty run
   `git -C repos/<repo> checkout <default_branch>`, otherwise leave the tree as it is and
   say so in the status file. A worktree run leaves its worktree as is.
   Then, if the workspace root is a git repository (`git -C <ws>
   rev-parse --git-dir` succeeds), record the run there:
   `git -C <ws> add <file> <status_dir>/YYYY-MM-DD-<topic>.md` — only this
   prompt file (its status flip) and its status file, never the whole
   `<plans_dir>` (a draft of another prompt may be sitting there) — and then
   `git -C <ws> commit -m "docs: <topic> <final>"`.
   Never stage `.chirat/` (chirat-watch commits the run log once this process
   has exited); ignore a failure of this commit (for example nothing
   to commit); never push the workspace.

Finish with a three-line summary: prompt file, final status, status file path.
