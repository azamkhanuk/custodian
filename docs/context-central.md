# Beside context-central

Custodian and [context-central](https://github.com/azamkhanuk/context-central) work without each other. Neither needs the other installed, and neither runs the other's commands. Both install from one marketplace, `azamkhanuk`. Three things are done so they sit well together.

## Setup offers an estate as a group

`custodian detect` reads an `estate.json` that marks a context-central estate. An estate whose folder holds several repos is offered as a group, named after the estate. It reads the file itself with `jq`: context-central need not be installed, and where it is absent nothing changes.

## A hub is found and judged

An estate's hub is context like any other.

- A hub kept as `CLAUDE.md` or `CLAUDE.local.md` is found where Claude Code loads it.
- A hub kept as a rule file under `.claude/rules/` is found too, and a repo that keeps only such a rule file is found by the `…/.claude` glob.
- The notes of a map are not context a session loads at launch, so they are not judged unless a file imports one.

## The block context-central writes

context-central writes the same block into every hub, between two marks. It is the same in every estate, so a judge is inclined to call it too generic for a group or a repo. Custodian knows the block by its marks, tells the judge which lines it is, and never reports it as too generic. A leak inside it is still reported.

Those two marks, and the `estate.json` that setup reads, are all Custodian knows of the other plugin.

## Their sessions do not meet

The audit's sessions run sealed: no plugin loads in them, context-central included, and Custodian's reminder stays silent there. A session you open yourself loads both plugins side by side, and each keeps to its own commands and its own data.
