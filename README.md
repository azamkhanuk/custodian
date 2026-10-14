# Custodian

A Claude Code plugin that audits where your Claude Code context sits, and shows you what leaks from one client's work into another's, on a page on your own machine.

![How Custodian works: your context sits in three tiers, global, group and repo, and reach decides which tier a file is in. An audit judges one batch per group with a session that can only read, each under the Claude subscription that group uses, and no key or token is ever used. Verdicts and quoted lines come back, every quote is checked against the file, and a report is written to your disk. From it you get a dashboard that shows leaks first, a status that says what has drifted, a reminder of one line a day at most, and a way to accept what is intended](docs/how-it-works.png)

## What it does

- **Finds every file a session loads.** Every CLAUDE.md, rule file, skill, agent and custom command under the folders you name, the files above them, and the files they import.
- **Sorts each one by reach.** A file's tier is the broadest place it is loaded from, not where its bytes live.
- **Asks a model that cannot act.** A headless Claude Code session with three tools, Read, Glob and Grep, fenced into a folder of copies, judges whether each file sits in the right tier.
- **Reads each group under its own account.** A group that has its own Claude account is read only under it, and is sent nothing else.
- **Checks every quote.** The session returns verdicts and quoted lines, and a quote that is not in the file rejects the whole run.
- **Shows the result on a page on your disk.** Leaks first, then a tree of where files live, and for every file how far it is loaded against how far its content belongs.
- **Says when the report has gone stale.** It fingerprints what it judged, measures what has drifted since, and tells you in one line when a session starts.

## How it helps

- **A leak is found before a client's session reads it.** A staging host pasted into your global CLAUDE.md, or one client's review rules in a skill linked into your global folder, is named with the line it sits on.
- **Nothing is changed.** Custodian reports; you move the files.
- **It runs on your Claude subscription.** No API key, token or other provider is ever used, and an account set up for one is refused before anything is sent.
- **It follows your taste.** Your own examples of what is right for every session, and what must never be global, go into the prompt word for word.
- **It stays quiet.** Nothing runs on a schedule. The reminder is one line a day at most, shown to you and never to the model.
- **It is plain files.** Bash and `jq`, one data folder that is yours alone, a page with no server, and no telemetry of its own.
- **It sits beside context-central.** Neither needs the other, and a context-central estate is offered as a group at setup.

## The core idea

Reach decides, not where a file lives. Your context sits in three tiers, and the tier decides who can load a file.

| Tier | Loaded by | What belongs there |
|---|---|---|
| Global | every session on the machine | what would still make sense if every client disappeared tomorrow |
| Group | the sessions of one client, or of one multi-repo product | that group's systems and conventions |
| Repo | sessions inside one codebase | that codebase's own quirks |

Two things can be wrong with where a file sits:

- A **leak**: content specific to one client, where another client's session can load it. It is the only thing that fails.
- **Misfiled**: content in the wrong tier of the right owner, too specific or too generic for where it sits. It is a warning.

No pattern match can tell whether a line names a client, a system or a convention that would not exist elsewhere. That is a judgement about meaning, so Custodian asks a model, but only a model that cannot act. [An audit, step by step](docs/audit.md) shows how that is held.

## How it works for you

1. **Set it up once.** Install the plugin and run `/custodian:setup`. It reads what it can from disk, asks what is left, and shows you the config before it writes it.
2. **Say what your taste is.** A few lines of your own in the examples file: what is right for every session, and what must never be global.
3. **Run the audit.** `/custodian:audit` judges everything and replaces the report. It takes minutes.
4. **Read the dashboard.** `/custodian:dashboard` opens the page, leaks first.
5. **Move the files, or accept what is intended.** Tick a flagged line you mean to keep, and it stays folded away for as long as its text is unchanged.
6. **Run it again when it tells you.** When files have changed since the audit, a session's first line says so. `/custodian:audit --if-stale` spends nothing when nothing has changed.

## Install

It needs:

- macOS 13 or later
- Claude Code 2.1.295 or later
- a Claude subscription, logged in for every account the audit reads under
- `jq` and `check-jsonschema`: `brew install jq check-jsonschema`

