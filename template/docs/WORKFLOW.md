# WORKFLOW — private process guide

Private. Never leaves this folder; never goes into a repo.

## 1. What is in this folder

```
<workspace>/                   ← AI workspace, its own private git repo; root of the Claude Project
├── CLAUDE.md                  main context for Claude Code sessions
├── .gitconfig                 git identity, included from ~/.gitconfig
├── .gitignore                 repos/, .claude/, .DS_Store — clones are separate repos
├── .claude/settings.local.json   local permissions (ignored; template is the source)
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
  status: pending | running | blocked | done | failed
  repo: <folder under repos/>
  branch: <branch name>
  worktree: <optional suffix → repos/<repo>-<suffix>>
  after: <optional branch; wait until it is merged into main>
  ---
  ```
  `blocked` = a human decision is needed; the question is at the top of the
  status file. Set it back to `pending` to re-queue. A prompt that depends
  on another prompt's branch declares `after:` and stays `pending`; it is
  not parked as `blocked` for that reason.
- `docs/status/` is the memory between sessions: at the end of a session
  write `docs/status/YYYY-MM-DD-<topic>.md` (done / not done / open
  questions / branch + last commit hash), or run `/relay:handover`.
  `docs/status/runs/` holds the runner's raw output per run; those files
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
