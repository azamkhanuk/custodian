# Changelog

Each release of Custodian, newest first. The version is the one in `.claude-plugin/plugin.json`. An installed copy stays on its release until `claude plugin update custodian@azamkhanuk` finds a newer one, or until auto-update does where that is on.

## 0.3.0 - 2026-10-14

The audit runs on a Claude subscription and on nothing else, a group with an account of its own is sent only what its sessions load, setup reads the disk before it asks, and four more kinds of context are audited.

- **A subscription, never a key.** A key, a token or a provider variable in the environment used to reach the audit's sessions, and a headless session prefers a key to a stored login, so every group could be read under one credential. The audit's sessions are now given a short named list of variables from your shell and nothing else, each account is asked who is logged in before anything is sent, and a session that reports a key is stopped. An account that is logged out, or set up with a key, a token or another provider, is refused in one sentence that says how to log it in.
- **A group with its own account gets only its own files.** Its batch carried your personal global files and the name of every group. It now carries no reference files and no scope but its own, and where a path would name another place it says `outside this group`. The report on your disk keeps every path.
- **The audit's sessions send your files and nothing else.** Claude Code's own analytics and error reports are switched off for them, whatever your settings say. A sealed session does not read your settings, so a switch kept there was not honoured.
- **A broken seal stops the session at once.** The session's tool surface, its plugins and its key are checked at its first event, not after the batch has been judged.
- **Claude Code 2.1.295 or later.** That release fixed `--tools` and `--restricted` not applying to tools that register after launch, which the read-only promise rests on. An older one is refused by the audit and named by `custodian doctor`.
- **Setup that detects.** `custodian detect` finds your Claude config folders and who is logged in to each, the folders that work as a group, where your repos live, checkouts that look like someone else's, an installed editor and a terminal launcher. `/custodian:setup` shows that, asks only what the disk did not settle, remembers an offer you turned down, and shows the config before it writes it. A context-central estate is offered as a group, read from its own file; that plugin need not be installed.
- **More is audited.** Rule files, custom commands, the CLAUDE.md and rule files in every folder above a group or a repo, and every file a CLAUDE.md or a rule file imports with `@path`, four files deep. `docs/limits.md` says what is still not seen.
- **A repo with no CLAUDE.md is found.** The second project glob is now `…/.claude`, so a repo that keeps only rule files, skills, agents or commands there is audited.
- **`default_slot`.** A new config key for your own login when it is kept in a folder other than `~/.claude`.
- **A folder Claude Code has never used is left alone.** Shown a folder as a config folder, Claude Code sets one up there and migrates whatever settings it finds. Setup and the audit now say that such a folder holds no login without showing it to Claude Code.
- **A block a tool wrote is not yours to move.** The lines context-central writes into every hub are the same in every estate, so the audit tells the judge which they are and reports none of them as too generic. A leak inside them is still a leak.
- **Freshness sees how a report was judged.** A changed model, a changed account or a changed prompt makes the report stale, each with a reason of its own.
- **The report says what a run used.** Tokens in and out, the seconds it took, and the figure Claude Code gives as cost, named as what the API would have charged, since a subscription is not charged by the run.
- **A usage limit is said in so many words**, with Claude Code's own first line, where it used to be "claude exited with status 1".
- **The page's save command needs no launcher.** It finds the installed plugin through your data folder.
- **Only macOS.** Anywhere else every command but `doctor` and `version` refuses before it writes anything, and the reminder stays silent.
- **It installs from one marketplace, `azamkhanuk`.** `claude plugin marketplace add azamkhanuk/claude-plugins`, then `claude plugin install custodian@azamkhanuk`. The marketplace is a list kept in a repository of its own, and context-central installs from the same one. This repository's own marketplace is now `custodian-dev`, for installing from a clone.
- **A shorter README, and a `docs/` folder.** The README is the short version, with a picture of how it works. Installing, the audit step by step, the config, what leaves your machine, freshness, the dashboard, the commands, sitting beside context-central and the limits each have a file of their own.

Faults fixed:

- With `output` set, an audit deleted any folder called `failed` beside the report. It now deletes only its own.
- The first error a newcomer met named `custodian.examples.md`, where the file is `examples.md`, and asked a config with no group for a group example.
- A report, a baseline or saved acknowledgements written by another version were read as if they were this one's. Each reader now asks first.
- A leak in a file that had since gone was still counted by the page's headline, by `custodian status` and by the reminder.
- With no baseline beside a report, the reminder repeated the counts of the last check every day.
- A lock left by a killed run blocked audits while its process number belonged to anything at all.
- A scope could end in a line break.
- A folder or a file with a backslash in its name stopped an audit after sessions had run, and an agent or a skill with a tab in its name stopped it before. Each is now passed over and named.
- An estate of more than about 36 roots made a dry run spin without end.
- A repo that keeps its CLAUDE.md in `.claude/` was called `.claude`, and the files at its root were missed.

Shown by the real model, on an invented estate with Claude Code 2.1.296: every seeded leak fails at its line, in a CLAUDE.md, a rule file, a command, an imported file and a file above two groups, and the clean ones pass. In one run of two it called the block context-central writes into a hub too generic, which is why the audit now drops that finding itself.

Not shown:

- A group read under an account of its own by the real model. The invented estate has one account.
- Both suites on a hosted macOS runner. The workflows are written and have never run.
- An account whose login is a Console key, a gateway or a cloud provider. Only made-up ones were tried.

For a setup that already exists:

- Each account the config names must be logged in with a Claude subscription. `custodian doctor` says which is not.
- A key, a token or a provider variable you export is no longer passed to the audit. Nothing in your shell needs to change.
- Replace a project glob ending `/.claude/CLAUDE.md` with one ending `/.claude`. The old one still works and still misses a repo with no CLAUDE.md.
- A group listed under `slots` no longer gets your global files as reference, so its files draw no "duplicates global tier" findings.
- A report from 0.2.0 is still read. Rule files, commands, imports and files above a root show as new until the next audit.
- The examples need a group example only when the config has a group.
- If you added this repository itself as a marketplace, it keeps the name it was added under and keeps working. To install as the README has it, remove that marketplace, then add `azamkhanuk/claude-plugins` and install `custodian@azamkhanuk`.

## 0.2.0 - 2026-09-21

The first version with all three parts, and the last before anything was published.

- **The audit.** Every CLAUDE.md, skill and agent under the folders you configure, judged by a headless Claude Code session that can only read, one batch per group, each quote checked against its file.
- **The dashboard.** One self-contained page on your disk that shows leaks first, and a save command for what you accept.
- **Freshness.** Every audit fingerprints what it judged, `custodian status` says what has drifted, `audit --if-stale` spends nothing when nothing changed, and one session-start hook tells you, once a day at most.
