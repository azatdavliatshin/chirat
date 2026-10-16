# {{NAME}} — AI workspace

{{DESCRIPTION}}

This folder is the working area for **{{NAME}}**. It is **not** a git
repository; it is also the root of the Claude Project for this work, so
planning sessions share memory through it. All AI context — this file, plans,
status notes, analysis — lives here and under `docs/`, never inside a code
repository. Read `docs/WORKFLOW.md` before doing anything.

Git identity: `.gitconfig` in the workspace root via includeIf — never set
user.* inside a repo.

## Layout

| Path | Purpose |
|---|---|
| `CLAUDE.md` | This file — main context |
| `.claude/settings.local.json` | Local permissions for this workspace |
| `.gitconfig` | Git identity for every repo under this workspace (via `includeIf` in `~/.gitconfig`) |
| `docs/WORKFLOW.md` | Private process guide (never shared) |
| `docs/PARKED.md` | Deferred ideas / open questions |
| `docs/input/` | **Read-only.** Incoming material |
| `docs/scope/` | Dated scope snapshots (`BASELINE_YYYY-MM-DD.md`) |
| `docs/plans/` | One file per feature/task; `<topic>.prompt-N.md` are the prompts handed to Claude Code |
| `docs/analysis/` | Technical analysis, research |
| `docs/status/` | Status, handover notes — memory between sessions |
| `docs/estimates/` | Estimates |
| `docs/qa/` | QA sessions, check scripts |
| `docs/guides/` | How-tos |
| `docs/emails/` | Drafts of public texts (README copy, announcements, replies) |
| `docs/ci/` | CI configs in progress, before moving into a repo |
| `repos/<name>/` | Git repositories. All branches, commits and pushes go from here. |

## Hard rules

- Never create planning/state files (plans, TODOs, scratch, `.planning/`,
  state files) inside any repo under repos/. All such files go under this
  folder's docs/ or this root folder.
- Never mention AI, Claude, or code generation in commit messages, PR
  descriptions, or code comments.
- Never commit or push without an explicit request; run `git status` in the
  repo before any commit and flag unexpected files.
- Anything that must reach a remote — branches, commits, pushes — goes
  through repos/<name>, never from a copy elsewhere.
- Secrets: never ask for or store package-registry, GitHub or API tokens.
- Headless runs: never pass `--dangerously-skip-permissions`; use
  `--permission-mode acceptEdits` (or `auto`) plus `--permission-prompts none`,
  with `git push` and `npm publish` denied in settings.

## Useful commands

Host prerequisites: `git`, `jq` (commit guard), `shellcheck` (if the repos
carry shell scripts). Add verified build / test commands here as the repos
take shape.
