# An audit, step by step

What `custodian audit` does between your typing it and the report landing on your disk. The runner owns every fact, and the model owns only the judgement.

![The six steps of an audit: discover finds every file a session loads, place gives each its tier by reach, seal starts a session that can only read and proves it, judge reads one batch per group under that group's account, check verifies every quote against the file, and report writes the report, the baseline and the page](step-by-step.png)

| Step | What happens | Where to look |
|---|---|---|
| [1. Discover](#1-discover) | Every file a session loads is found, once each | `custodian dry-run` |
| [2. Place](#2-place) | Each file is given its tier by reach | the `tier` and `scope` of each item |
| [3. Seal](#3-seal) | A session that can only read is started, and has to prove it | exit 2 or 3 when it cannot |
| [4. Judge](#4-judge) | One batch per group is judged, each under its own account | the lines the audit prints as it goes |
| [5. Check](#5-check) | Every quote is checked against the file | exit 4 when one is not there |
| [6. Report](#6-report) | The report, the baseline and the page are written | `custodian dashboard` |

## 1. Discover

The runner looks under every root your config names.

| Kind | Where it is found |
|---|---|
| CLAUDE.md | `CLAUDE.md`, `CLAUDE.local.md` and `.claude/CLAUDE.md` in a root |
| Rule file | every `.md` under `rules/` in a Claude config folder, and under `.claude/rules/` in a group folder or a repo, eight folders deep |
| Skill | `skills/*/SKILL.md` and `.claude/skills/*/SKILL.md` |
| Agent | `agents/*.md` and `.claude/agents/*.md` |
| Command | every `.md` under `commands/` in a Claude config folder, and under `.claude/commands/` elsewhere |
| File above a root | `CLAUDE.md`, `CLAUDE.local.md`, `.claude/CLAUDE.md` and the rule files under `.claude/rules/`, in every folder above a group folder or a repo |
| Imported file | a file that a CLAUDE.md, a rule file or another imported file names with `@path`, four files deep |

It follows links, audits each real file once, and records every place the file is linked from. Whatever it passes over it names: a dangling link, a file it cannot read, a path your config leaves out, a file type Claude Code does not import, and a name that holds a tab, a line break or a backslash.

`custodian dry-run` stops here and prints one row per batch. It calls no model.

## 2. Place

A file's tier is the broadest place it is loaded from, not where its bytes live.

- A file in a global root is **global**.
- A group's skill linked into your global skills folder is **global** too, and that is how a leak is caught.
- A file reached by two groups is **global**.
- A file reached by a group's folder, or by two repos of one group, belongs to that **group**.
- A file reached by one repo belongs to that **repo**.

Where the file lives still decides who reads it. A group's file is read in that group's batch, under that group's account, whatever its reach.

## 3. Seal

The files are split into one batch per group: `global`, one for each group, and `unscoped` for standalone repos. Each batch is judged by its own headless Claude Code session.

Before anything is sent:

- Claude Code has to be 2.1.295 or later.
- Each account a batch would run under is asked who is logged in, and has to answer with a Claude subscription.

Then, for each batch:

- The batch's files are copied into a folder of their own, and the session is fenced into it.
- The session is started in safe mode, with three tools, Read, Glob and Grep, no MCP server, and a permission mode that asks nothing and allows nothing else.
- It is given a named list of variables from your shell and no key, token or provider. [What leaves your machine](privacy.md) has the list.
- Its first event has to show it: those tools and no other, no MCP server, no plugin but Claude Code's own, and no key. If it does not, or it says Claude Code's analytics are on, the session is stopped there, before the batch is judged.

## 4. Judge

The session is given the prompt, your [examples](config.md#your-examples) and a manifest: for each file, where it sits, how far it reaches and where to read its copy.

- A CLAUDE.md, a rule file and an imported file are judged line by line. Each flagged line is quoted.
- A skill, an agent and a command are judged whole. The description weighs most, because it loads into every session within reach even when the body never does.
- The test is one question: would this still make sense if the client disappeared tomorrow?

| What the judge finds | Verdict |
|---|---|
| The content belongs where it sits | pass |
| Content specific to one client, where a session outside that client loads it | fail: a **leak** |
| Content in the wrong tier of the right owner, too specific or too generic | warn: **misfiled** |

A block a tool wrote into a file is not yours to move. Custodian knows the one context-central writes into a hub, tells the judge which lines it is, and never reports it as too generic. A leak inside it is still reported.

## 5. Check

Whatever the session returns that can be checked, is.

- There has to be exactly one judgement for every file in the batch, and none for any other.
- Every quoted line has to be in the file. One that is not rejects the whole run.
- A file judged line by line takes the worst verdict among its lines, whatever the session said of the file as a whole.

## 6. Report

Only when every batch has passed does anything replace what was there.

- The report, `audit.json`, replaces the last one.
- The baseline records a fingerprint of every file judged, so drift can be measured from then on.
- The page is generated again.
- The audit says what the sessions used: tokens in and out, the time it took, and the figure Claude Code gives as cost. That figure is what the API would have charged. A subscription is not charged by the run; it counts against your plan's usage.

A failed run leaves the last report untouched and keeps the prompt, the session's output and the reason in a `failed` folder beside it.

## The exit code

It says whether the audit ran, never what it found.

| Code | Meaning |
|---|---|
| 0 | A report was written |
| 1 | Custodian itself could not go on: a file it could not read or write. The last report is untouched |
| 2 | A setup problem: the config, the examples, a login, the Claude Code version, or a run already going. Nothing was sent |
| 3 | A session failed, timed out, hit a usage limit or broke the seal |
| 4 | The answer was rejected: a quote that is not in the file, or a shape that does not fit |
