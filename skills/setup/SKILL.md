---
name: setup
description: Set Custodian up on this machine, or check a setup that exists. Checks the machine and each account's login, reads the disk to propose a config, and explains the examples file.
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/custodian:*)
---

Set Custodian up with the user. Everything that belongs to them lives in their data folder, `~/.custodian` unless `CUSTODIAN_HOME` says otherwise, and never inside this plugin. Detect first and ask afterwards: a question the disk already answers is not put to them.

1. Run `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" doctor`. For each line starting `FIX`, help the user apply the fix it names, then run doctor again. An account that is not logged in is theirs to fix: they run the command the line names in a terminal and log in with their Claude subscription. Custodian audits on a subscription only and never passes a key or a token to the audit, so do not suggest one. Carry on once only the config and examples lines remain.
2. Run `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" detect --json`. It reads the disk and writes nothing.
   - If `config.valid` is false, show `config.problems`, help fix the config, and run it again.
   - If `config.valid` is true and `nothing_to_add` is true, say that the config already holds everything found, go to step 6, and stop there unless they ask to change something.
3. Show what it found as a short list, in this order and leaving out whatever is empty:
   - each entry of `accounts`: its folder, whether it is logged in with a subscription, and where it works;
   - each entry of `groups`: its `scope`, its `path`, how many repos, every reason in `why`, and the account in `slot` when there is one. A group is a folder of repos that work as one thing: a paying client, or a multi-repo product of their own;
   - `default_slot`, which means their own login is kept in a folder other than `~/.claude`;
   - each entry of `globs`, which is how their repos are found;
   - each entry of `foreign`: a checkout whose remote is unlike its neighbours' and which carries context of its own;
   - `dead_excludes`: exclusions in the config that match nothing on disk;
   - `editors`.
4. Put every open question in one message, each with the answer you recommend and why. Leave out what the detection settled.
   - For each group: add it? Recommend yes, and give its reasons. Where it has a `slot`, say that its files will be read only under that account.
   - For each foreign checkout: leave it out? Recommend yes when it is someone else's work.
   - An editor for the dashboard's links? Say why it is wanted: a flagged line then opens in that editor at that line. It is optional.
   - Is there a group the detection did not find? It sees only folders where sessions ran, two levels below where their repos live.
   For each offer they turn down, run `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" detect --decline <key>` with that offer's `key`, so it is not made again.
5. With no config yet, run `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" init`, which creates the data folder, a starter config and the examples file. Then run `detect --json` again and take `proposed` as the config: it holds every offer still standing, and it is proposed whole over the starter config, which is nobody's choice. Add the exclusions and the `editor_url` they agreed to. Show them the whole config, and write it to `config.json` in the data folder only once they agree. Every path starts with `/` or `~/`.
6. Run `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" dry-run` and walk through the table with them: one row per batch, the account that reads it, and its size. A group with an account of its own shows no reference files, because its sessions load none of the personal ones. Adjust the config until they agree with it.
7. Explain the examples file in their data folder. A real audit refuses to start until it holds three lines they consider right for every session, three that must never sit in the global tier and, when the config has a group, one skill that is rightly tied to a group. Offer to draft it from their own user-level CLAUDE.md and skills. Write every example with invented names such as acme and globex, because the file is sent with every batch.
8. If `launcher` was null, offer a terminal command: `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" init --launcher <a folder on their PATH>`, with a folder from `launcher_dirs` where there is one.
9. Finish by naming the two commands they will use: `/custodian:audit` and `/custodian:dashboard`. Tell them about the reminder: once a day at most, when a session starts and context files have changed since the last audit, the plugin shows them one line of counts. To do that it reads their config and two small files in their data folder, lists and stats their context files, and hashes only the ones that look different; it never opens the report and connects to nothing. The model never sees the line, it names no file or group, and `"remind": false` in the config turns it off. `custodian status` in a terminal shows what has changed at any time.

Read only the user's own user-level files when drafting examples. Group and repo files go to the audit, which reads each group under its own account. Once an audit has run, its report quotes lines from several groups' files, so leave the report, the page and the state file unread and relay what the commands print.

Keep ids and paths out of anything you save: a memory, a note or a checkpoint. A path names a group, and what is saved here is read back under whichever account the next session runs.