```sh
claude plugin marketplace add azamkhanuk/claude-plugins
claude plugin install custodian@azamkhanuk
```

Then run this in any session:

```
/custodian:setup
```

[Install, update and remove](docs/install.md) has the rest: installing from inside a session or from a local clone, updating, [what the first run does](docs/install.md#first-run), [two accounts on one machine](docs/install.md#two-accounts-on-one-machine), [the terminal command](docs/install.md#the-terminal-command), [turning the reminder off](docs/install.md#turning-the-reminder-off), removing it and [troubleshooting](docs/install.md#troubleshooting).

Linux and Windows are not supported. [What it does not do](docs/limits.md) lists that with every other limit.

## An audit, step by step

An audit goes through six steps. The runner owns every fact, and the model owns only the judgement: anything the runner can work out is never asked of the model, and anything the model returns that can be checked is checked.

![The six steps of an audit: discover finds every file a session loads, place gives each its tier by reach, seal starts a session that can only read and proves it, judge reads one batch per group under that group's account, check verifies every quote against the file, and report writes the report, the baseline and the page](docs/step-by-step.png)

| Step | What happens | Where to look |
|---|---|---|
| [1. Discover](docs/audit.md#1-discover) | Every file a session loads is found, once each | `custodian dry-run` |
| [2. Place](docs/audit.md#2-place) | Each file is given its tier by reach | the tier of each item |
| [3. Seal](docs/audit.md#3-seal) | A session that can only read is started, and has to prove it | exit 2 or 3 when it cannot |
| [4. Judge](docs/audit.md#4-judge) | One batch per group is judged, each under its own account | the lines the audit prints as it goes |
| [5. Check](docs/audit.md#5-check) | Every quote is checked against the file | exit 4 when one is not there |
| [6. Report](docs/audit.md#6-report) | The report, the baseline and the page are written | `/custodian:dashboard` |

[An audit, step by step](docs/audit.md) says what each step finds, sends and checks, and [what the exit code means](docs/audit.md#the-exit-code).

## Where the detail lives

The README is the short version. Each part has a file of its own under `docs/`:

| Part | What its file covers |
|---|---|
| [Install, update and remove](docs/install.md) | What it needs, installing from a session or a local clone, updating, the first run, two accounts on one machine, the terminal command, turning the reminder off, removing it and troubleshooting |
| [An audit, step by step](docs/audit.md) | What each of the six steps finds, sends and checks, the verdicts, what a run used, and the exit code |
| [The config and your examples](docs/config.md) | Every key of the config, the roots, the two globs, accounts, what setup detects, and the examples file |
| [What leaves your machine](docs/privacy.md) | What each kind of group is sent, how a subscription and nothing else is held, the variables a session is given, and what is kept on your disk |
| [Knowing when to run it](docs/freshness.md) | When a report is stale, the four kinds of drift, `custodian status`, and what the reminder reads and never does |
| [The dashboard, and accepting things](docs/dashboard.md) | What the page shows, how drift is marked, and how a line you mean to keep is accepted |
| [Commands and skills](docs/commands.md) | Every command of `custodian` with its flags and exit codes, the four skills, and the checks for whoever changes the plugin |
| [Beside context-central](docs/context-central.md) | How an estate is offered as a group, how a hub is found and judged, and the one block Custodian knows |
| [What it does not do](docs/limits.md) | Every limit: what it does not see, the imports it cannot be sure of, and what has not been shown |

[CONTEXT.md](CONTEXT.md) holds the plugin's decisions and its terms. [CHANGELOG.md](CHANGELOG.md) says what each release changed.

## What it does not do

- It changes nothing it audits, and it runs nothing on a schedule.
- It does not use an API key, a token or another provider. It needs a Claude subscription.
- It does not see a skill's other files, a CLAUDE.md nested deeper inside a repo, the skills of an installed plugin, or your organisation's managed policy.
- It does not follow an import it cannot be sure Claude Code would load, so that it never sends a file no session would load.
- It does not make a verdict true. Every quote is checked against the file, but the verdict is a model's judgement, steered by your examples.
- It runs on macOS only.

The full list is in [What it does not do](docs/limits.md).

## Licence

[MIT](LICENSE).
