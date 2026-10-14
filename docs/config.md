# The config and your examples

Two files in your data folder decide what an audit reads and how it judges: `config.json` and `examples.md`. `/custodian:setup` proposes the first from what is on your disk and helps you write the second.

## The config

`config.json` in your data folder, which is `~/.custodian` unless `CUSTODIAN_HOME` says otherwise. Every path is absolute or starts with `~/`. An unknown key is refused, so a typing mistake is never read as a setting.

```json
{
  "tiers": [
    { "tier": "global",  "path": "~/.claude" },
    { "tier": "client",  "path": "~/Developer/acme", "scope": "acme" },
    { "tier": "client",  "path": "~/.claude-acme",   "scope": "acme" },
    { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" },
    { "tier": "project", "glob": "~/Developer/*/*/.claude" }
  ],
  "slots": { "acme": "~/.claude-acme" },
  "exclude": ["~/Developer/acme/vendored-thing"],
  "editor_url": "zed://file/{path}:{line}"
}
```

| Key | What it is |
|---|---|
| `tiers` | The roots to look under. Needed, and never empty |
| `slots` | For a group with its own Claude account, that account's config folder |
| `default_slot` | The config folder your own login is kept in, when that is not `~/.claude` |
| `exclude` | Paths to leave out, such as a checkout that is someone else's work |
| `editor_url` | An editor's address, so a flagged line in the dashboard opens at that line. It has to hold `{path}`, and may hold `{line}` |
| `model` | The model that judges. The default is `sonnet` |
| `timeout_seconds` | How long one batch may take. The default is 900 |
| `remind` | `false` turns the session-start reminder off |
| `stale_after_days` | A report older than this is stale whatever else is true. The default is 7 |

### The roots

- A `global` root is a Claude config folder that every session loads: `~/.claude`, or the folder `default_slot` names.
- A `client` root is a **group**: a folder of repos that work as one thing, be it a paying client or a multi-repo product of your own. `scope` is your name for it, in lowercase letters, digits and hyphens. It may not be `global`, `project`, `external` or `unscoped`, which Custodian uses itself.
- A `project` root is one repo, by `path` or found by `glob`. A repo inside a group belongs to that group, and any other repo is standalone.

### The two globs

A `project` glob finds repos by something each one holds, and the repo is the folder that holds the match. Keep both shapes:

- `…/CLAUDE.md` finds a repo with a CLAUDE.md at its root.
- `…/.claude` finds a repo that keeps anything in `.claude/`, such as rule files or skills with no CLAUDE.md at all.

A glob that names only a CLAUDE.md passes over a repo that has none, and nothing can say so. Where a folder's own name holds a glob character, escape it in the glob, so that `~/work \[old\]/*/*/.claude` matches the folder called `work [old]`.

### Accounts

`slots` names the Claude config folder of a group that has its own account. List that folder as a second `client` root with the same scope, as above, so what it holds is audited too. That group's files are then read only under that account. Leave `slots` out if you use one account.

`default_slot` is for your own login when it is kept somewhere other than `~/.claude`. It may not name `~/.claude` itself: Claude Code keeps that folder's login under no name, and does not find it once the folder is named.

## What setup detects

`custodian detect` reads your disk and proposes. It writes nothing but an offer you turned down, and it never writes the config.

| It finds | From |
|---|---|
| Your Claude config folders, and who is logged in to each | `~/.claude` and the folders named like it in your home folder |
| Where sessions have run | the names of the folders Claude Code keeps per working folder. It reads names only, never a session |
| Folders that work as a group | a folder of repos with a CLAUDE.md or a `.claude` folder of its own, a context-central estate, or an account whose every session ran there |
| How your repos are found | the two glob shapes, at the depth your repos sit |
| Checkouts that look like someone else's | a remote unlike its neighbours', on a checkout that carries context of its own. The remote is compared and never printed |
| An editor, and a terminal launcher | your Applications folders, and your `PATH` |

Each thing it would add is an **offer** with a key. `custodian detect --decline <key>` records one you turn down, so it is not made again, and `--all` shows those too. Beside a config that already exists it offers only what the config lacks. A checkout that looks like someone else's is offered and never left out without your yes.

`custodian detect --json` prints all of it as one document, with `proposed`: the whole config it would write.

## Your examples

A real audit refuses to start until `examples.md` in your data folder holds:

- at least three lines you consider right for every session, under `## Correctly global`
- at least three that must never sit in the global tier, under `## Leakage`
- when your config has a group, at least one skill that is rightly tied to a group, under `## Correctly client-tier`

Two more headings are optional: `## Correctly project-tier` and `## Too generic for where it sits`.

They are put into the prompt word for word, so verdicts follow your taste and not the model's. Write them with invented names such as acme and globex, because the file is sent with every batch. Revisit it whenever a verdict surprises you: a changed examples file makes the report stale.
