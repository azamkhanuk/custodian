# The dashboard, and accepting things

`custodian dashboard` turns the report into one self-contained page on your disk and opens it. The page is a file: it has no server, uses no browser storage and cannot connect to anything.

## What it shows

- **The headline.** How many files leak, how many are misfiled, and how many need nothing from you.
- **How old the audit is,** and what has changed on disk since. It turns amber when the report is stale and red when it is older than `stale_after_days`.
- **Where files live.** A tree of your global folder, each group with its repos, your standalone repos, and files outside every root, with a count of what is open under each.
- **One card for each file.** Where it lives, who loads it, where its content belongs, and the reason. A file judged line by line shows each flagged line, quoted.

Files are in four bands: leaks, misfiled, accepted and in place. Leaks come first.

Drift annotates and never recounts:

- A file that changed after it was judged says so on its card, since its lines may have moved or gone.
- A file now loaded from somewhere else says so, since how far it reaches may have changed.
- A file that no longer exists is listed apart, and is counted neither in the headline nor in the tree.
- A file found since the audit is listed as not yet judged.

The filters and the search live in the page's address, so a filtered view can be bookmarked. With `editor_url` in the config, a card opens its file in your editor at the flagged line.

## Accepting what is intended

Some flagged lines are right where they are. To accept one:

1. Tick "Accept as intended" on it, and add a note if you like.
2. Press a copy button.
3. Paste what it copied.

The page cannot write to your disk, so a command does the saving:

| Button | Gives | Paste it into |
|---|---|---|
| Copy for Claude Code | a `/custodian:ack` command | a Claude Code session |
| Copy save command | a command that finds the installed plugin through your data folder, so it needs no launcher | a terminal |

Then refresh the page.

- An accepted line stays folded away on later audits for as long as its text is unchanged.
- It comes back if the text changes, or if a misfiled line becomes a leak.
- "Stop accepting this" undoes one, the same way.
- What you accepted is kept in `state.json` in your data folder.

The payload holds only opaque keys and your own notes, never a line of a file.
