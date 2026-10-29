---
name: poll
description: Planning-side check-in rule for runs started by relay — when and how to look for results without a fixed timer. Use when the human says "check" or "poll", asks what happened to the run, or wants a check-in set up while they are away.
argument-hint: "[workspace path]"
allowed-tools: Bash(tail *) Bash(grep *) Bash(ls *) Bash(find *) Bash(cksum *) Bash(wc *)
---

# /relay:poll

For the **planning** session (Cowork, or a Claude Project with this plugin).
`/relay:next` is the executor's side; this skill never runs a prompt.

## The rule

Every poll is a turn of the planning chat with its full context; a 3-minute
timer over a night is ~160 turns, almost all empty. So: signal first.

1. **Human at the machine** — no polling. `relay-watch` posts a macOS
   notification when a run ends; the human reads the status file and pings
   this chat.
2. **"check"** (or right after enqueueing a prompt) — read the last line of
   `.relay/LATEST` (or the lines newer than the last one reported).
   `running` lives in the prompt's front matter, not in LATEST.
3. **Human away, Mac awake** — adaptive poll (below), unless the workspace
   `CLAUDE.md` or `docs/WORKFLOW.md` says `cowork_poll: off`.
4. **Night** — no poll. The human writes first in the morning; catch up in
   one turn.
5. **Mac unreachable** (asleep, app closed) — retry once after 10 minutes,
   then stop.

## Fingerprint

One command over the workspace path `W`; it prints a single checksum of the
prompt statuses, the status-file listing, the last LATEST line and the count
of non-empty run logs:

```
W=/path/to/workspace; { grep -H '^status:' "$W"/docs/plans/*.prompt-*.md; ls "$W"/docs/status/*.md; tail -n 1 "$W"/.relay/LATEST; find "$W"/.relay/runs -name '*.json' -size +0 | wc -l; } 2>/dev/null | cksum
```

## A tick

1. Run the fingerprint command.
2. Compare with the fingerprint carried in the reminder text.
3. **Unchanged** — schedule the next tick per the cadence; say nothing.
4. **Changed** — read the last LATEST line and the newest status file,
   report in one short message, then re-plan (next tick, or stop).

## Cadence

| Situation | Next check |
|---|---|
| First check after enqueueing | expected run length: sonnet ≈ 10 min, opus ≈ 20–25 min (see `.relay/runs/`) |
| Run still going, nothing changed | every 10 min |
| Queue empty (no `pending`/`running`) | one 60-min tick, then stop |
| Night | none |
| Two failed reaches in a row | stop |

## Reminder text

Schedule each tick with the fingerprint and the tick count inside the
reminder itself, so an unchanged tick needs no file reads:

```
relay poll <workspace> · tick 3 · fp 1234567890 4321 · rerun /relay:poll fingerprint, compare, silent if equal
```

Increment the tick on every reschedule; the checksum is the first number
`cksum` prints.
