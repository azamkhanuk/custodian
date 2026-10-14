---
name: ack
description: Save the acknowledgements the Custodian dashboard prepared. Takes the payload the page copies.
argument-hint: "<payload copied from the dashboard>"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/custodian:*)
---

Save the user's acknowledgements. Arguments: $ARGUMENTS

1. If there are no arguments, explain where a payload comes from: in the dashboard, tick the entries to accept, press "Copy for Claude Code" and paste the result. Then stop.
2. Otherwise run `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" ack $ARGUMENTS`, passing the payload exactly as given. It holds only opaque keys and the user's own notes.
3. Relay the result, which is counts only. On success, tell the user to refresh the dashboard. If a key was not recognised, the report has changed since the page was generated, so suggest `/custodian:dashboard` and ticking the entries again.

The payload and the command's output hold keys, notes and counts. The report quotes lines from several groups' files and this conversation runs under one account, so leave the report, the page and the state file unread.

Keep ids and paths out of anything you save: a memory, a note or a checkpoint. An id starts with a group's name, and what is saved here is read back under whichever account the next session runs.
