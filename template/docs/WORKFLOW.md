# WORKFLOW — private process guide

Private. Never leaves this folder; never goes into a repo.

## 1. What is in this folder

```
<workspace>/                   ← AI workspace, its own private git repo; root of the Claude Project
├── CLAUDE.md                  main context for Claude Code sessions
├── .gitconfig                 git identity, included from ~/.gitconfig
├── .gitignore                 repos/, .claude/, .DS_Store, .relay/lock/ — clones are separate repos
├── .claude/settings.local.json   local permissions (ignored; template is the source)
├── .relay/                    relay's own state — run log, LATEST, lock; see README
├── docs/
│   ├── WORKFLOW.md            this file
│   ├── PARKED.md              deferred ideas / questions
│   ├── input/                 read-only incoming material
│   ├── scope/                 BASELINE_YYYY-MM-DD.md snapshots
│   ├── plans/                 one plan per feature; <topic>.prompt-N.md = prompts for Claude Code
│   ├── analysis/              research
│   ├── status/                session handovers — memory between sessions
│   ├── estimates/ qa/ guides/ ci/
│   └── emails/                drafts of anything public
└── repos/<name>/              git repositories (ignored here); code commits happen there
```

## 2. Principle: parent folder = AI workspace, repos stay clean

Everything Claude needs to think lives here. A repository contains only what
a reader of that repository should see. Every prompt handed to Claude Code
goes to `docs/plans/<topic>.prompt-N.md`; every result comes back as
`docs/status/YYYY-MM-DD-<topic>.md`. Keep that trail honest, including
failed runs.

## 3. Zero-trace checklist

- `~/.claude/settings.json`: no co-author / attribution trailer.
- `.git/info/exclude` in each clone: `CLAUDE.local.md`, `.claude/`,
  `.planning/`, `*.local.md`.
- **Two tiers.** In `repos/*` Claude commits only at the checkpoints a
  prompt defines, on the prompt's branch, and never pushes or touches
  `main`; the human reviews, merges and pushes. In the workspace, `docs:`
  commits are routine (`/relay:next` makes one per run); pushes are the
  human's.
- Before every commit `git status` must not show `.claude/`,
  `settings.local.json`, `*.local.md`, `.DS_Store`, or anything from this
  workspace's `docs/`.
- Commit messages: conventional (`feat: …`, `fix(scope): …`, `docs: …`).
  No AI mentions.

## 4. Daily workflow

- One task → one branch → one session. Plan first in `docs/plans/<topic>.md`
  (goal, file list, test plan, done criteria), then prompts
  `<topic>.prompt-N.md` executed in fresh Claude Code sessions. To insert a
  prompt between N and N+1, name it `<topic>.prompt-Nb.md` (or `N-fix`); it
  runs after N.
- Prompt front matter (read by `/relay:next` and the runner):
  ```
  ---
  model: sonnet | opus | fable
  status: draft | pending | running | blocked | done | failed
  repo: <folder under repos/>
  branch: <branch name>
  worktree: <optional suffix → repos/<repo>-<suffix>>
  after: <optional branch; wait until it is merged into main>
  ---
  ```
  A `done` prompt is a branch waiting for your review and merge; nothing lands on `main` by itself, and the next `after:` prompt waits for that merge.
  `blocked` = a human decision is needed; the question is at the top of the
  status file. Set it back to `pending` to re-queue. A prompt that depends
  on another prompt's branch declares `after:` and stays `pending`; it is
  not parked as `blocked` for that reason.
- **Prompt review before it can run** (`prompt_review: on` in CLAUDE.md,
  the default): the planning chat writes a new prompt with `status: draft`
  (inert — the runner takes only `pending`), posts a three-line summary,
  and flips it to `pending` only when I say "go" after reading or editing
  the file. `prompt_review: off` writes `pending` directly.
- When the planning chat writes a draft prompt, it opens the file as a
  document in the chat's side panel (not pasted into the message), so the
  review happens without leaving the chat; the file is the source of truth.
- Right after flipping a prompt to `pending` (the "go"), the planning chat
  posts a short **What's next** block, in the language of the conversation:
  (1) what happens now — the watcher picks it up within its interval, where
  the prompt runs and roughly how long (sonnet ≈ 10 min, opus ≈ 20–25);
  (2) what can be run meanwhile — `relay-watch status`, `relay-watch tail -f`,
  `relay-watch logs`; (3) what happens at the end — the notification, say
  "check" here, then review → merge → the `## Landing` steps → the next
  `after:` prompt starts by itself. Same block every time, so there is
  nothing to ask.
