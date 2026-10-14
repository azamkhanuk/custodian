# Commands and skills

What the plugin adds to Claude Code: one command, four skills that call it, and one hook. The hook is in [Knowing when to run it](freshness.md#the-reminder).

## The command

Inside a session the skills run `custodian` for you. [Install, update and remove](install.md#the-terminal-command) says how to run it from a terminal.

| Command | What it does |
|---|---|
| `custodian audit` | Judge everything and replace the report. Takes minutes |
| `custodian audit --dry-run` | The same as `custodian dry-run --json` |
| `custodian audit --if-stale` | Audit only if something has changed since the last one. Otherwise say so and spend nothing |
| `custodian dry-run [--json]` | List what would be audited: one row per batch, the account that reads it, and its size. Calls no model. `--json` prints every file with its facts |
| `custodian status [--json]` | Say what has changed since the audit, whether the report is stale and why, and what the reminder would say |
| `custodian dashboard [--no-open]` | Check what has changed, generate the page and open it. `--no-open` only writes it |
| `custodian ack <payload>` | Save what you accepted in the dashboard. The payload is what the page copies |
| `custodian detect [--json] [--all]` | Read the disk and propose a config. Writes nothing. `--all` shows offers you turned down too |
| `custodian detect --decline <key>` | Record an offer you turn down, so it is not made again |
| `custodian init` | Create the data folder, a starter config and the examples file. It keeps what is already there |
| `custodian init --launcher <folder>` | Install the terminal launcher into a folder on your `PATH` |
| `custodian init --import <config>` | Bring in a config, with its examples and report, from before the data folder existed |
| `custodian doctor` | Check this machine, each account's login and the data folder. Each fault is a line that starts `FIX` and names its fix |
| `custodian version` | Print the version |

### Exit codes

An exit code says whether the command worked, never what it found.

| Command | 0 | Otherwise |
|---|---|---|
| `audit` | a report was written, or `--if-stale` found nothing to do | 2 a setup problem, and nothing was sent; 3 a session failed or broke the seal; 4 its answer was rejected; 1 Custodian itself could not go on |
| `dry-run`, `status`, `dashboard`, `detect` | it ran | 2 a setup problem |
| `ack` | the acknowledgements were saved | 2 a payload it does not understand, or a key the report no longer has |
| `doctor` | nothing to fix | 1 at least one `FIX` line |

Anywhere but macOS every command except `doctor` and `version` exits 2 before it writes anything.

## The skills

Each is one you type. None is ever started by the model.

| Skill | What it does |
|---|---|
| `/custodian:setup` | Checks the machine and each login, reads the disk, asks what is left, shows the config before writing it, and explains the examples |
| `/custodian:audit [--dry-run \| --if-stale]` | Runs the audit in the background and relays its last line: counts and the report's path |
| `/custodian:dashboard` | Generates the page, opens it and relays what has changed since the audit |
| `/custodian:ack <payload>` | Saves what the page copied |

The skills relay counts, ids and paths. They never read the report, the page or your audited files into the conversation, because a report mixes groups and a conversation runs under one account.

## For whoever changes it

```
test/run.smoke.sh              # the audit, against an invented estate with a stand-in claude
test/custodian.smoke.sh        # everything behind bin/custodian, and the hook
test/run.smoke.sh --loaded     # asks the real Claude Code which files it loads; logged out, costs nothing
test/run.smoke.sh --live       # the real model on the invented estate; spends usage
claude --plugin-dir .          # load the plugin for one session
scripts/release-check.sh       # before any release
```

Either suite takes a group's name to run that group alone. Read [CONTEXT.md](../CONTEXT.md) before changing anything: it holds the decisions, the traps and the change log.

A release raises the version in `.claude-plugin/plugin.json` and adds its section at the top of [CHANGELOG.md](../CHANGELOG.md). The checks run both suites on macOS, and the release is tagged and published once they pass on `main`. In a clone that publishes, link `scripts/pre-push` as `.git/hooks/pre-push`, so a push that names something of yours is stopped.
