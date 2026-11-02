# chirat

[![CI](https://github.com/azatdavliatshin/chirat/actions/workflows/ci.yml/badge.svg)](https://github.com/azatdavliatshin/chirat/actions/workflows/ci.yml)

chirat is a task queue between a planning chat (Cowork or a Claude Project)
and Claude Code: the chat writes a prompt as a file, a watcher on your
machine runs it with Claude Code on a branch, and the result comes back as a
status file and a diff for you to review.

*chirat* (*chi-RAHT*) is Tatar for "queue; one's turn".

## How it works

1. Discuss a task in the planning chat and have it save a prompt file in the
   workspace (`docs/plans/<topic>.prompt-N.md`).
2. The watcher, running locally, notices the pending prompt and runs Claude
   Code on a branch of your repository.
3. Claude Code commits at the checkpoints the prompt defines and writes a
   status report (`docs/status/`).
4. You read the report and the diff, in the chat or on your machine.
5. Review and iterate with a follow-up prompt until you are satisfied.
6. Merge and push yourself. chirat never does.

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
release decisions with me. More in [docs/workflow.md](docs/workflow.md).

## Before you start

chirat fits you if you already plan with Claude in a chat and run Claude Code
on your own repositories, and want the handoff between them automated.

It requires a separate *workspace folder* beside your repositories:
`docs/plans/`, `docs/status/`, `.chirat/`, and each repository cloned into
`repos/<repo>/`. `chirat-init` creates one. Using it inside a single
repository, with plans next to the code, is not supported yet; the plugin
alone does not lift that requirement.

You need macOS or Linux, Bash 3.2+, `git`, and `claude` installed and logged
in. The planning session must be able to read and write the workspace files;
not every Claude Project has access to a local folder, so check yours.

## Safety

Read this before your first run. Runs happen on your machine, with your
`claude` login and whatever credentials are available there. The default
permission mode is `auto`: a classifier, not you, approves each action. A
plugin hook refuses `git push`, `npm publish` and commits of workspace files,
but it is defense in depth against accidents, not a sandbox. `git push` and
`npm publish` are also denied in the workspace settings, and you do the
merging. The watcher needs no server of its own; Claude Code still uses its
service. Details: [docs/safety.md](docs/safety.md#what-it-is-for).

## Install

In your terminal:

```bash
git clone https://github.com/azatdavliatshin/chirat ~/code/chirat-src
~/code/chirat-src/bin/chirat-watch install   # chirat-watch, chirat-prompt → ~/.local/bin
```

Make sure `~/.local/bin` is on your `PATH` (`install` says if not). Then,
typed inside a Claude Code session:

```
/plugin marketplace add ~/code/chirat-src
/plugin install chirat@chirat
```

Next, [docs/getting-started.md](docs/getting-started.md) walks through
creating a workspace and running your first task.

## Documentation

| File | Read it when |
|---|---|
| [getting-started.md](docs/getting-started.md) | you are setting up and running the first task |
| [workflow.md](docs/workflow.md) | you want to know why the workspace is laid out this way and how to use it |
| [prompts.md](docs/prompts.md) | you write prompt files: naming, front matter, `after:`, checkpoints |
| [commands.md](docs/commands.md) | you need a `chirat-watch` / `chirat-prompt` command or flag |
| [configuration.md](docs/configuration.md) | you change `.chirat/config`, environment variables or notifications |
| [safety.md](docs/safety.md) | you want to know what runs can do and what the commit guard covers |
| [troubleshooting.md](docs/troubleshooting.md) | a prompt is stuck, a run failed or a notification is missing |
| [upgrading.md](docs/upgrading.md) | you update chirat or move over from *relay* |
| [development.md](docs/development.md) | you run the tests or report a guard bypass |

## License

MIT, see [LICENSE](LICENSE).
