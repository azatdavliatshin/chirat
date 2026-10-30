# Changelog

All notable changes are listed here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## [0.2.1] — 2026-10-29

### Fixed

- Commit guard: commands are read with a real shell-word lexer, so a quoted
  path with spaces (or `&`, `;`) is one word and `git -C "code with spaces"
  commit` is checked like a commit from inside the repo; `--git-dir` /
  `--work-tree` (also `GIT_DIR` / `GIT_WORK_TREE`), `cd` / `pushd` /
  `env -C`, `bash -c` and `eval` bodies, `$(…)`, backticks and here-documents
  are followed, including substitutions nested in quotes
  (`"${x:-"$(git push)"}"`), `-c` bodies with the caller's repository context
  (`GIT_DIR=… bash -c 'git commit'`, `env -C … sh -c`), and `cd` under
  pipelines or control flow (the directory is a set of candidates; a commit is
  checked against every one), background jobs, loops and functions: a `cd`
  behind `&` or in `coproc` changes nothing outside, a `cd` in a loop body,
  in a function, in `source`, in a `trap` or in an unresolved `eval` makes
  the directory unknown. The rule is a whitelist — only a top-level `cd`, the
  same `&&` chain and `if`/`case` branches move the set to a known place.
  The guard now fails closed: a commit whose repository it cannot tell (a
  variable or glob in the path, `cd` to an unresolved dir, a literal path
  that is not a repository, unbalanced quotes) is refused with the reason
  instead of let through. A differential test (`plugin/tests/guard-corpus.sh`)
  runs every corpus line through the guard and through a real bash with
  `git` shimmed, and fails if anything the real run would commit in a dirty
  repository got past the guard.
- `chirat-watch --dry-run` writes nothing, as the README promised: it no
  longer recovers a stale lock for real (it prints `would set … pending` /
  `would remove lock …` and what would run next), it creates no `runs/`,
  lock, `LATEST`, `watch.log` or `*.seen` line, state dir or
  `watcher.pid` / `watcher.flags`, and it previews the same prompt a real
  pass would run: the prompts a recovery would re-queue compete with the
  pending ones in queue order (`chirat-prompt next --as-pending <file>…`,
  no writes) instead of being shown only when nothing else is pending.
- Stopping the watcher (signal, `restart --force`) waits for `claude`'s whole
  process group, not just `claude`: a child that outlives `claude` is sent
  KILL after the grace period, and only when nothing of the group is left is
  the prompt set back to `pending` and the lock released; otherwise, or when
  the group cannot be inspected, both are kept (`interrupted-alive`). A lock
  whose `claude` is dead but whose children run is live, not stale.
- `after:` no longer treats a deleted branch as merged: a run now records the
  branch head as `commit:` in its prompt (`/chirat:next` and the watcher),
  and once the branch is gone that commit must be in the default branch;
  the "a done prompt names the branch" and "a commit message mentions it"
  heuristics are removed. `after_mode: done` opts out for squash merges and
  older prompts, with a warning on every check and on the run.
  `chirat-prompt unset` removes a key.
- The `reviewer` agent and `/chirat:poll` read `plans_dir`, `status_dir` and
  `default_branch` from `.chirat/config` instead of assuming `docs/plans`,
  `docs/status` and `main`.

## [0.2.0] — 2026-10-29

First public release. chirat was called *relay* before; the 0.1.x versions
were internal.

### Added

- Prompt files `<topic>.prompt-N.md` with front matter (`model`, `status`,
  `repo`, `branch`, `worktree`, `after`) and a queue that runs the next
  `pending` one; `after:` waits until a branch is merged; suffixed numbers
  (`5-fix`, `5b`) insert a prompt between two others; `chirat-prompt lint`
  and the watcher log misnamed files.
- `chirat-prompt` for reading and writing front matter, listing waiting
  prompts and checking `after:`; every `status` change is logged.
- `chirat-watch`, a self-hosted watcher that runs `claude -p` with the
  prompt's model on your own `claude` login, with `--once`, `--dry-run`,
  `--tmux`, locks, stale-lock recovery and clean interruption.
- Operations commands: `status`, `recover`, `logs`, `tail`, `doctor [--online]`,
  `restart` and `install`.
- Desktop notifications on macOS when a run ends (terminal-notifier 3.x or
  `osascript`), with a click action and the `notify_open` config key.
- `.chirat/` workspace state: `config` (`plans_dir`, `status_dir`,
  `default_branch`, `notify_open`), per-run logs, `LATEST` and `status.log`.
- Status files that end with `## Next for the human`: review, merge, landing
  steps from the workspace `CLAUDE.md`, and the prompts the merge releases.
- `chirat-init` and a workspace template (`CLAUDE.md`, `docs/WORKFLOW.md`,
  local settings that deny push and publish).
- Claude Code plugin: `/chirat:next`, `/chirat:handover`, `/chirat:poll`, a
  read-only `reviewer` agent pinned to `opus`, and a Bash hook that refuses
  push, publish (`npm`, `pnpm`, `yarn`) and commits containing workspace
  files.
- CI on macOS and Ubuntu, including macOS's Bash 3.2.
- README sections on Safety and Troubleshooting; `LICENSE` (MIT).

### Changed

- Renamed from *relay* to *chirat*: commands, `.chirat/` directory, plugin,
  `CHIRAT_*` variables and repository. Nothing is migrated automatically;
  `chirat-watch status` and `doctor` print each step, and the README has the
  upgrade path from relay.
- The default permission mode is `auto` instead of `acceptEdits`.

[0.2.1]: https://github.com/azatdavliatshin/chirat/releases/tag/v0.2.1
[0.2.0]: https://github.com/azatdavliatshin/chirat/releases/tag/v0.2.0
