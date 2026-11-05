# Upgrading

Routine updates, the plugin cache, the move from the earlier name *relay*,
and stopping and restarting the watcher safely. Back to the
[README](../README.md); related: [commands](commands.md),
[troubleshooting](troubleshooting.md).

## Routine update

Pull the clone (`git -C ~/code/chirat-src pull`). The installed commands are
symlinks into the clone, so they update with it; restart a running watcher
with `chirat-watch restart` (see below). **The plugin** is a cache snapshot,
not a link to the clone: after pulling a version that touches `plugin/`, run
`claude plugin update chirat@chirat`.

## Stopping and restarting the watcher

`chirat-watch restart` stops the watcher and starts `--tmux` again with the
same flags. It is refused while `claude` runs; `--force` sends the stop
signals anyway and the prompt goes back to `pending`. Prefer waiting for the
run to end. Stopping by `tmux kill-session` or Ctrl-C triggers the same
interruption handling: TERM to `claude`'s whole process group, a wait of up to
`CHIRAT_STOP_GRACE` seconds (default 15), KILL, and another wait; only when
nothing of the group is left does the prompt go back to `pending`, the lock
get released and `interrupted` get logged. If anything survives, or the group
cannot be inspected, prompt and lock stay as they are and the log says
`interrupted-alive`; the next start waits for that group. Run
`chirat-watch status` to see the state.

## From relay

The earlier name; nothing is migrated automatically — `chirat-watch status`
and `doctor` print each command until it is done, and the watcher skips a
workspace that still has `.relay/`.

1. Stop the old watcher: `relay-watch status` must show no live run, then
   `tmux kill-session -t relay`.
2. Merge or pull this version into your clone.
3. Remove the old symlinks (`rm ~/.local/bin/relay-watch
   ~/.local/bin/relay-prompt`) and run `bin/chirat-watch install`.
4. Move the config: `mv ~/.config/relay ~/.config/chirat`; optionally the
   state too: `mv ~/.local/state/relay ~/.local/state/chirat` (with
   `$XDG_CONFIG_HOME` / `$XDG_STATE_HOME` instead of `~/.config` /
   `~/.local/state` if you set them). Rename any `RELAY_*` variable to
   `CHIRAT_*`; the old names are ignored.
5. Per workspace: `git mv .relay .chirat && sed -i.bak
   's#^\.relay/#.chirat/#' .gitignore && rm .gitignore.bak`, and in
   `.claude/settings.local.json` change `Bash(relay-prompt *)` to
   `Bash(chirat-prompt *)`. If `.relay/lock/` exists, a run from the old
   watcher may still be live: check it first, do not move.
6. Plugin, in Claude Code: `/plugin uninstall relay@relay`,
   `/plugin marketplace remove relay`, add the marketplace again (see
   [getting started](getting-started.md#4-install-the-plugin-claude-code)),
   `/plugin install chirat@chirat`.
7. The GitHub repository was renamed too; old URLs redirect, but update
   existing clones: `git remote set-url origin
   https://github.com/azatdavliatshin/chirat` (or the ssh form), and if the
   marketplace was added by GitHub name rather than a local path:
   `claude plugin marketplace remove chirat && claude plugin marketplace
   add azatdavliatshin/chirat`.
8. `chirat-watch doctor --online`, then start the watcher:
   `chirat-watch --tmux`.

## From 0.x

The run log moved from `docs/status/` to `.chirat/`. Per workspace,
`git mv docs/status/runs .chirat/runs && git mv docs/status/LATEST .chirat/LATEST`
(what exists; `status` and `doctor` warn until then), then
`chirat-watch restart`.
