# What leaves your machine

What an audit sends, under which account, and what holds it to that. Nothing else leaves.

## What is sent

The contents of your context files are sent to Anthropic through Claude Code, under a Claude subscription, one group at a time. That includes any file one of them imports with `@path`, when it is of a type Claude Code itself imports, and your examples file, which goes with every batch.

| A batch for | Is read under | And is sent |
|---|---|---|
| your global files | your own account | those files |
| a group with no account of its own, or your standalone repos | your own account | that group's files, with your global CLAUDE.md, your global rule files and what they import, for comparison. A session you opened there would load those too |
| a group with an account of its own | that account alone | that group's files, and nothing else |

A group with an account of its own is told no other group's name and no standalone repo's name, and it is sent none of your global files. Where one of its files is linked from, imported by or sits beneath a place outside the group, or is loaded only by another group, the session is told only `outside this group`. The report on your disk keeps every path.

Two groups never share a context window.

## A subscription, and nothing else

No API key, token or other provider is ever used. Three things hold that:

1. **What the session is given.** The audit's sessions get [the variables listed below](#the-variables-a-session-is-given) from your shell, and no other. No variable that picks a key, a token or a provider is among them, whether Claude Code documents it or not.
2. **Who is logged in.** Before anything is sent, each account is asked `claude auth status` in that same environment. It has to answer a logged-in Claude subscription. An account that is logged out, or set up with a key, a token or another provider, is refused, with the command that logs it in.
3. **What the session reports.** Its first event has to say that no key is in use. If it names one, the session is stopped.

A key kept in an account's own Claude Code settings refuses the audit for that account, though the audit's session would not have used it. Claude Code's own answer reads those settings, and a run that goes ahead on a guess is worse than one that says what it found.

## The variables a session is given

| What for | Names |
|---|---|
| What a process needs | `HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, `TMPDIR`, `LANG`, `TERM`, `TZ`, `__CF_USER_TEXT_ENCODING`, and any `LC_*` or `XDG_*` |
| Your proxy | `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, `ALL_PROXY`, and the same four in lowercase |
| Your certificates | `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_TLS_REJECT_UNAUTHORIZED`, `NODE_USE_SYSTEM_CA`, `CLAUDE_CODE_CERT_STORE`, `CLAUDE_CODE_CLIENT_CERT`, `CLAUDE_CODE_CLIENT_KEY`, `CLAUDE_CODE_CLIENT_KEY_PASSPHRASE`, `CLAUDE_CODE_PROXY_RESOLVES_HOSTS` |
| The output limit | `CLAUDE_CODE_MAX_OUTPUT_TOKENS` |

The audit sets three more itself: the switch that turns Claude Code's own analytics and error reports off, the config folder of the account a batch is read under, where your config names one, and a mark that keeps the reminder silent inside the audit's own sessions.

Your proxy and certificate settings do pass, because they are how your own sessions reach the network at all. Everything else in your shell is left out, such as `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL` or `CLAUDE_CODE_USE_BEDROCK`. `custodian doctor` names what of Anthropic's and Claude Code's is set in your shell and left out.

A list of what to leave out could not be kept whole: Claude Code reads dozens of variables its documentation does not list. So this is a list of what passes. If your network needs a variable that is not on it, a batch fails to connect and says so.

## Nothing else

- **Claude Code's own analytics are off** for the audit's sessions, whatever your settings say. A sealed session does not read your settings, so a switch kept there would not be honoured.
- **The dashboard cannot connect to anything.** Its policy allows only its own script and style, and forbids every connection.
- **The reminder connects to nothing** and tells the model nothing.
- **`custodian detect` sends nothing.** It reads folder names, the address of a checkout's remote and an `estate.json`.
- **Custodian has no telemetry of its own.**

## What is kept on your disk

Everything of yours lives in one folder, `~/.custodian` unless you set `CUSTODIAN_HOME`, readable by you alone:

| File | What it holds |
|---|---|
| `config.json`, `examples.md` | what to audit, and your taste |
| `audit.json` | the report |
| `baseline.json`, `status.json` | what the audit saw, and what has drifted since |
| `state.json` | what you accepted in the dashboard |
| `setup.json` | the offers you turned down at setup |
| `dashboard.html` | the generated page |
| `failed/` | the prompt, the session's output and the reason, after a run that failed |
| `hook/`, `plugin-root` | the reminder's stamps, and where the plugin is installed |

The plugin's own folder holds none of it, so an update cannot touch it. Delete that folder and Custodian knows nothing about you.

The skills show you counts, ids and paths only. They never read the report into a conversation, because a report mixes groups and a conversation runs under one account. The `failed` folder holds your files' text for the same reason: read it yourself.
