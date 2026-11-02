# Troubleshooting

Symptom, first check, recovery. Back to the [README](../README.md); related:
[commands](commands.md), [configuration](configuration.md),
[upgrading](upgrading.md).

## The run itself

**A prompt stays `pending`.** The watcher is not running (`chirat-watch
status`), the workspace is not in `~/.config/chirat/workspaces`, the file name
does not match the pattern (`chirat-prompt lint <ws>`, or `misnamed` in the
log), or an `after:` is unmet (`chirat-prompt waiting <ws>`). See
[prompts](prompts.md) for the naming rules and `after:`.

**A run ends `failed` within seconds.** The plugin is not installed for this
user, or the `claude` login expired: `chirat-watch doctor --online`; the `.err`
names which. If `claude` or `chirat-watch` is not found, check `PATH`
(`chirat-watch doctor` reports it; `chirat-watch install` hints at it).

**A run ends `blocked` on a permission.** `--permission-prompts none` denied
something the classifier would have asked about; the top of the status file
says what. Re-plan the prompt to avoid it, or (less safe) allow it in
`.claude/settings.local.json` and run with `acceptEdits`
([safety](safety.md#permissions)).

**`chirat-watch status` says `STALE`.** Run `chirat-watch recover --dry-run`
first, then `chirat-watch recover`; the rules are in the header of
`bin/chirat-watch`. A `running` prompt without a lock, as an interactive
`/chirat:next` leaves, is only `warn:`.

**A repository is still on the prompt's branch after a run.** A failed or
dirty run does not switch back to the default branch. Look at
`git -C repos/<repo> status`, then check out the default branch yourself once
the tree is clean.

## Notifications

**No notification, nothing in `.err`, `doctor` says `ok terminal-notifier`.**
terminal-notifier has no notification permission yet. macOS lists a
command-line tool under System Settings → Notifications only after its app
bundle has been launched once; by hand the error is `Could not request
notification permission: Notifications are not allowed for this application`.
Launch the bundle, click **Allow**, then check:
`open "$(dirname "$(dirname "$(dirname "$(readlink -f "$(command -v terminal-notifier)")")")")"`
(or `open "$(brew --prefix)/Cellar/terminal-notifier/<version>/terminal-notifier.app"`),
then `chirat-watch doctor --online` → `ok … permission granted`. `doctor` derives
the bundle path the same way and prints it when the permission is missing.

**`[!] -sender is no longer supported` in `.err`.** terminal-notifier 3.x
dropped `-sender`; chirat no longer sends it, so upgrade chirat if you see this.
Conversely `-open` is unknown to 2.x: `brew upgrade terminal-notifier`.

**The notification shows but the click does nothing.** With `notify_open`
unset the click only activates Claude Desktop. Set
`notify_open=claude://claude.ai/project/<uuid>` in `.chirat/config` (read per
run, no restart). Test a URL by hand with `open "claude://…"`; a wrong chat id
shows "That session is no longer available" in Claude Desktop. A `'` in the
value is refused (`warn:` in `.err`).

**Notifications come from "Script Editor".** The watcher did not find
terminal-notifier, often because `brew install` ran after the tmux session
started and its `PATH` is old: `chirat-watch restart`. `chirat-watch doctor`
says which notifier it sees.

**Nothing at all and `.err` is quiet.** Focus / Do Not Disturb, or the style
for terminal-notifier is "None": System Settings → Notifications →
terminal-notifier → Banners or Alerts. `CHIRAT_NOTIFY=0` in the watcher's
environment silences everything too; `chirat-watch status` prints a `notify:`
line per workspace with `CHIRAT_NOTIFY`, `CHIRAT_NOTIFY_OPEN` and `notify_open`
as seen by the shell you ran it in, so run it from the watcher's environment.

## Linux

No desktop notifications; the loop still works through `.chirat/LATEST`,
`chirat-watch status`, or `/chirat:poll` in the chat.
