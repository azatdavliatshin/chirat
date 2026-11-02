# Workflow

Why chirat's workspace looks the way it does, and how it is used day to day:
the principles behind it, the author's way of working, and what chirat
automates. Back to the [README](../README.md); related:
[getting started](getting-started.md), [prompts](prompts.md),
[safety](safety.md).

## Why I built this

After trying different ways of working with AI agents, I settled on a
workspace structure: `docs/` holds project documents, including plans and
decisions, SoWs (statements of work), analyses, emails, inputs, and other
related materials, while `repos/` holds the code repositories.

I use Cowork to discuss ideas, compare approaches and prepare prompts for
Claude Code. Claude Code implements the task; I inspect the result and the
diff, then bring them back to Cowork for another review. We iterate on the
implementation—and on the workflow itself—until I'm comfortable shipping it.

The repeated handoff became tedious: moving prompts into execution, checking
whether the work had finished, and bringing the results back into the
planning conversation.

I built chirat to automate that handoff while keeping planning, review and
release decisions with me.

## The workflow came first

The workflow predates chirat: project context and one or several
repositories in a single workspace; plans that carry context from a thinking
session to a fresh coding session; results that come back for review. The
repeated handoff between those steps became the part worth automating, and
that is all chirat does.

## Principles

1. **One workspace, project-wide context.** `docs/` holds inputs, statements
   of work, analyses, plans, decisions, correspondence and reports; `repos/`
   holds one or more code repositories. Planning can cross repository
   boundaries while project context stays out of the delivered code. These
   folders are examples, not mandatory ones; one prompt still names one
   `repo:`. In short: keep project documents and agent context separate from
   the delivered code.
2. **Files carry memory between sessions.** Stable context lives in
   `CLAUDE.md`; evolving plans and results live in documents. A fresh session
   re-anchors from them instead of from a long chat. Neither is perfect: a
   chat remembers things files do not, and files go stale.
3. **A plan connects discussion to execution.** Write it where the context
   accumulated, run it in a fresh session. A good plan has the task,
   evidence, constraints, checkpoints and verifiable completion criteria.
4. **Report evidence.** The checks that were actually run and their results,
   the baseline, pre-existing versus new failures, and the checks that could
   not be run. This is the author's practice; chirat does not enforce it.
5. **Keep decisions explicit.** The human approves scope changes, inspects
   results and decides what ships; external acceptance tests (for example on
   hardware) stay human steps. chirat automates the handoff, not the whole
   process.

## A day with chirat

1. In the planning chat, discuss the task and have the session write
   `docs/plans/<topic>.prompt-N.md` (new prompts as `draft` while
   `prompt_review: on`; you set `pending` after reading them).
2. The watcher picks up a `pending` prompt and runs Claude Code on its
   branch in `repos/<repo>`, committing at the prompt's checkpoints.
3. A status file appears in `docs/status/`; you hear back through a
   notification, `chirat-watch status`, or by saying "check" in the chat
   ([configuration](configuration.md#notifications)).
4. You read the status file and the diff, bring them to the planning chat for
   another review, and iterate with a follow-up prompt on the same branch.
5. When you are comfortable, merge and push yourself. A `done` prompt is a
   branch waiting for your review and merge; nothing lands on the default
   branch by itself, and the next prompt that declares `after:` waits for that
   merge ([prompts](prompts.md#after-and-merges)).
6. Landing steps: after the merge, a status file lists what to run for the
   files the branch touched, from a `## Landing` section in the workspace
   `CLAUDE.md` ([configuration](configuration.md#status-files-and-landing-steps)).

## What chirat automates, and what it does not

| Step | Who |
|---|---|
| Discuss, decide, write the prompt | you and the planning session |
| Hand the prompt to Claude Code, keep the run log, record completion state | the watcher |
| Implement on a branch, commit at checkpoints, write the status file | Claude Code, via `/chirat:next` |
| Inspect the result, review, iterate | you |
| Merge, push, release | you |

Some details differ from a purely manual setup:

- The workspace is a git repository of its own (`chirat-init` creates it);
  the code clones under `repos/` stay independent repositories.
- `/chirat:next` commits on the execution branch at the prompt's checkpoints
  without asking each time. Approving every commit by hand is an optional
  practice, not something chirat does for you.
- The watcher does the prompt handoff and writes completion state and run
  logs. Review stays explicit.
- Team sharing is not a feature: no shared queues, distributed execution,
  team ownership or automatic CI gates.

## Models and reviews

Roles: planning explores and writes prompts, execution implements, you
inspect, and a further review finds omissions and drives another iteration.
A reviewer on a different model can add another perspective; that is a
practice, not a guarantee. The author mostly plans with `fable`, a personal
preference and not a requirement.

Three different things carry a model or effort:

- the prompt's `model:` key selects the model that executes it;
- the read-only `reviewer` agent has its own configured model (`opus`);
- an effort level written in the prompt body is a request in prose; the
  watcher does not forward it as a flag.

There is no automatic model rotation, effort forwarding, autonomous review or
quality gate.
