# What it does not do

## It does not act

- It changes nothing it audits. Custodian reports; you move the files.
- It runs nothing on a schedule, and nothing calls the model by itself. An audit starts when you start it.
- It does not use an API key, a token or another provider, and it refuses an account set up for one. It needs a Claude subscription.
- It runs on macOS only.

## What it does not see

Custodian judges what a session loads from the files [an audit finds](audit.md#1-discover). It does not see:

- A skill's other files. Only its `SKILL.md` is judged.
- A CLAUDE.md, a rules folder or a skill nested deeper inside a repo, which Claude Code loads when a session works in that folder.
- `AGENTS.md`, unless a CLAUDE.md or a rule file imports it.
- The skills and agents of an installed plugin.
- Output styles, auto memory, settings, what a hook adds to a session, and an MCP server's instructions.
- Your organisation's managed policy files.
- Whether you approved a project's imports from outside it. Claude Code asks once before it loads one, and Custodian counts every such import as loaded.
- A file of a type Claude Code does not import, such as an image. An audit names each one it leaves out.
- A folder or a file with a tab, a line break or a backslash in its name. An audit names each one it passes over.
- A repo that neither project glob matches. Nothing can say that one was passed over.

## Imports it cannot be sure of

Claude Code finds imports by reading a file as Markdown. Custodian reads the blocks of a file the same way, held to what Claude Code was seen to load. Inside a paragraph it stops wherever a code span, a tag or a link could hide what follows, so that it never sends a file no session would load.

Of 1,013 forms tried against Claude Code, it follows 443 of the 525 that Claude Code loads, and none of the rest. It misses an import:

- inside emphasis that holds more than the path, or in a paragraph where a code span, a tag or a link holds an emphasis mark
- straight after an escaped character, or with white space before it that is not a space, a tab or a line break
- inside a reference link, at the start of a link's text, or later in a paragraph than a link with a title or a tag with a quote in it
- whose path holds an asterisk, a bracket, a backtick, or an underscore that is not between two letters or digits

It reads nothing more from a file after a quote whose list or inner quote runs on into a line with no quote mark, and nothing at all from a file nested more than sixty blocks deep.

## What has not been shown

- A group read under an account of its own by the real model. The suites show what such a batch is sent; the live check's estate has one account.
- An account whose login is a Console key, a gateway or a cloud provider. Only made-up ones were tried, and each was refused.
- What a real usage limit prints. The message quotes whatever Claude Code says.
- How large one batch can be. Nothing caps one, and it has `timeout_seconds` to finish.
- The judge's verdicts are a model's, and it wobbles: on one invented estate it passed a line in one run and flagged it in the next. Every quote is checked, but a verdict is a judgement. Your examples are what steer it.