- **Model choice** (the `model:` line) is made in the planning discussion, not
  by a fixed default: the Cowork session that writes the prompt picks model and
  effort for the executor and gives a one-line reason as the first line of the
  prompt body (`Model: fable, effort high — found the bug, has the repros`).
  Defaults when there is no reason to deviate: opus or fable, high effort, for
  code; sonnet / medium for docs-only work.
  - Model diversity pays off at review: prefer a reviewer on a different
    model from the author's. Planner and executor may share a model; when
    triaging a review, the planner should be wary of dismissing findings
    against code written by its own model.
  - Whoever writes a fix never verifies it: the verification pass runs in a
    session (or model) that did not write the fix. A review session may be
    switched to the author role by an explicit prompt — then someone else
    verifies.
- `docs/status/` is the memory between sessions: at the end of a session
  write `docs/status/YYYY-MM-DD-<topic>.md` (done / not done / open
  questions / branch + last commit hash), or run `/relay:handover`.
  `.relay/runs/` holds the runner's raw output per run; those files
  are versioned here as the run log.
- After merging a branch that touches `plugin/` in the relay repo, run
  `claude plugin update relay@relay` (or uninstall and reinstall): the
  installed plugin is a cache snapshot, not a live link to the clone.
- Anything public is drafted in `docs/emails/` and re-read by the human
  before posting.

## 5. Session hygiene

- Start a session by reading `CLAUDE.md`, the active plan, and the latest
  `docs/status/` file. Don't re-derive context from the repo.
- One concern per session; side issues → one line in `docs/PARKED.md`.
- Before ending: `git status` in each clone, update the status file, make
  sure nothing from the workspace leaked into a repo.

## 6. Hearing back from the runner

The planning chat does not poll on a fixed timer: every poll is a turn with
its full context, and a 3-minute timer over a night is ~160 turns, almost
all empty. Signal first.

- **Log.** For each finished run `relay-watch` appends one line to
  `.relay/LATEST` (tab-separated: time, prompt stem, status, branch,
  commit, exit code, seconds). On "check", or right after enqueueing a prompt,
  the planning chat reads the last line (or the lines newer than the last one
  it reported). `running` shows in the prompt's front matter, not in LATEST.
- **Three modes.**
  1. Human at the machine: `relay-watch` posts a macOS notification when a
     run ends; the human reads the status file and pings the planning chat.
     With `notify_open` set in `.relay/config`, a click on the notification
     brings the human to the Project (or the session).
  2. Human away, Mac awake: adaptive poll. First check at the expected run
     length (sonnet ≈ 10 min, opus ≈ 20–25 min, from `.relay/runs/`),
     then every 10 min. Queue empty: one 60-min tick, then stop.
  3. Night: no poll; the human writes first in the morning and the planning
     chat catches up in one turn.
- **Tick.** One shell command prints a fingerprint; it travels in the
  reminder text, so an unchanged tick reads nothing and says nothing. Changed:
  read the last LATEST line and the newest status file, report in one short
  message, re-plan.
  ```
  W=/path/to/workspace; { grep -H '^status:' "$W"/docs/plans/*.prompt-*.md; ls "$W"/docs/status/*.md; tail -n 1 "$W"/.relay/LATEST; find "$W"/.relay/runs -name '*.json' -size +0 | wc -l; } 2>/dev/null | cksum
  ```
- **Unreachable.** If a tick cannot reach the Mac (asleep, app closed): one
  retry after 10 min, then stop.
- **Opt-out.** `cowork_poll: off` in this file's header or `CLAUDE.md` means
  never tick, even when away.

**Review in the side panel.** The planning chat shows things to read as
documents in the chat's side panel, never pasted into a message:
- a draft prompt, when written;
- on "check", two files for the finished run: the status file, and the
  diff — `git -C repos/<repo> diff <default_branch>..<branch>` for the
  prompt's branch, written to `.relay/review/<stem>.diff` (gitignored),
  rendered with `docs/qa/diff2html.py <in.diff> <out.html> [title]` and
  opened as HTML (file list with +/− counts, collapsible files, line
  numbers). Status first, diff second; a `blocked`/`failed` run gets the
  diff only if the branch has commits;
- "diff" (or "diff <stem>") shows the diff again on its own — the newest
  `done` prompt with an unmerged branch when no stem is given.
The aim is to stay in Cowork as long as possible and leave it only for what
it cannot reach (git merge, push).

The `/relay:poll` skill carries the same rule for the planning session.
