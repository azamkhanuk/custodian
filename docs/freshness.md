# Knowing when to run it

An audit describes your disk as it was. Custodian fingerprints what it judged, so it can say when the report has stopped being true, and it tells you in one line when a session starts.

## When a report is stale

A report is **stale** when any of these holds:

| Reason | What changed |
|---|---|
| drift | a file it judged changed, appeared, went, or is now loaded from somewhere else |
| examples | your examples file |
| roots | your config's roots or exclusions |
| judge | the model, or the accounts in your config |
| prompt | the prompt Custodian judges by, as an update can change it |
| age | it is older than `stale_after_days`, which is 7 unless you set it |

Drift is measured by content, so a checkout that only touches modification times changes nothing. It has four kinds: **changed**, **new**, **gone** and **relinked**. Relinked is the same file loaded from different places, which is how a group's skill becomes global.

## Asking

```
custodian status
```

It says how old the audit is, what has drifted since, whether the report is stale and why, and what the reminder would say. `--json` prints the same for a script. It exits 0 whether or not the report is stale.

```
custodian audit --if-stale
```

It audits only if something has changed since the last one. Otherwise it says so and spends nothing.

The dashboard asks too: its first line says what has changed since the audit, a card says when its file changed after it was judged, and new files are listed as not yet judged.

## The reminder

The plugin has one hook. When you start or resume a session and the report is stale, or a leak is still open, you see one line such as:

```
SessionStart:startup says: Custodian: 3 context files have changed, appeared or gone since your audit 2 days ago. /custodian:audit re-judges everything, /custodian:dashboard shows the detail.
```

- It is shown to you and never given to the model, so it costs no tokens and steers nothing.
- It holds counts, ages and Custodian's own commands. It never names a file, a folder or a group.
- It appears at most once a day, in one session, however many you start together.
- It is silent before your first audit, in headless sessions and inside the audit's own sessions.
- It checks at most once an hour, and that check costs the same for thirty files as for three.

What it reads: your config, and two small files the audit and `custodian status` keep in your data folder. It lists and stats your context files, and hashes only the ones whose size or time changed. It never opens the report, calls no model and makes no connection.

What it writes: only inside your data folder. Its own stamps, a note when a check fails, and the pointer your terminal launcher follows.

It does not see a changed prompt, which would cost it a hash. `custodian status` does. With no baseline beside a report, as after a report written by a much older version, it says only the audit's age and the leaks still open.

`"remind": false` in the config turns it off. `custodian doctor` says whether it is on and when it last spoke.
