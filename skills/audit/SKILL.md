---
name: audit
description: Run the Custodian audit over every Claude Code context file and replace the report. Pass --dry-run to list what would be audited without calling a model, or --if-stale to run only when something has changed.
argument-hint: "[--dry-run | --if-stale]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/custodian:*)
---

Run the Custodian audit for the user. Arguments: $ARGUMENTS

1. If the arguments contain `--dry-run`, run `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" dry-run`, show its table and stop. The table has one row per batch: its name, the Claude account that would read it, and how many files.
2. Otherwise run `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" audit` as a background task, because a real audit takes several minutes. Add `--if-stale` when the arguments contain it: the command then checks what has changed since the last audit and, when nothing has, says that nothing was run and spends nothing. Tell the user it has started and that each batch announces itself as it begins and ends.
3. When the task finishes, relay its final line, which holds the counts and the report's path.
   - Exit 2 means the setup needs fixing and nothing was sent. Relay the message, which names the fix. Where it says an account is not logged in, or is set up with a key, the fix is the user's: they log that account in with their Claude subscription, in a terminal. Custodian never audits on a key or a token.
   - Exit 3 or 4 means the run was rejected and the previous report is untouched. Relay the message and the `failed` folder it names. A usage limit shows here too: the message says so, and the audit can be run again once the limit resets.
4. Suggest `/custodian:dashboard` to read the result.

Relay what the command prints, which is counts, ids and paths. The report quotes lines from several groups' files and this conversation runs under one account, so its text belongs in the dashboard. Leave the report, the page and the audited files unread.

Keep ids and paths out of anything you save: a memory, a note or a checkpoint. An id starts with a group's name, and what is saved here is read back under whichever account the next session runs.
