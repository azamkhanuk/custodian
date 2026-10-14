# Install, update and remove

How to install the plugin, what the first run does, how a release reaches it, how to turn the reminder off and how to remove it. The [README](../README.md#install) has the two commands most people need.

## What it needs

- macOS 13 or later
- Claude Code 2.1.295 or later
- a Claude subscription, logged in for every account the audit reads under
- `jq`, which ships with macOS 15 and is otherwise `brew install jq`
- `check-jsonschema`: `brew install check-jsonschema`

Linux and Windows are not supported. There every command but `doctor` and `version` refuses before it writes anything, and the reminder stays silent.

Claude Code 2.1.295 fixed `--tools` and `--restricted` not applying to tools that register after a session starts. The read-only promise rests on that, so an older Claude Code is refused: `claude update` brings a newer one.

An API key, a token, Amazon Bedrock, Google Vertex AI and Microsoft Foundry are not used, and an account set up for one of them is refused. [What leaves your machine](privacy.md#a-subscription-and-nothing-else) says how that is held.

`custodian doctor` checks all of it.

## Install

From a shell:

```sh
claude plugin marketplace add azamkhanuk/claude-plugins
claude plugin install custodian@azamkhanuk
```

Or from inside a session:

```
/plugin marketplace add azamkhanuk/claude-plugins
/plugin install custodian@azamkhanuk
```

The marketplace is the list of its author's plugins, kept in a repository of its own. [context-central](https://github.com/azamkhanuk/context-central) installs from the same one, and neither plugin needs the other.

**Trying a local clone.** Load it for one session with `claude --plugin-dir <the clone>`. To install it from the clone, give `claude plugin marketplace add` the clone's path. The repository carries a development marketplace of its own, so the plugin is then `custodian@custodian-dev`.

**Updating.** The plugin carries a version, and an installed copy stays on its release until a newer one is published:

```sh
claude plugin marketplace update azamkhanuk
claude plugin update custodian@azamkhanuk
```

Your data folder is never touched by an update. If you installed the terminal launcher, run any Custodian skill once afterwards, so the launcher follows the new version.

**Releases.** [CHANGELOG.md](../CHANGELOG.md) says what each release changed, and what a setup that already exists has to do.

## First run

Run this in any session:

```
/custodian:setup
```

It then:

1. runs `custodian doctor`, and helps with each line that starts `FIX`
2. runs `custodian detect`, which reads your disk and writes nothing
3. shows what it found as a short list: your Claude config folders and who is logged in to each, the folders that work as a group, how your repos are found, and checkouts that look like someone else's
4. puts what the disk did not settle to you in one message, each question with the answer it recommends
5. records each offer you turn down, so it is not made again
6. shows you the whole config, and writes it only once you agree
7. shows a dry run: one row per batch, the account that reads it, and its size
8. explains the examples file, and offers to draft it from your own user-level files
9. offers the terminal launcher

Where a config already holds everything it found, it says so and stops at the dry run. [The config and your examples](config.md) covers the config, the examples and what `detect` reads.

## Two accounts on one machine

If a group has its own Claude account, selected with `CLAUDE_CONFIG_DIR`, name that folder under `slots` for the group. Its files are then read only under that account, and that account is sent nothing else.

Each account has to be logged in with a Claude subscription. `custodian doctor` asks every account the config names and says which is not, with the command that logs it in:

```sh
CLAUDE_CONFIG_DIR=~/.claude-acme claude
```

If your own login is kept in a folder other than `~/.claude`, name it as `default_slot`. Every batch without a slot of its own is then read under it.

Custodian never shows Claude Code a folder it has not used as a config folder. Shown one, Claude Code sets a config up there and migrates whatever settings it finds, so such a folder is said to hold no login without being asked.

## The terminal command

The skills are all you need. To run `custodian` from a terminal as well:

```
custodian init --launcher <a folder on your PATH>
```

It installs a small launcher that finds the installed plugin through your data folder, so it keeps working across plugin updates. It refuses to replace a file that is not its own.

## Turning the reminder off

`"remind": false` in the config turns the session-start line off. `custodian doctor` says whether it is on and when it last spoke. [Knowing when to run it](freshness.md#the-reminder) says what the reminder reads and what it never does.

## Removing

```sh
claude plugin uninstall custodian@azamkhanuk
```

Then delete `~/.custodian`, and the launcher if you installed one. Nothing else was written.

The marketplace can stay. `claude plugin marketplace remove azamkhanuk` removes it, and uninstalls every other plugin you installed from it.

## Troubleshooting

Start with `custodian doctor`: every line that starts `FIX` names its own fix.

| What you see | What it means |
|---|---|
| "is not logged in to Claude Code" | That account has no login. Run the command the message names and log in with your Claude subscription |
| "has never been set up as a Claude Code config folder" | A folder named under `slots` or `default_slot` has never been used by Claude Code, so nobody is logged in there. Run the command the message names and log in |
| "is set up with an API key", "logged in by oauth_token", "set up for bedrock" | That account would not use a subscription, so nothing was sent. A key kept in that account's Claude Code settings counts too, even though the audit's own session would not use it |
| "Claude Code … is older than 2.1.295" | Run `claude update` |
| "has reached its usage limit" | Your plan's limit. The previous report is untouched; run the audit again once the limit resets |
| "the tool surface is wider than Read, Glob, Grep", "a plugin that is not Claude Code's own is listed" | The session was not sealed, so it was stopped at once. A Claude Code update can do this; the message names what was found |
| Every batch fails to connect, on a network that needs a variable of its own | The audit's sessions are given a named list of variables, which holds the usual proxy and certificate ones. `custodian doctor` names what of Anthropic's and Claude Code's is set in your shell and left out |
| "examples.md needs at least 3 list items" | Fill in the examples file in your data folder |
| "another run holds the lock" | An audit is running. A lock left by a run that died is taken over by itself |
| "was written by a version of Custodian this one cannot read" | Another version of the plugin wrote that file. For the report or the baseline, run `custodian audit` to write a fresh one. For `state.json` or `setup.json`, move the file aside; the acknowledgements or the offers you turned down then start again |
| "a backslash in its path", "a tab, a line break or a backslash in its name" | That folder or file is passed over, because Custodian's tables cannot carry such a name. Rename it to have it audited |
| A repo is missing from `custodian dry-run` | Its folder matches neither project glob. Check that the second glob ends in `/.claude` |
| The reminder never appears | `custodian status` says what it would say and why it would stay silent |

A failed audit keeps the prompt, the session's output and the reason in the `failed` folder beside the report. They hold your files' text, so read them yourself and do not paste them into a session under another account.
