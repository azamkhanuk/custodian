---
name: dashboard
description: Generate the Custodian dashboard page from the latest audit and open it in the browser.
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/custodian:*)
---

Open the Custodian dashboard for the user.

1. Run `"${CLAUDE_PLUGIN_ROOT}/bin/custodian" dashboard`. It first checks what has changed on disk since the audit and prints the counts, then writes one self-contained page into the user's data folder and opens it in their browser. Relay the counts. When anything has changed, offer `/custodian:audit`.
2. If it says there is no report yet, or that the report predates the dashboard, offer `/custodian:audit`.
3. Tell the user how saving works: tick the entries they accept, press "Copy for Claude Code", and paste the result here. The page cannot write to disk, so `/custodian:ack` does the saving.

Relay what the command prints. The page quotes lines from several groups' files and this conversation runs under one account, so leave the page, the report and the state file unread.

Keep ids and paths out of anything you save: a memory, a note or a checkpoint. An id starts with a group's name, and what is saved here is read back under whichever account the next session runs.
