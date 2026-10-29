# Changelog

All notable changes are listed here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

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

[0.2.0]: https://github.com/azatdavliatshin/chirat/releases/tag/v0.2.0
