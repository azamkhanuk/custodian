# custodian

A Claude Code plugin that audits where Claude Code context sits and shows the result in a local dashboard. `lib/run.sh` is the read-only audit, `bin/custodian` is the one command in front of everything, and `skills/` and `hooks/` are what the plugin adds to Claude Code: four user-invoked skills and one session-start hook that speaks only to the person.

Before changing anything, read `CONTEXT.md`. When a change makes it stale, update it in the same pass and add a dated line to its change log. Use invented names such as acme and globex in every fixture, example and document, because the release check refuses real ones.

- Runner suite: `test/run.smoke.sh`, or `test/run.smoke.sh <group>` for one group
- Command suite: `test/custodian.smoke.sh`, or `test/custodian.smoke.sh <group>`
- Live taste check, spends usage: `test/run.smoke.sh --live`
- Loading check, costs nothing: `test/run.smoke.sh --loaded`
- Before any release: `scripts/release-check.sh`
