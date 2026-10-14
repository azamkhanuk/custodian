#!/bin/bash
# Smoke suite for run.sh: run.smoke.sh [group] drives it with a fake claude, --live has the real one judge, --loaded asks the real one what it loads.
set -u
here=$(cd "$(dirname "$0")" && pwd)
lib=$(cd "$here/../lib" && pwd)
RUN="$lib/run.sh"
LIVE=0; LOADED=0; FILTER=""
for a in "$@"; do case "$a" in --live) LIVE=1;; --loaded) LOADED=1;; *) FILTER=$a;; esac; done
. "$here/helpers.sh"

run_custodian() {
  fake_settings
  ( cd "$WORLD/cwd" && env -i HOME="$FAKE_HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$TMPD" FAKE_LOG="$LOG" \
      ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$RUN" --config "$CFG" "$@" >"$STDOUT" 2>"$ERR" )
  rc=$?
  [ -z "$(ls -A "$WORLD/cwd")" ] || dirtied="$dirtied $WORLD"
}


happy_path() {
  new_world
  mk "$FAKE_HOME/store/CLAUDE.md" '# Global

Use conventional commits.
'
  examples_ok
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian
  t "happy path exits 0" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  t "happy path writes the report" '[ -f "$OUT" ]'
  t "report validates against the schema" 'check-jsonschema --schemafile "$lib/schema.json" "$OUT" >/dev/null 2>&1'
  jqt "summary counts one passing item" "$OUT" '.summary == {total: 1, pass: 1, warn: 0, fail: 0}'
  jqt "item carries the runner-owned facts" "$OUT" '.items[0] | .id == "global/CLAUDE.md" and .kind == "claude_md" and .tier == "global" and .scope == null and .linked_from == [] and (.path | endswith("/home/store/CLAUDE.md"))'
  jqt "report records version, model and schema version" "$OUT" '.claude_code_version == "9.9.9-fake" and .model == "claude-sonnet-5" and .schema_version == 1'
  jqt "the report records what the run used and which version of the plugin wrote it" "$OUT" \
    '.usage == {seconds: 2, input_tokens: 150, output_tokens: 40, api_equivalent_usd: 0.25} and .plugin_version == $v' --arg v "$(jq -r .version "$here/../.claude-plugin/plugin.json")"
  t "what was used is said on stderr, in words that do not call it a charge" 'grep -q "used 150 tokens in and 40 out, in 2s; the API would have charged about \$0.25" "$ERR"' "stderr=$(cat "$ERR")"
  t "stdout is one summary line" '[ "$(wc -l < "$STDOUT" | tr -d " ")" = 1 ] && grep -q "1 items" "$STDOUT" && grep -q "~/Developer/.custodian/audit.json" "$STDOUT"' "stdout=$(cat "$STDOUT")"
}

judged() { jq -c '[.batches[].judge[]]' "$STDOUT" > "$WORLD/judged.json"; }

estate_of_repos() {
  local i=1
  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" "global rules"
  while [ "$i" -le "$1" ]; do mk "$FAKE_HOME/Developer/acme/repo-$i/CLAUDE.md" "repo $i rules"; i=$((i+1)); done
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" }, { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
}

discovery() {
  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" "global rules"
  mk "$FAKE_HOME/store/skills/commit-style/SKILL.md" "commit skill"
  mk "$FAKE_HOME/store/agents/reviewer.md" "review agent"
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "acme rules"
  mk "$FAKE_HOME/Developer/acme/CLAUDE.local.md" "acme local"
  mk "$FAKE_HOME/Developer/acme/.claude/CLAUDE.md" "acme dot rules"
  mk "$FAKE_HOME/Developer/acme/.claude/skills/deploy/SKILL.md" "deploy skill"
  mk "$FAKE_HOME/Developer/acme/.claude/agents/release.md" "release agent"
  mk "$FAKE_HOME/store/skills/commit-style/notes.md" "not an item"
  mk "$FAKE_HOME/store/skills/synced/bucket/SKILL.md" "too deep to match"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" },
             { "tier": "client", "path": "~/Developer/acme", "scope": "acme" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; judged
  t "dry run exits 0" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  jqt "all three kinds are found in both layouts" "$WORLD/judged.json" \
    '(map(.sits_at) | sort) == ["~/Developer/acme/.claude/CLAUDE.md","~/Developer/acme/.claude/agents/release.md","~/Developer/acme/.claude/skills/deploy/SKILL.md","~/Developer/acme/CLAUDE.local.md","~/Developer/acme/CLAUDE.md","~/store/CLAUDE.md","~/store/agents/reviewer.md","~/store/skills/commit-style/SKILL.md"]'
  jqt "kind follows the matching pattern" "$WORLD/judged.json" \
    '(map(select(.kind == "claude_md")) | length) == 4 and (map(select(.kind == "skill")) | length) == 2 and (map(select(.kind == "agent")) | length) == 2'
  jqt "line counts are recorded" "$WORLD/judged.json" 'all(.[]; .line_count == 1)'
  t "a dry run writes no report and calls nothing" '[ ! -e "$OUT" ] && [ -z "$(ls -A "$LOG")" ]'

  new_world; examples_ok
  mk "$FAKE_HOME/store/skills/commit-style/SKILL.md" "commit skill"
  lnk "$FAKE_HOME/store/skills" "$FAKE_HOME/.claude/skills"
  lnk "$FAKE_HOME/store/skills/commit-style" "$FAKE_HOME/Developer/acme/.claude/skills/commit-style"
  mk "$FAKE_HOME/Developer/acme/MAP.md" "the acme map"
  lnk "$FAKE_HOME/Developer/acme/MAP.md" "$FAKE_HOME/Developer/acme/CLAUDE.md"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" },
             { "tier": "global", "path": "~/.claude" },
             { "tier": "client", "path": "~/Developer/acme", "scope": "acme" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; judged
  jqt "a folder link and a skill link to one canonical file yield one item" "$WORLD/judged.json" \
    '[.[] | select(.sits_at == "~/store/skills/commit-style/SKILL.md")] | length == 1 and .[0].linked_from == ["~/.claude/skills", "~/Developer/acme/.claude/skills/commit-style"]'
  jqt "a CLAUDE.md linking to another file name stays claude_md" "$WORLD/judged.json" \
    '[.[] | select(.sits_at == "~/Developer/acme/MAP.md")] | length == 1 and .[0].kind == "claude_md" and .[0].linked_from == ["~/Developer/acme/CLAUDE.md"]'
  jqt "an unlinked path reports the canonical absolute path" "$WORLD/judged.json" \
    '[.[] | select(.sits_at == "~/store/skills/commit-style/SKILL.md")][0].path | startswith("/") and endswith("/home/store/skills/commit-style/SKILL.md")'

  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" "global rules"
  lnk "/nonexistent/skill" "$FAKE_HOME/store/skills/ghost"
  lnk "/nonexistent/agent.md" "$FAKE_HOME/store/agents/gone.md"
  mk "$FAKE_HOME/store/agents/locked.md" "secret"; chmod 000 "$FAKE_HOME/store/agents/locked.md"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" }, { "tier": "global", "path": "~/nowhere" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; judged
  t "broken links, locked files and a missing root do not stop the run" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  jqt "only the readable item is listed" "$WORLD/judged.json" 'map(.sits_at) == ["~/store/CLAUDE.md"]'
  t "each skip is named on stderr" 'grep -q "skills/ghost" "$ERR" && grep -q "agents/gone.md" "$ERR" && grep -q "agents/locked.md" "$ERR" && grep -q "root not found.*~/nowhere" "$ERR"' "stderr=$(cat "$ERR")"

  new_world; examples_ok
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "acme rules"
  mk "$FAKE_HOME/Developer/acme/web/CLAUDE.md" "web rules"
  mk "$FAKE_HOME/Developer/acme/vendored/CLAUDE.md" "third party"
  mk "$FAKE_HOME/elsewhere/app.md" "linked out"
  lnk "$FAKE_HOME/elsewhere/app.md" "$FAKE_HOME/Developer/acme/app/CLAUDE.md"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "client", "path": "~/Developer/acme", "scope": "acme" },
             { "tier": "project", "glob": "~/Developer/*/CLAUDE.md" },
             { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" } ],
  "exclude": ["~/Developer/acme/vendored", "~/elsewhere"],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; judged
  jqt "an exclude prefix drops items by found path and by canonical path" "$WORLD/judged.json" \
    '(map(.sits_at) | sort) == ["~/Developer/acme/CLAUDE.md", "~/Developer/acme/web/CLAUDE.md"]'
  jqt "a configured client root is never also a project root" "$WORLD/judged.json" \
    '[.[] | select(.sits_at == "~/Developer/acme/CLAUDE.md")] | length == 1 and .[0].tier == "client"'
  t "excluded paths are named on stderr" 'grep -q "excluded.*vendored" "$ERR"' "stderr=$(cat "$ERR")"

  new_world; examples_ok
  mk "$FAKE_HOME/Developer/Personal/side/CLAUDE.md" "side rules"
  mk "$FAKE_HOME/Developer/Personal/zed/CLAUDE.md" "someone else's rules"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" } ],
  "exclude": ["~/Developer/Personal/zed"],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run
  jqt "an excluded checkout is not announced as one of my projects" "$STDOUT" 'all(.batches[]; .unscoped_projects == ["side"])'

  new_world; examples_ok
  mk "$FAKE_HOME/Developer/globex/app/CLAUDE.md" "app rules"
  mk "$FAKE_HOME/Developer/globex/site/.claude/rules/hub.md" "the map of the site"
  mk "$FAKE_HOME/Developer/globex/site/.claude/skills/ship/SKILL.md" "ship skill"
  mk "$FAKE_HOME/Developer/globex/docs/.claude/CLAUDE.md" "docs rules"
  mk "$FAKE_HOME/Developer/globex/tool/.claude/settings.local.json" "{}"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" }, { "tier": "project", "glob": "~/Developer/*/*/.claude/CLAUDE.md" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; judged
  jqt "globs that name a CLAUDE.md pass over a repo that keeps only rule files and skills" "$WORLD/judged.json" \
    '(map(.sits_at) | sort) == ["~/Developer/globex/app/CLAUDE.md", "~/Developer/globex/docs/.claude/CLAUDE.md"]'
  cfg_set '.tiers[1].glob = "~/Developer/*/*/.claude"'; run_custodian --dry-run; judged
  jqt "a glob on the .claude folder finds every repo that keeps anything there" "$WORLD/judged.json" \
    '(map(.sits_at) | sort) == ["~/Developer/globex/app/CLAUDE.md", "~/Developer/globex/docs/.claude/CLAUDE.md", "~/Developer/globex/site/.claude/rules/hub.md", "~/Developer/globex/site/.claude/skills/ship/SKILL.md"]'
  jqt "such a repo is the folder above its .claude folder, by its own name" "$WORLD/judged.json" \
    '[.[] | select(.kind == "rule") | [.id, .home.project, .home.root]] == [["project/site/.claude/rules/hub", "site", "~/Developer/globex/site"]]'
  jqt "a repo with a .claude folder and nothing to judge in it adds nothing" "$STDOUT" 'all(.batches[]; .unscoped_projects == ["app", "docs", "site", "tool"]) and ([.batches[].judge[] | select(.sits_at | contains("/tool/"))] == [])'

  new_world; examples_ok
  mk "$FAKE_HOME/work [old]/acme/web/CLAUDE.md" "web rules"; mk "$FAKE_HOME/work [old]/acme/back\\slash/CLAUDE.md" "odd rules"; mk "$FAKE_HOME/work o/acme/web/CLAUDE.md" "another folder's rules"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "project", "glob": "~/work \\[old\\]/*/*/CLAUDE.md" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; judged
  jqt "a glob may escape a glob character in a folder's own name, and then matches that folder alone" "$WORLD/judged.json" 'map(.sits_at) == ["~/work [old]/acme/web/CLAUDE.md"]'
  t "a repo with a backslash in its name is passed over and named, since no table here can carry it" 'grep -q "root skipped, a backslash in its path: ~/work \[old\]/acme/back.slash" "$ERR"' "stderr=$(cat "$ERR")"

  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" "global rules"; mk "$FAKE_HOME/Developer/we\\ird/CLAUDE.md" "odd rules"
  mk "$FAKE_HOME/store/agents/od\\d.md" "odd agent"; mk "$FAKE_HOME/store/skills/od\\d/SKILL.md" "odd skill"; mk "$FAKE_HOME/store/rules/od\\d.md" "odd rule"
  mk "$FAKE_HOME/store/agents/ta"$'\t'"b.md" "tabbed agent"; mk "$FAKE_HOME/store/skills/ta"$'\t'"b/SKILL.md" "tabbed skill"
  mk "$FAKE_HOME/el\\se/real.md" "an agent kept in a folder with a backslash"; lnk "$FAKE_HOME/el\\se/real.md" "$FAKE_HOME/store/agents/linked.md"
  mk "$FAKE_HOME/store/agents/plain.md" "a plain agent"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" }, { "tier": "project", "path": "~/Developer/we\\ird" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian; jq -c '[.items[].id]' "$OUT" > "$WORLD/ids.json" 2>/dev/null
  t "an audit over names it cannot carry runs to its end" '[ "$rc" = 0 ] && [ "$(ls "$LOG" | wc -l | tr -d " ")" = 1 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "it judges what it can carry and nothing else" "$WORLD/ids.json" '. == ["global/CLAUDE.md", "global/agents/plain"]'
  t "a root with a backslash in its path is passed over and named" 'grep -q "^custodian: root skipped, a backslash in its path: ~/Developer/we.ird$" "$ERR"' "stderr=$(cat "$ERR")"
  t "an agent, a skill and a rule file with a backslash or a tab in the name are each named" \
    '[ "$(grep -c "skipped, a tab, a line break or a backslash in its name: ~/store/\(agents\|skills\|rules\)/" "$ERR")" = 5 ]' "stderr=$(cat "$ERR")"
  t "a link to a file whose real path holds a backslash is named too" 'grep -q "skipped, a tab, a line break or a backslash in its real path: ~/store/agents/linked.md" "$ERR"' "stderr=$(cat "$ERR")"

  new_world; examples_ok
  mk "$FAKE_HOME/Developer/we[ird] *client?/CLAUDE.md" "awkward rules"
  mk "$FAKE_HOME/Developer/we[ird] *client?/.claude/skills/deploy/SKILL.md" "awkward skill"
  mk "$FAKE_HOME/Developer/we[ird] *client?/.claude/agents/release.md" "awkward agent"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "client", "path": "~/Developer/we[ird] *client?", "scope": "weird" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; judged
  jqt "a root whose name holds spaces and glob characters is searched in full" "$WORLD/judged.json" \
    '(map(.sits_at) | sort) == ["~/Developer/we[ird] *client?/.claude/agents/release.md", "~/Developer/we[ird] *client?/.claude/skills/deploy/SKILL.md", "~/Developer/we[ird] *client?/CLAUDE.md"]'

  new_world; examples_ok
  mkdir -p "$FAKE_HOME/store/skills"
  config <<'EOF'
{ "canonical_store": "~/store", "tiers": [ { "tier": "global", "path": "~/store" } ], "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run
  t "nothing to audit is exit 2" '[ "$rc" = 2 ] && grep -qi "nothing" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  local one twelve
  estate_of_repos 1; log_descriptors realpath; run_custodian --dry-run; one=$(most_descriptors realpath)
  estate_of_repos 12; log_descriptors realpath; run_custodian --dry-run; twelve=$(most_descriptors realpath)
  t "discovery holds no more descriptors open for twelve repos than for one" '[ "$rc" = 0 ] && [ "$twelve" = "$one" ]' "rc=$rc one repo: $one, twelve repos: $twelve"

  new_world; examples_ok
  mk "$FAKE_HOME/Developer/acme-web/.claude/CLAUDE.md" "web rules"
  mk "$FAKE_HOME/Developer/acme-web/CLAUDE.local.md" "web local"
  mk "$FAKE_HOME/Developer/globex-app/CLAUDE.md" "app rules"
  mk "$FAKE_HOME/Developer/globex-app/.claude/CLAUDE.md" "app dot rules"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "project", "glob": "~/Developer/*/CLAUDE.md" },
             { "tier": "project", "glob": "~/Developer/*/.claude/CLAUDE.md" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run
  jqt "a repo that keeps its CLAUDE.md in .claude is found under its own name, whichever glob matched it" "$STDOUT" \
    '[.batches[].judge[].id] | sort == ["project/acme-web/.claude/CLAUDE.md", "project/acme-web/CLAUDE.local.md", "project/globex-app/.claude/CLAUDE.md", "project/globex-app/CLAUDE.md"]'
  jqt "such a repo is announced as a project by its own name" "$STDOUT" 'all(.batches[]; .unscoped_projects == ["acme-web", "globex-app"])'
}

item() { jq -c --arg at "$1" '[.batches[] | .batch as $b | .judge[] | select(.sits_at == $at) | . + {batch: $b}][0]' "$STDOUT" > "$WORLD/item.json"; }

rules_estate() {
  new_world; examples_ok
  account_folder "$FAKE_HOME/.claude-acme"
  mk "$FAKE_HOME/store/CLAUDE.md" "global rules"
  mk "$FAKE_HOME/store/rules/testing.md" "Run the smoke script after editing a hook."
  mk "$FAKE_HOME/store/.claude/rules/misplaced.md" "a config folder keeps its rules in rules"
  mk "$FAKE_HOME/.claude-acme/rules/style.md" "acme account style"
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "acme rules"
  mk "$FAKE_HOME/Developer/acme/.claude/rules/api.md" "acme api rules"
  mk "$FAKE_HOME/Developer/acme/rules/handbook.md" "the acme handbook, which no session loads"
  mk "$FAKE_HOME/Developer/acme/web/CLAUDE.md" "web rules"
  mk "$FAKE_HOME/Developer/acme/web/.claude/rules/routes.md" "web route rules"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" },
             { "tier": "client", "path": "~/Developer/acme", "scope": "acme" },
             { "tier": "client", "path": "~/.claude-acme", "scope": "acme" },
             { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" } ],
  "slots": { "acme": "~/.claude-acme" },
  "output": "~/Developer/.custodian/audit.json" }
EOF
}
rules_found() { jq -c '[.batches[].judge[] | select(.kind == "rule")]' "$STDOUT" > "$WORLD/rules.json"; }

rule_files() {
  rules_estate; run_custodian --dry-run; rules_found
  t "an estate with rule files lists cleanly" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  jqt "a rule file is found in rules under a config folder and in .claude/rules under any other root" "$WORLD/rules.json" \
    '(map(.sits_at) | sort) == ["~/.claude-acme/rules/style.md", "~/Developer/acme/.claude/rules/api.md", "~/Developer/acme/web/.claude/rules/routes.md", "~/store/rules/testing.md"]'
  jqt "a rules folder in the wrong place for its root holds no context file of any kind" "$STDOUT" \
    '[.batches[].judge[].sits_at] | all(. != "~/store/.claude/rules/misplaced.md" and . != "~/Developer/acme/rules/handbook.md")'
  jqt "a rule file's id is its path under its home without the ending" "$WORLD/rules.json" \
    '(map(.id) | sort) == ["acme/.claude/rules/api", "acme/rules/style", "acme/web/.claude/rules/routes", "global/rules/testing"]'
  jqt "a rule file takes the tier and scope of the root it is loaded from" "$WORLD/rules.json" \
    '(map({(.id): [.tier, .scope]}) | add) == {"global/rules/testing": ["global", null], "acme/rules/style": ["client", "acme"], "acme/.claude/rules/api": ["client", "acme"], "acme/web/.claude/rules/routes": ["project", "acme"]}'

  rules_estate; run_custodian
  t "an audit of an estate with rule files succeeds" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "each rule file is reported as a rule" "$OUT" \
    '[.items[] | select(.kind == "rule") | .id] | sort == ["acme/.claude/rules/api", "acme/rules/style", "acme/web/.claude/rules/routes", "global/rules/testing"]'
  t "a report holding rules validates" 'check-jsonschema --schemafile "$lib/schema.json" "$OUT" >/dev/null 2>&1'
  jq '(.items[] | select(.id == "global/rules/testing") | .evidence) = {line: 1, text: "Run the smoke script after editing a hook."}' "$OUT" > "$WORLD/evident.json"
  t "a report whose rule carries an evidence does not validate" '! check-jsonschema --schemafile "$lib/schema.json" "$WORLD/evident.json" >/dev/null 2>&1'

  rules_estate; EXTRA_ENV=("FAKE_FILTER=.items |= map(if .id == \"global/rules/testing\" then .findings = [$(finding 1 "Run the smoke script after editing a hook." warn project)] else . end)"); run_custodian
  t "a rule's flagged lines are accepted" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "a rule's verdict is the worst of its findings, as a CLAUDE.md's is" "$OUT" \
    '.items[] | select(.id == "global/rules/testing") | .verdict == "warn" and .suggested_tier == "project" and .evidence == null and ([.findings[] | [.line, .text]] == [[1, "Run the smoke script after editing a hook."]])'

  rules_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "global/rules/testing" then .verdict = "fail" | .suggested_tier = "client" | .evidence = {line: 1, text: "Run the smoke script after editing a hook."} else . end)'); run_custodian
  t "an evidence for a rule is exit 4" '[ "$rc" = 4 ] && grep -q "evidence must be null.*global/rules/testing" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  rules_estate; EXTRA_ENV=("FAKE_FILTER=.items |= map(if .id == \"global/rules/testing\" then .findings = [$(finding 1 "Deploy through the acme change board." fail client)] else . end)"); run_custodian
  t "a quote that is not in the rule file is exit 4" '[ "$rc" = 4 ] && grep -q "quote not found in the file: global/rules/testing" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  EXTRA_ENV=()

  new_world; examples_ok
  mk "$FAKE_HOME/store/rules/testing.md" "top level rule"
  mk "$FAKE_HOME/store/rules/frontend/react/hooks.md" "nested rule"
  mk "$FAKE_HOME/store/rules/a/b/c/d/e/f/g/h/eight.md" "eight folders down"
  mk "$FAKE_HOME/store/rules/a/b/c/d/e/f/g/h/i/nine.md" "nine folders down"
  mk "$FAKE_HOME/store/rules/.hidden.md" "a dot name"
  mk "$FAKE_HOME/store/rules/.private/secret.md" "under a dot folder"
  mk "$FAKE_HOME/store/rules/notes.txt" "not markdown"
  mk "$FAKE_HOME/shared/team/security.md" "shared security rule"
  lnk "$FAKE_HOME/shared/team" "$FAKE_HOME/store/rules/team"
  mk "$FAKE_HOME/shared/one.md" "one shared rule"
  lnk "$FAKE_HOME/shared/one.md" "$FAKE_HOME/store/rules/one.md"
  lnk "/nonexistent/folder" "$FAKE_HOME/store/rules/gone"
  lnk "/nonexistent/rule.md" "$FAKE_HOME/store/rules/lost.md"
  mk "$FAKE_HOME/alt/CLAUDE.md" "a second global root"
  lnk "/nonexistent/rules" "$FAKE_HOME/alt/rules"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" }, { "tier": "global", "path": "~/alt" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; rules_found
  jqt "rule files are found in the folders beneath a rules folder, through links to files and to folders" "$WORLD/rules.json" \
    '(map(.sits_at) | sort) == ["~/shared/one.md", "~/shared/team/security.md", "~/store/rules/a/b/c/d/e/f/g/h/eight.md", "~/store/rules/frontend/react/hooks.md", "~/store/rules/testing.md"]'
  jqt "a rule reached through a link says where it is linked from" "$WORLD/rules.json" \
    '[.[] | select(.sits_at == "~/shared/team/security.md") | .linked_from] == [["~/store/rules/team"]]'
  t "a folder more than eight below a rules folder is skipped and named" \
    'grep -q "skipped, more than 8 folders below a rules folder: ~/store/rules/a/b/c/d/e/f/g/h/i$" "$ERR"' "stderr=$(cat "$ERR")"
  t "a dangling link in a rules folder is named, whether or not it looks like a rule file" \
    'grep -q "dangling link: ~/store/rules/gone$" "$ERR" && grep -q "dangling link: ~/store/rules/lost.md$" "$ERR"' "stderr=$(cat "$ERR")"
  t "a rules folder that is itself a dangling link is named" 'grep -q "dangling link: ~/alt/rules$" "$ERR"' "stderr=$(cat "$ERR")"

  new_world; examples_ok
  mk "$FAKE_HOME/store/rules/testing.md" "top level rule"
  lnk "$FAKE_HOME/store/rules" "$FAKE_HOME/store/rules/loop"
  config <<'EOF'
{ "canonical_store": "~/store", "tiers": [ { "tier": "global", "path": "~/store" } ], "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; rules_found
  t "a circular link in a rules folder ends at the cap" '[ "$rc" = 0 ] && grep -q "more than 8 folders below a rules folder" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  jqt "a rule beside a circular link is still one item" "$WORLD/rules.json" 'map(.sits_at) == ["~/store/rules/testing.md"]'

  rules_estate
  lnk "$FAKE_HOME/Developer/acme/.claude/rules/api.md" "$FAKE_HOME/store/rules/acme-api.md"
  run_custodian --dry-run; item "~/Developer/acme/.claude/rules/api.md"
  jqt "a group's rule linked into the global rules folder is global by reach, read in its home batch" "$WORLD/item.json" \
    '.tier == "global" and .scope == null and .batch == "acme" and .id == "acme/.claude/rules/api" and .linked_from == ["~/store/rules/acme-api.md"]'
  jqt "a group with its own account reads no reference file, a rule file no more than a CLAUDE.md" "$STDOUT" \
    '[.batches[] | {(.batch): [.reference[].id]}] | add == {"global": [], "acme": []}'
  cfg_set 'del(.slots)'; run_custodian --dry-run
  jqt "a batch under the personal account reads the global rule files as reference, beside the global CLAUDE.md" "$STDOUT" \
    '[.batches[] | {(.batch): [.reference[].id]}] | add == {"global": [], "acme": ["global/CLAUDE.md", "global/rules/testing"]}'

  rules_estate
  lnk "$FAKE_HOME/.claude-acme" "$FAKE_HOME/accounts/acme"
  cfg_set '.slots.acme = "~/accounts/acme/"'
  run_custodian --dry-run; rules_found
  jqt "a config folder is recognised by where it really is, however the slot is written" "$WORLD/rules.json" \
    '[.[] | select(.sits_at == "~/.claude-acme/rules/style.md") | .id] == ["acme/rules/style"]'

  new_world; examples_ok
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "acme rules"
  mk "$FAKE_HOME/Developer/acme/.claude/agents/reviewer.md" "review agent"
  lnk "$FAKE_HOME/Developer/acme/CLAUDE.md" "$FAKE_HOME/store/rules/acme.md"
  lnk "$FAKE_HOME/Developer/acme/.claude/agents/reviewer.md" "$FAKE_HOME/store/rules/reviewer.md"
  config <<'CFG'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" }, { "tier": "client", "path": "~/Developer/acme", "scope": "acme" } ],
  "output": "~/Developer/.custodian/audit.json" }
CFG
  run_custodian --dry-run
  jqt "a file linked into a rules folder keeps the kind and the id it has where it lives" "$STDOUT" \
    '[.batches[].judge[] | {(.id): [.kind, .tier, .linked_from]}] | add
     == {"acme/CLAUDE.md": ["claude_md", "global", ["~/store/rules/acme.md"]], "acme/.claude/agents/reviewer": ["agent", "global", ["~/store/rules/reviewer.md"]]}'

  local tab=$'\t' nl=$'\n'
  new_world; examples_ok
  mk "$FAKE_HOME/store/rules/testing.md" "top level rule"
  mk "$FAKE_HOME/store/rules/locked/in.md" "inside a folder nobody may read"; chmod 000 "$FAKE_HOME/store/rules/locked"
  mk "$FAKE_HOME/store/rules/tab${tab}name.md" "a tab in its name"
  mk "$FAKE_HOME/store/rules/two${nl}lines.md" "a line break in its name"
  config <<'CFG'
{ "canonical_store": "~/store", "tiers": [ { "tier": "global", "path": "~/store" } ], "output": "~/Developer/.custodian/audit.json" }
CFG
  run_custodian --dry-run; rules_found
  t "a rules folder holding names the runner cannot carry still lists" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "the rule files that can be read and carried are still found" "$WORLD/rules.json" 'map(.sits_at) == ["~/store/rules/testing.md"]'
  t "a folder that cannot be read is named" 'grep -q "^custodian: skipped, not a readable folder: ~/store/rules/locked$" "$ERR"' "stderr=$(cat "$ERR")"
  t "a name holding a tab or a line break is named on one line, and nothing false is said" \
    '[ "$(grep -c "skipped, a tab, a line break or a backslash in its name: ~/store/rules/" "$ERR")" = 2 ] && ! grep -q "dangling" "$ERR"' "stderr=$(cat "$ERR")"
}

std_estate() {
  new_world; examples_ok
  account_folder "$FAKE_HOME/.claude-acme"
  mk "$FAKE_HOME/store/CLAUDE.md" "# Global
Use conventional commits.
"
  mk "$FAKE_HOME/store/skills/commit-style/SKILL.md" "commit skill"
  mk "$FAKE_HOME/store/agents/reviewer.md" "review agent"
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "# Acme
Deploys go through the acme change board.
"
  mk "$FAKE_HOME/Developer/acme/claude/skills/pr-review/SKILL.md" "acme review skill"
  mk "$FAKE_HOME/Developer/acme/claude/skills/pr-auditor/SKILL.md" "acme auditor skill"
  mk "$FAKE_HOME/Developer/acme/claude/skills/solo/SKILL.md" "one repo only"
  mk "$FAKE_HOME/Developer/acme/claude/skills/shared/SKILL.md" "shared with globex"
  lnk "$FAKE_HOME/Developer/acme/claude/skills/pr-review" "$FAKE_HOME/.claude/skills/pr-review"
  mk "$FAKE_HOME/Developer/acme/web/CLAUDE.md" "web rules"
  mk "$FAKE_HOME/Developer/acme/api/CLAUDE.md" "api rules"
  lnk "$FAKE_HOME/Developer/acme/claude/skills/pr-auditor" "$FAKE_HOME/Developer/acme/web/.claude/skills/pr-auditor"
  lnk "$FAKE_HOME/Developer/acme/claude/skills/pr-auditor" "$FAKE_HOME/Developer/acme/api/.claude/skills/pr-auditor"
  lnk "$FAKE_HOME/Developer/acme/claude/skills/solo" "$FAKE_HOME/Developer/acme/web/.claude/skills/solo"
  lnk "$FAKE_HOME/Developer/acme/claude/skills/shared" "$FAKE_HOME/Developer/acme/.claude/skills/shared"
  mk "$FAKE_HOME/Developer/globex/CLAUDE.md" "globex rules"
  lnk "$FAKE_HOME/Developer/acme/claude/skills/shared" "$FAKE_HOME/Developer/globex/.claude/skills/shared"
  mk "$FAKE_HOME/Developer/Personal/side/CLAUDE.md" "side project rules"
  mk "$FAKE_HOME/notes/rules.md" "external agent"
  lnk "$FAKE_HOME/notes/rules.md" "$FAKE_HOME/Developer/globex/.claude/agents/ext.md"
  mk "$FAKE_HOME/notes/both.md" "external agent in global"
  lnk "$FAKE_HOME/notes/both.md" "$FAKE_HOME/.claude/agents/both.md"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" },
             { "tier": "global", "path": "~/.claude" },
             { "tier": "client", "path": "~/Developer/acme", "scope": "acme" },
             { "tier": "client", "path": "~/Developer/globex", "scope": "globex" },
             { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" } ],
  "slots": { "acme": "~/.claude-acme" },
  "output": "~/Developer/.custodian/audit.json" }
EOF
}

commands_estate() {
  new_world; examples_ok
  account_folder "$FAKE_HOME/.claude-acme"
  mk "$FAKE_HOME/store/CLAUDE.md" "global rules"
  mk "$FAKE_HOME/store/commands/deploy.md" "---
description: Ship the current branch
---
Deploy through the acme change board."
  mk "$FAKE_HOME/store/skills/deploy/SKILL.md" "a skill of the same name"
  mk "$FAKE_HOME/store/.claude/commands/misplaced.md" "a config folder keeps its commands in commands"
  mk "$FAKE_HOME/.claude-acme/commands/acme/release.md" "the acme release, from its own account"
  mk "$FAKE_HOME/Developer/.claude/commands/up.md" "a command above a root is not loaded"
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "acme rules"
  mk "$FAKE_HOME/Developer/acme/.claude/commands/frontend/component.md" "an acme command in a folder of its own"
  mk "$FAKE_HOME/Developer/acme/commands/handbook.md" "acme's own commands folder, which no session loads"
  mk "$FAKE_HOME/Developer/acme/web/CLAUDE.md" "web rules"
  mk "$FAKE_HOME/Developer/acme/web/.claude/commands/ship.md" "a web command"
  mk "$FAKE_HOME/Developer/acme/web/.claude/commands/notes.txt" "not a command"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" },
             { "tier": "client", "path": "~/Developer/acme", "scope": "acme" },
             { "tier": "client", "path": "~/.claude-acme", "scope": "acme" },
             { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" } ],
  "slots": { "acme": "~/.claude-acme" },
  "output": "~/Developer/.custodian/audit.json" }
EOF
}
commands_found() { jq -c '[.batches[].judge[] | select(.kind == "command")]' "$STDOUT" > "$WORLD/commands.json"; }

command_files() {
  commands_estate; run_custodian --dry-run; commands_found
  t "an estate with command files lists cleanly" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  jqt "a command is found in commands under a config folder and in .claude/commands under any other root, at any depth" "$WORLD/commands.json" \
    '(map(.sits_at) | sort) == ["~/.claude-acme/commands/acme/release.md", "~/Developer/acme/.claude/commands/frontend/component.md", "~/Developer/acme/web/.claude/commands/ship.md", "~/store/commands/deploy.md"]'
  jqt "a commands folder in the wrong place, one above a root and a file that is not Markdown hold no context file" "$STDOUT" \
    '[.batches[].judge[].sits_at] | all(test("misplaced|handbook|/up\\.md|notes\\.txt") | not)'
  jqt "a command's id is its path under its home without the ending" "$WORLD/commands.json" \
    '(map(.id) | sort) == ["acme/.claude/commands/frontend/component", "acme/commands/acme/release", "acme/web/.claude/commands/ship", "global/commands/deploy"]'
  jqt "a command takes the tier and scope of the root it is loaded from" "$WORLD/commands.json" \
    '(map({(.id): [.tier, .scope]}) | add) == {"global/commands/deploy": ["global", null], "acme/commands/acme/release": ["client", "acme"], "acme/.claude/commands/frontend/component": ["client", "acme"], "acme/web/.claude/commands/ship": ["project", "acme"]}'
  jqt "a command that shares its name with a skill is still an item, and so is the skill" "$STDOUT" \
    '[.batches[].judge[] | select(.id == "global/commands/deploy" or .id == "global/skills/deploy") | .kind] | sort == ["command", "skill"]'
  jqt "a command is never a reference file" "$STDOUT" 'all(.batches[].reference[]; .id | test("/commands/") | not)'

  commands_estate; run_custodian
  t "an audit of an estate with command files succeeds" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "each command file is reported as a command" "$OUT" '[.items[] | select(.kind == "command") | .id] | length == 4'
  t "a report holding commands validates" 'check-jsonschema --schemafile "$lib/schema.json" "$OUT" >/dev/null 2>&1'
  jq '(.items[] | select(.id == "global/commands/deploy") | .findings) = [{line: 4, text: "Deploy through the acme change board.", verdict: "fail", suggested_tier: "client", rationale: "x"}]' "$OUT" > "$WORLD/found.json"
  t "a report whose command carries findings does not validate" '! check-jsonschema --schemafile "$lib/schema.json" "$WORLD/found.json" >/dev/null 2>&1'

  commands_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "global/commands/deploy" then .verdict = "fail" | .suggested_tier = "client" | .evidence = {line: 4, text: "Deploy through the acme change board."} else . end)'); run_custodian
  t "a verdict with its evidence is accepted for a command" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "the command's verdict and evidence reach the report" "$OUT" \
    '.items[] | select(.id == "global/commands/deploy") | .verdict == "fail" and .evidence == {line: 4, text: "Deploy through the acme change board."} and .findings == []'
  commands_estate; EXTRA_ENV=("FAKE_FILTER=.items |= map(if .id == \"global/commands/deploy\" then .findings = [$(finding 4 "Deploy through the acme change board." fail client)] else . end)"); run_custodian
  t "findings for a command are exit 4" '[ "$rc" = 4 ] && grep -q "findings must be empty for a command: global/commands/deploy" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  commands_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "global/commands/deploy" then .verdict = "fail" | .suggested_tier = "client" | .evidence = {line: 4, text: "Never said in the file."} else . end)'); run_custodian
  t "a quote that is not in the command file is exit 4" '[ "$rc" = 4 ] && grep -q "quote not found in the file: global/commands/deploy" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  EXTRA_ENV=()

  new_world; examples_ok
  mk "$FAKE_HOME/store/commands/a/b/c/d/e/f/g/h/eight.md" "eight folders down"
  mk "$FAKE_HOME/store/commands/a/b/c/d/e/f/g/h/i/nine.md" "nine folders down"
  mk "$FAKE_HOME/Developer/acme/.claude/commands/review.md" "an acme command"
  lnk "$FAKE_HOME/Developer/acme/.claude/commands/review.md" "$FAKE_HOME/store/commands/review.md"
  lnk "$FAKE_HOME/nowhere.md" "$FAKE_HOME/store/commands/gone.md"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" }, { "tier": "client", "path": "~/Developer/acme", "scope": "acme" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; commands_found
  jqt "a group's command linked into the global commands folder is global by reach" "$WORLD/commands.json" \
    '[.[] | select(.id == "acme/.claude/commands/review") | [.tier, .linked_from]] == [["global", ["~/store/commands/review.md"]]]'
  t "a commands folder past the cap and a dangling link in one are named, and a rules folder is not blamed" \
    'grep -q "skipped, more than 8 folders below a commands folder: ~/store/commands/a/b/c/d/e/f/g/h/i" "$ERR" && grep -q "skipped, dangling link: ~/store/commands/gone.md" "$ERR" && ! grep -q "rules folder" "$ERR"' "stderr=$(cat "$ERR")"
  jqt "the walk goes eight folders deep and no further" "$WORLD/commands.json" '[.[] | select(.sits_at | test("/(eight|nine)\\.md")) | .sits_at] == ["~/store/commands/a/b/c/d/e/f/g/h/eight.md"]'
  new_world; examples_ok; mk "$FAKE_HOME/store/CLAUDE.md" "global"; lnk "$FAKE_HOME/nowhere" "$FAKE_HOME/store/commands"
  config <<'EOF'
{ "canonical_store": "~/store", "tiers": [ { "tier": "global", "path": "~/store" } ], "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run
  t "a commands folder that is a dangling link is named" 'grep -q "skipped, dangling link: ~/store/commands" "$ERR"' "stderr=$(cat "$ERR")"
}

imports_estate() {
  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" '# Global

- Prefer early returns.
See @notes/style.md for style.
The team: @~/Developer/acme/notes/team.md
A span `@notes/quoted.md` stays text.
<!-- @notes/commented.md -->
Before <!-- @notes/inline.md --> after
> @notes/quote.md
**@notes/bold.md**
Trailing stop @notes/trail.md.
Escaped @notes/with\ space.md and a fragment @notes/frag.md#part
Another type @notes/data.xyz and nothing @notes/missing.md and a folder @notes
Capitals @notes/SHOUT.MD and no ending @notes/LICENSE
Mail someone@example.com about (@notes/paren.md)
```
@notes/fenced.md
```

    @notes/indented.md
'
  local n
  for n in quoted commented inline quote bold trail "with space" frag paren fenced indented; do mk "$FAKE_HOME/store/notes/$n.md" "a note called $n"; done
  mk "$FAKE_HOME/store/notes/data.xyz" "a type Claude Code does not import"
  mk "$FAKE_HOME/store/notes/SHOUT.MD" "capitals"; mk "$FAKE_HOME/store/notes/LICENSE" "no ending"
  mk "$FAKE_HOME/store/notes/style.md" "Style.
More in @deeper.md"
  mk "$FAKE_HOME/store/notes/deeper.md" "second, then @three.md"
  mk "$FAKE_HOME/store/notes/three.md" "third, then @four.md"
  mk "$FAKE_HOME/store/notes/four.md" "fourth, then @five.md"
  mk "$FAKE_HOME/store/notes/five.md" "fifth, which no session loads"
  mk "$FAKE_HOME/store/rules/testing.md" "Run the tests.
See @../notes/from-rule.md"
  for n in front quotefence listfence spantwo htmlblock preblock tabcode listcode quotecode refdef tilde crlfcode; do mk "$FAKE_HOME/store/notes/skip-$n.md" "a note no session loads: $n"; done
  mk "$FAKE_HOME/store/notes/skip-dot." "a name that ends in a dot"
  mk "$FAKE_HOME/store/notes/crlf.md" "imported from a file with Windows line endings"
  mk "$FAKE_HOME/store/notes/spanned.md" "after a comment mark inside a code span"
  printf -- '---\ndescription: see @../notes/skip-front.md here\n---\n> ```\n> @../notes/skip-quotefence.md\n> ```\n- ```\n  @../notes/skip-listfence.md\n  ```\ntext `code\n@../notes/skip-spantwo.md more` end\n\n<div>\n@../notes/skip-htmlblock.md\n</div>\n\n<pre>\n\n@../notes/skip-preblock.md\n</pre>\n\n  \t@../notes/skip-tabcode.md\n\n    - @../notes/skip-listcode.md\n\n>     @../notes/skip-quotecode.md\n\n[l]: @../notes/skip-refdef.md\n~~~\n@../notes/skip-tilde.md\n~~~\nA dot @../notes/skip-dot.\nA span `<!--` then @../notes/spanned.md here\n' > "$FAKE_HOME/store/rules/shapes.md"
  printf 'intro\r\n@../notes/crlf.md\r\n\r\n    @../notes/skip-crlfcode.md\r\n' > "$FAKE_HOME/store/rules/windows.md"
  mk "$FAKE_HOME/store/notes/from-rule.md" "imported by a rule file"
  mk "$FAKE_HOME/shared/rule.md" "a rule kept elsewhere, with @beside.md"
  mk "$FAKE_HOME/shared/beside.md" "beside the rule's real file"
  mk "$FAKE_HOME/store/rules/beside.md" "beside the link, and a rule of its own"
  lnk "$FAKE_HOME/shared/rule.md" "$FAKE_HOME/store/rules/linked.md"
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "acme rules"
  mk "$FAKE_HOME/Developer/acme/notes/team.md" "# The team

- Deploys wait for the acme change board."
  mk "$FAKE_HOME/Developer/acme/.claude/rules/api.md" "acme api rules"
  mk "$FAKE_HOME/Developer/acme/web/CLAUDE.md" "web rules
@README.md and @package.json
@../.claude/rules/api.md"
  mk "$FAKE_HOME/Developer/acme/web/README.md" "# web"
  mk "$FAKE_HOME/Developer/acme/web/package.json" '{ "name": "web" }'
  mk "$FAKE_HOME/Developer/globex/CLAUDE.md" "globex rules
@~/Developer/acme/notes/team.md"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" },
             { "tier": "client", "path": "~/Developer/acme", "scope": "acme" },
             { "tier": "client", "path": "~/Developer/globex", "scope": "globex" },
             { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
}
forms_into() {
  local folder=$1 i=0 n text ref file beside
  mkdir -p "$folder/rules" "$folder/notes"
  while IFS= read -r -d '' text && IFS= read -r -d '' ref && IFS= read -r -d '' file && IFS= read -r -d '' beside; do
    n=$(printf '%03d' "$i")
    if [ -n "$beside" ]; then ref=${beside//%/$n}; file=$folder/rules/$ref; else file=$folder/notes/n$n/${file:-$ref}; ref=../notes/n$n/$ref; fi
    mkdir -p "${file%/*}"; printf 'target %s\n' "$n" > "$file"
    REF="@$ref" awk 'BEGIN { ref = ENVIRON["REF"]; gsub(/[\\&]/, "\\\\&", ref) } { gsub(/@T/, ref); print }' <<< "${text%$'\n'}" > "$folder/rules/c$n.md"
    i=$((i+1))
  done < <(jq -j '.[] | .text, "\u0000", (.ref // "t.md"), "\u0000", (.file // ""), "\u0000", (.beside // ""), "\u0000"' "$here/import-forms.json")
}
FORM_OF='(capture("/notes/n(?<n>[0-9]+)/") // capture("/rules/[^/]*-(?<n>[0-9]+)\\.txt$")).n | tonumber'
followed_forms() { jq -c "[.batches[].judge[] | select(.kind == \"import\") | .sits_at | $FORM_OF] | sort" "$1"; }

imports_found() { jq -c '[.batches[] | .batch as $b | .judge[] | select(.kind == "import") | . + {batch: $b}]' "$STDOUT" > "$WORLD/imports.json"; }

imports() {
  imports_estate; run_custodian --dry-run; imports_found
  t "an estate with imports lists cleanly" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  jqt "each form of import that Claude Code follows is found" "$WORLD/imports.json" \
    '[.[] | select(.sits_at | startswith("~/store/notes/")) | .sits_at | ltrimstr("~/store/notes/")] | sort
     == ["LICENSE", "SHOUT.MD", "bold.md", "crlf.md", "deeper.md", "four.md", "frag.md", "from-rule.md", "quote.md", "spanned.md", "style.md", "three.md", "with space.md"]'
  jqt "a span, a comment, a fence, an indented block, a bracket and a path with a stop after it import nothing" "$STDOUT" \
    '[.batches[].judge[].sits_at] | all(test("/(quoted|commented|inline|fenced|indented|paren|trail)\\.md$") | not)'
  jqt "frontmatter, a fence in a quote or a list, a span over two lines, an HTML block, indented code, a link definition and a name ending in a dot import nothing" "$STDOUT" \
    '[.batches[].judge[].sits_at] | all(test("/skip-") | not)'
  jqt "the chain is followed four files deep and not five" "$STDOUT" '[.batches[].judge[].sits_at] | (index("~/store/notes/four.md") != null) and (index("~/store/notes/five.md") == null)'
  jqt "an imported file keeps its ending in its id, under the label of its home" "$WORLD/imports.json" \
    '[.[] | select(.sits_at | test("style\\.md|team\\.md|README\\.md|package\\.json|shared/beside")) | .id] | sort
     == ["acme/notes/team.md", "acme/web/README.md", "acme/web/package.json", "external/~/shared/beside.md", "global/notes/style.md"]'
  jqt "a group's notes imported by the global file are global, read in the group's own batch, and say what imports them" "$WORLD/imports.json" \
    '[.[] | select(.id == "acme/notes/team.md") | [.tier, .scope, .batch, .home.tier, .imported_by]] == [["global", null, "acme", "client", ["~/Developer/globex/CLAUDE.md", "~/store/CLAUDE.md"]]]'
  jqt "a repo's own imports stay that repo's" "$WORLD/imports.json" \
    '[.[] | select(.id == "acme/web/README.md" or .id == "acme/web/package.json") | [.tier, .scope, .imported_by]] | unique == [["project", "acme", ["~/Developer/acme/web/CLAUDE.md"]]]'
  jqt "a rule file that is also imported keeps its kind and its id, and says what imports it" "$STDOUT" \
    '[.batches[].judge[] | select(.sits_at == "~/Developer/acme/.claude/rules/api.md") | [.kind, .id, .tier, .imported_by]] == [["rule", "acme/.claude/rules/api", "client", ["~/Developer/acme/web/CLAUDE.md"]]]'
  jqt "a rule file imports as a CLAUDE.md does" "$WORLD/imports.json" '[.[] | select(.id == "global/notes/from-rule.md") | [.tier, .imported_by]] == [["global", ["~/store/rules/testing.md"]]]'
  jqt "an import is read beside the linked file's target, and the file beside the link is left a rule" "$STDOUT" \
    '([.batches[].judge[] | select(.sits_at == "~/shared/beside.md") | [.kind, .tier, .imported_by]] == [["import", "global", ["~/shared/rule.md"]]])
     and ([.batches[].judge[] | select(.sits_at == "~/store/rules/beside.md") | [.kind, .imported_by]] == [["rule", []]])'
  jqt "what nothing imports says so" "$STDOUT" '[.batches[].judge[] | select(.id == "global/CLAUDE.md" or .id == "acme/CLAUDE.md") | .imported_by] == [[], []]'
  jqt "an imported file whose reach and home are both global is a reference file" "$STDOUT" \
    '[.batches[] | select(.batch == "acme") | .reference[].id] | (index("global/notes/style.md") != null) and (index("acme/notes/team.md") == null)'
  t "a file type Claude Code does not import is named once, and nothing is said of a path that names nothing or a folder" \
    '[ "$(grep -c "not followed, a file type Claude Code does not import: ~/store/notes/data.xyz" "$ERR")" = 1 ] && ! grep -q "missing.md" "$ERR" && ! grep -q "store/notes$" "$ERR"' "stderr=$(cat "$ERR")"
  jqt "no file is an item twice" "$STDOUT" '[.batches[].judge[].path] | length == (unique | length)'

  imports_estate
  printf 'bytes\000here\n' > "$FAKE_HOME/store/notes/blob.txt"; mk "$FAKE_HOME/store/notes/locked.md" "locked"; chmod 000 "$FAKE_HOME/store/notes/locked.md"
  mk "$FAKE_HOME/Developer/acme/notes/secret.md" "left out"
  mk "$FAKE_HOME/store/notes/a.md" "to @b.md"; mk "$FAKE_HOME/store/notes/b.md" "and back to @a.md"
  printf 'Also @notes/blob.txt and @notes/locked.md and @~/Developer/acme/notes/secret.md and @notes/a.md\n' >> "$FAKE_HOME/store/CLAUDE.md"
  cfg_set '.exclude = ["~/Developer/acme/notes/secret.md"]'
  run_custodian --dry-run; imports_found
  t "a file that is not text, one that cannot be read and one that is excluded are each named once" \
    '[ "$rc" = 0 ] && [ "$(grep -c "skipped, an imported file that is not text: ~/store/notes/blob.txt" "$ERR")" = 1 ] && [ "$(grep -c "skipped, an imported file that cannot be read: ~/store/notes/locked.md" "$ERR")" = 1 ] && [ "$(grep -c "excluded: ~/Developer/acme/notes/secret.md" "$ERR")" = 1 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "none of the three is an item" "$STDOUT" '[.batches[].judge[].sits_at] | all(test("blob\\.txt|locked\\.md|secret\\.md") | not)'
  jqt "two files that import each other are one item each" "$WORLD/imports.json" \
    '[.[] | select(.sits_at | test("/notes/[ab]\\.md$")) | [.id, .imported_by]] | sort == [["global/notes/a.md", ["~/store/CLAUDE.md", "~/store/notes/b.md"]], ["global/notes/b.md", ["~/store/notes/a.md"]]]'
  chmod 600 "$FAKE_HOME/store/notes/locked.md"

  new_world; examples_ok; mk "$FAKE_HOME/store/CLAUDE.md" "global"; forms_into "$FAKE_HOME/store"
  config <<'EOF'
{ "canonical_store": "~/store", "tiers": [ { "tier": "global", "path": "~/store" } ], "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run
  t "of the forms an import can take, the parser follows exactly the ones recorded for it" \
    '[ "$rc" = 0 ] && [ "$(followed_forms "$STDOUT")" = "$(jq -c "[to_entries[] | select(.value.followed) | .key]" "$here/import-forms.json")" ]' \
    "rc=$rc differs at: $(jq -c -n --argjson got "$(followed_forms "$STDOUT" 2>/dev/null || echo "[]")" --slurpfile forms "$here/import-forms.json" '[$forms[0] | to_entries[] | select(.value.followed != (.key | IN($got[]))) | [.key, .value.text]]' | cut -c1-500)"
  jqt "and none of those is a form Claude Code was seen not to load" "$here/import-forms.json" 'length > 1000 and all(.[]; (.followed | not) or .loads)'

  imports_estate; mk "$FAKE_HOME/odd"$'\t'"folder/note.md" "kept in a folder with a tab in its name"; lnk "$FAKE_HOME/odd"$'\t'"folder/note.md" "$FAKE_HOME/store/notes/tabbed.md"
  printf 'Tabbed @notes/tabbed.md\n' >> "$FAKE_HOME/store/CLAUDE.md"; run_custodian --dry-run
  t "an imported file whose real path holds a tab is skipped and named" \
    '[ "$rc" = 0 ] && grep -q "skipped, a tab, a line break or a backslash in its real path: ~/store/notes/tabbed.md" "$ERR" && ! jq -e "any(.batches[].judge[]; .sits_at | test(\"note\\\\.md$\"))" "$STDOUT" >/dev/null' "rc=$rc stderr=$(cat "$ERR")"
  imports_estate; printf '#!/bin/bash\ncase "$1" in *"function emit"*) exit 2;; esac\nexec /usr/bin/awk "$@"\n' > "$BIN/awk"; chmod +x "$BIN/awk"; run_custodian --dry-run
  t "a file that cannot be read for its imports stops the run with exit 1" '[ "$rc" = 1 ] && grep -q "could not read a file for its imports" "$ERR" && [ ! -s "$STDOUT" ]' "rc=$rc stderr=$(cat "$ERR")"

  new_world; examples_ok
  mk "$FAKE_HOME/Mono/big/CLAUDE.md" "big
@notes.md"
  mk "$FAKE_HOME/Mono/big/notes.md" "the repo's own notes"; mk "$FAKE_HOME/Mono/big/packages/inner/CLAUDE.md" "inner"
  config <<EOF
{ "tiers": [ { "tier": "project", "path": "~/Mono/big" }, { "tier": "project", "path": "~/Mono/big/packages/inner" } ],
  "output": "$OUT", "canonical_store": "~/store" }
EOF
  run_custodian --dry-run
  jqt "a repo nested inside a repo does not widen what that repo imports" "$STDOUT" \
    '[.batches[].judge[] | select(.sits_at == "~/Mono/big/notes.md") | [.kind, .tier, .id]] == [["import", "project", "project/big/notes.md"]]'

  new_world; examples_ok; mk "$FAKE_HOME/store/CLAUDE.md" "global
@long.json"
  awk 'BEGIN { printf "{"; for (i = 0; i < 12000; i++) printf "\"@scope/pkg%d\": \"^1.0.0\", ", i; printf "\"end\": 1}\n" }' > "$FAKE_HOME/store/long.json"
  config <<'EOF'
{ "canonical_store": "~/store", "tiers": [ { "tier": "global", "path": "~/store" } ], "output": "~/Developer/.custodian/audit.json" }
EOF
  local began=$SECONDS; run_custodian --dry-run
  t "a long line with thousands of at signs is read in seconds" '[ "$rc" = 0 ] && [ $((SECONDS - began)) -lt 15 ]' "rc=$rc seconds=$((SECONDS - began))"

  imports_estate; EXTRA_ENV=("FAKE_FILTER=.items |= map(if .id == \"acme/notes/team.md\" then .findings = [$(finding 3 "- Deploys wait for the acme change board." fail client)] else . end)"); run_custodian
  t "an imported file's flagged lines are accepted" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "it is reported as an imported file, with its findings, no evidence and what imports it" "$OUT" \
    '.items[] | select(.id == "acme/notes/team.md") | .kind == "import" and .verdict == "fail" and .tier == "global" and .evidence == null and ([.findings[] | .line] == [3]) and .imported_by == ["~/Developer/globex/CLAUDE.md", "~/store/CLAUDE.md"]'
  jqt "every item in the report says what imports it, if anything" "$OUT" 'all(.items[]; (.imported_by | type) == "array")'
  t "a report holding imported files validates" 'check-jsonschema --schemafile "$lib/schema.json" "$OUT" >/dev/null 2>&1'
  jq '(.items[] | select(.id == "acme/notes/team.md") | .evidence) = {line: 3, text: "- Deploys wait for the acme change board."}' "$OUT" > "$WORLD/evident.json"
  t "a report whose imported file carries an evidence does not validate" '! check-jsonschema --schemafile "$lib/schema.json" "$WORLD/evident.json" >/dev/null 2>&1'
  local sent
  for sent in 1 2 3 4; do sent_manifest $sent | jq -e 'any(.judge[]; .id == "acme/notes/team.md")' >/dev/null 2>&1 && break; done
  jqt "the judge is told what imports a file, and reads it under the group that owns it" <(sent_manifest $sent) \
    '.batch == "acme" and ([.judge[] | select(.id == "acme/notes/team.md") | .imported_by] == [["~/Developer/globex/CLAUDE.md", "~/store/CLAUDE.md"]])'
  t "a file that is not Markdown is staged like any other" 'ls "$LOG/$sent/staging" | grep -q "^0" && ! ls "$LOG/$sent/staging" | grep -qv "\\.md$"' "staging=$(ls "$LOG/$sent/staging" | tr "\n" " ")"

  local base="$WORLD/baseline.json"
  jqt "the baseline marks the paths an import named, and gives each the fingerprint of what was judged" "$base" \
    '[.found[] | select(.path | test("/store/notes/style\\.md$|/acme/notes/team\\.md$")) | [.import, (.sha256 | type), (.inode | type)]] | unique == [[true, "string", "string"]]'
  jqt "a path that named nothing is recorded too, with no identity and no fingerprint" "$base" \
    '[.found[] | select(.path | test("/store/notes/missing\\.md$")) | [.import, .sha256, .inode, .size]] == [[true, null, null, null]]'
  jqt "a path the patterns found carries no such mark, and no path is recorded twice" "$base" \
    '([.found[] | select(.path | test("/store/CLAUDE\\.md$|/store/rules/testing\\.md$")) | has("import")] == [false, false]) and ([.found[].path] | length == (unique | length))'
  jqt "a file of another type and one inside a fence are not recorded" "$base" '[.found[].path] | all(test("data\\.xyz$|fenced\\.md$") | not)'

  imports_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "acme/notes/team.md" then .verdict = "fail" | .suggested_tier = "client" | .evidence = {line: 3, text: "- Deploys wait for the acme change board."} else . end)'); run_custodian
  t "an evidence for an imported file is exit 4" '[ "$rc" = 4 ] && grep -q "evidence must be null for an imported file: acme/notes/team.md" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  imports_estate; EXTRA_ENV=("FAKE_FILTER=.items |= map(if .id == \"acme/notes/team.md\" then .findings = [$(finding 3 "Never said in the file." fail client)] else . end)"); run_custodian
  t "a quote that is not in the imported file is exit 4" '[ "$rc" = 4 ] && grep -q "quote not found in the file: acme/notes/team.md" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  EXTRA_ENV=()
}

above_estate() {
  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" "global"
  mk "$FAKE_HOME/Developer/CLAUDE.md" "above both groups"
  mk "$FAKE_HOME/Developer/CLAUDE.local.md" "mine, above both groups"
  mk "$FAKE_HOME/Developer/.claude/CLAUDE.md" "tucked away above both groups"
  mk "$FAKE_HOME/Developer/.claude/rules/shared/style.md" "a rule above both groups"
  mk "$FAKE_HOME/Developer/.claude/skills/up/SKILL.md" "a skill above a root is not loaded"
  mk "$FAKE_HOME/Developer/.claude/agents/up.md" "nor is an agent"
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "acme"
  mk "$FAKE_HOME/Developer/acme/web/CLAUDE.md" "web"
  mk "$FAKE_HOME/Developer/globex/CLAUDE.md" "globex"
  mk "$FAKE_HOME/Work/CLAUDE.md" "above one group"
  mk "$FAKE_HOME/Work/initech/CLAUDE.md" "initech"
  mk "$FAKE_HOME/Own/CLAUDE.md" "above one repo"
  mk "$FAKE_HOME/Own/tool/CLAUDE.md" "tool"
  mk "$FAKE_HOME/Mono/big/CLAUDE.md" "big"
  mk "$FAKE_HOME/Mono/big/packages/inner/CLAUDE.md" "inner"
  config <<EOF
{ "tiers": [ { "tier": "global", "path": "~/store" },
             { "tier": "client", "path": "~/Developer/acme", "scope": "acme" },
             { "tier": "client", "path": "~/Developer/globex", "scope": "globex" },
             { "tier": "client", "path": "~/Work/initech", "scope": "initech" },
             { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" },
             { "tier": "project", "path": "~/Own/tool" },
             { "tier": "project", "path": "~/Mono/big" },
             { "tier": "project", "path": "~/Mono/big/packages/inner" } ],
  "output": "$OUT", "canonical_store": "~/store" }
EOF
}

above_roots() {
  above_estate; run_custodian --dry-run; judged
  t "an estate with files above its roots lists cleanly" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  jqt "the three file names and the rule files are found in a folder above the roots" "$WORLD/judged.json" \
    '[.[] | select(.sits_at | startswith("~/Developer/") and (test("/(acme|globex)/") | not)) | [.sits_at, .kind]] | sort == [["~/Developer/.claude/CLAUDE.md", "claude_md"], ["~/Developer/.claude/rules/shared/style.md", "rule"], ["~/Developer/CLAUDE.local.md", "claude_md"], ["~/Developer/CLAUDE.md", "claude_md"]]'
  jqt "a skill or an agent above a root is not looked for" "$WORLD/judged.json" 'all(.[]; .sits_at | test("/up(/|\\.md)") | not)'
  item "~/Developer/CLAUDE.md"
  jqt "a file above two groups is global, has no home and is read in the global batch" "$WORLD/item.json" \
    '.tier == "global" and .scope == null and .batch == "global" and .home == {tier: null, scope: null, project: null, root: null} and .id == "external/~/Developer/CLAUDE.md"'
  jqt "it names the roots it sits above" "$WORLD/item.json" '.above == ["~/Developer/acme", "~/Developer/acme/web", "~/Developer/globex"] and .linked_from == []'
  item "~/Developer/.claude/rules/shared/style.md"
  jqt "a rule file above the roots drops its ending as any rule does" "$WORLD/item.json" '.id == "external/~/Developer/.claude/rules/shared/style" and .tier == "global"'
  item "~/Work/CLAUDE.md"
  jqt "a file above one group's roots is that group's, and read in its batch" "$WORLD/item.json" \
    '.tier == "client" and .scope == "initech" and .batch == "initech" and .above == ["~/Work/initech"]'
  item "~/Own/CLAUDE.md"
  jqt "a file above one standalone repo is that repo's" "$WORLD/item.json" '.tier == "project" and .scope == null and .batch == "unscoped" and .above == ["~/Own/tool"]'
  item "~/Mono/big/CLAUDE.md"
  jqt "a repo nested inside a repo does not widen that repo's own file" "$WORLD/item.json" '.tier == "project" and .above == [] and .id == "project/big/CLAUDE.md"'
  item "~/Developer/acme/CLAUDE.md"
  jqt "a group's own file is as it was: its group's, with a home and nothing to sit above" "$WORLD/item.json" \
    '.tier == "client" and .scope == "acme" and .home.tier == "client" and .above == [] and .id == "acme/CLAUDE.md"'
  jqt "no file is listed twice" "$WORLD/judged.json" '([.[].path] | length) == ([.[].path] | unique | length)'

  above_estate; lnk "$FAKE_HOME/nowhere.md" "$FAKE_HOME/Developer/.claude/rules/gone.md"; cfg_set '.exclude = ["~/Work/CLAUDE.md"]'
  mk "$FAKE_HOME/Developer/.claude/rules/a/b/c/d/e/f/g/h/i/deep.md" "too deep"
  run_custodian --dry-run; judged
  t "a dangling link, a folder past the cap and an excluded file above the roots are each named once" \
    '[ "$rc" = 0 ] && [ "$(grep -c "skipped, dangling link: ~/Developer/.claude/rules/gone.md" "$ERR")" = 1 ] && [ "$(grep -c "more than 8 folders below a rules folder" "$ERR")" = 1 ] && [ "$(grep -c "excluded: ~/Work/CLAUDE.md" "$ERR")" = 1 ]' "stderr=$(cat "$ERR")"
  jqt "an excluded file above the roots is not judged" "$WORLD/judged.json" 'all(.[]; .sits_at != "~/Work/CLAUDE.md")'

  above_estate; rm "$FAKE_HOME/Developer/CLAUDE.md"; lnk "$FAKE_HOME/Developer/acme/CLAUDE.md" "$FAKE_HOME/Developer/CLAUDE.md"
  run_custodian --dry-run; item "~/Developer/acme/CLAUDE.md"
  jqt "a group's file linked from above both groups is global, and says where it is linked from" "$WORLD/item.json" \
    '.tier == "global" and .linked_from == ["~/Developer/CLAUDE.md"] and .home.tier == "client" and .batch == "acme"'

  new_world; examples_ok
  mk "$FAKE_HOME/.claude/CLAUDE.md" "global"; mk "$FAKE_HOME/.claude/rules/tidy.md" "a global rule"; mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "acme"
  config <<EOF
{ "tiers": [ { "tier": "global", "path": "~/.claude" }, { "tier": "client", "path": "~/Developer/acme", "scope": "acme" } ],
  "output": "$OUT", "canonical_store": "~/store" }
EOF
  run_custodian --dry-run; judged
  jqt "the global root's own files, found again above a root, stay one item each and global" "$WORLD/judged.json" \
    '[.[] | select(.home.tier == "global") | [.id, .tier, (.found_at | length), .above]] | sort == [["global/CLAUDE.md", "global", 1, []], ["global/rules/tidy", "global", 1, []]]'

  above_estate; run_custodian
  t "an audit of that estate is clean" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  jqt "the report carries what an item sits above" "$OUT" '[.items[] | select(.id == "external/~/Work/CLAUDE.md") | .above] == [["~/Work/initech"]] and all(.items[]; (.above | type) == "array")'
  t "a report with such items validates" 'check-jsonschema --schemafile "$lib/schema.json" "$OUT" >/dev/null 2>&1'
  jqt "the judge is told what an item sits above" <(sent_manifest 1) 'any(.judge[]; .above == ["~/Developer/acme", "~/Developer/acme/web", "~/Developer/globex"])'
  jqt "the baseline records the files above the roots as found paths" "$WORLD/baseline.json" \
    '[.found[] | select(.path | endswith("/Developer/CLAUDE.md")) | (.sha256 | type)] == ["string"]'
}

reach_and_home() {
  std_estate; run_custodian --dry-run
  t "the standard estate lists cleanly" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  item "~/store/skills/commit-style/SKILL.md"
  jqt "a file in a global root is global" "$WORLD/item.json" '.tier == "global" and .scope == null and .batch == "global"'
  item "~/Developer/acme/claude/skills/pr-review/SKILL.md"
  jqt "a client-folder skill linked into the global folder is global by reach, read in its home batch" "$WORLD/item.json" \
    '.tier == "global" and .scope == null and .batch == "acme" and .linked_from == ["~/.claude/skills/pr-review"]'
  item "~/Developer/acme/claude/skills/pr-auditor/SKILL.md"
  jqt "a skill linked into two projects of one scope is client-tier" "$WORLD/item.json" '.tier == "client" and .scope == "acme" and .batch == "acme"'
  item "~/Developer/acme/claude/skills/solo/SKILL.md"
  jqt "a skill linked into one project is project-tier" "$WORLD/item.json" '.tier == "project" and .scope == "acme"'
  item "~/Developer/acme/claude/skills/shared/SKILL.md"
  jqt "a file shared by two scopes is global" "$WORLD/item.json" '.tier == "global" and .scope == null and .batch == "acme"'
  item "~/Developer/acme/web/CLAUDE.md"
  jqt "a project takes the scope of the client root around it" "$WORLD/item.json" '.tier == "project" and .scope == "acme" and .batch == "acme"'
  item "~/Developer/Personal/side/CLAUDE.md"
  jqt "a project outside every client root is unscoped" "$WORLD/item.json" '.tier == "project" and .scope == null and .batch == "unscoped"'
  item "~/notes/rules.md"
  jqt "an external file linked from one scope joins that scope's batch" "$WORLD/item.json" '.tier == "client" and .scope == "globex" and .batch == "globex" and .id == "external/~/notes/rules"'
  item "~/notes/both.md"
  jqt "an external file linked from a global root joins the global batch" "$WORLD/item.json" '.tier == "global" and .batch == "global" and .id == "external/~/notes/both"'
  item "~/store/skills/commit-style/SKILL.md"
  jqt "a global file's home is its global root" "$WORLD/item.json" '.home == {tier: "global", scope: null, project: null, root: "~/store"}'
  item "~/Developer/acme/claude/skills/pr-review/SKILL.md"
  jqt "a group-level file keeps its group as home even when its reach is global" "$WORLD/item.json" '.home == {tier: "client", scope: "acme", project: null, root: "~/Developer/acme"} and .tier == "global"'
  item "~/Developer/acme/web/CLAUDE.md"
  jqt "a repo file's home names the group and the repo" "$WORLD/item.json" '.home == {tier: "project", scope: "acme", project: "web", root: "~/Developer/acme/web"}'
  item "~/Developer/Personal/side/CLAUDE.md"
  jqt "a standalone repo's home has no group" "$WORLD/item.json" '.home == {tier: "project", scope: null, project: "side", root: "~/Developer/Personal/side"}'
  item "~/notes/rules.md"
  jqt "an external file has an empty home" "$WORLD/item.json" '.home == {tier: null, scope: null, project: null, root: null}'
  jqt "batches run global, scopes alphabetically, unscoped" "$STDOUT" '[.batches[].batch] == ["global", "acme", "globex", "unscoped"]'
  jqt "only a slotted scope gets a slot, expanded but otherwise untouched" "$STDOUT" \
    '[.batches[] | {(.batch): .slot}] | add | (.acme | endswith("/home/.claude-acme")) and .global == null and .globex == null and .unscoped == null'
  jqt "a batch says whether the account it is read under is its group's own" "$STDOUT" '[.batches[] | {(.batch): .own_account}] | add == {"global": false, "acme": true, "globex": false, "unscoped": false}'
  jqt "a batch under the personal account knows every scope and my own projects; one under its own account knows itself alone" "$STDOUT" \
    '[.batches[] | {(.batch): [.known_scopes, .unscoped_projects]}] | add == {"global": [["acme", "globex"], ["side"]], "acme": [["acme"], []], "globex": [["acme", "globex"], ["side"]], "unscoped": [["acme", "globex"], ["side"]]}'
  jqt "a batch under the personal account reads the global CLAUDE.md as reference; global and one under its own account read none" "$STDOUT" \
    '[.batches[] | {(.batch): [.reference[].id]}] | add == {"global": [], "acme": [], "globex": ["global/CLAUDE.md"], "unscoped": ["global/CLAUDE.md"]}'
  cfg_set 'del(.slots)'; run_custodian --dry-run
  jqt "without a slot the group is read as every other batch is" "$STDOUT" \
    '[.batches[] | select(.batch == "acme") | [.own_account, .known_scopes, .unscoped_projects, [.reference[].id]]] == [[false, ["acme", "globex"], ["side"], ["global/CLAUDE.md"]]]'
}

external_across_scopes() {
  new_world; examples_ok
  mk "$FAKE_HOME/notes/two.md" "shared external agent"
  lnk "$FAKE_HOME/notes/two.md" "$FAKE_HOME/Developer/acme/.claude/agents/two.md"
  lnk "$FAKE_HOME/notes/two.md" "$FAKE_HOME/Developer/globex/.claude/agents/two.md"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "client", "path": "~/Developer/acme", "scope": "acme" },
             { "tier": "client", "path": "~/Developer/globex", "scope": "globex" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run; item "~/notes/two.md"
  jqt "an external file linked from two scopes is global and joins the global batch" "$WORLD/item.json" \
    '.tier == "global" and .scope == null and .batch == "global" and .id == "external/~/notes/two" and .linked_from == ["~/Developer/acme/.claude/agents/two.md", "~/Developer/globex/.claude/agents/two.md"]'
}

ids_and_order() {
  std_estate; run_custodian --dry-run
  jqt "ids drop the skill and agent suffixes; items order by tier, scope, then id" "$STDOUT" \
    '[.batches[] | {(.batch): [.judge[].id]}] | add == {
       "global": ["external/~/notes/both", "global/CLAUDE.md", "global/agents/reviewer", "global/skills/commit-style"],
       "acme": ["acme/claude/skills/pr-review", "acme/claude/skills/shared", "acme/CLAUDE.md", "acme/claude/skills/pr-auditor", "acme/api/CLAUDE.md", "acme/claude/skills/solo", "acme/web/CLAUDE.md"],
       "globex": ["external/~/notes/rules", "globex/CLAUDE.md"],
       "unscoped": ["project/side/CLAUDE.md"] }'
  cp "$STDOUT" "$WORLD/first.json"; run_custodian --dry-run
  t "two dry runs over one tree are byte-identical" 'cmp -s "$WORLD/first.json" "$STDOUT"'

  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" "store rules"
  mk "$FAKE_HOME/.claude/CLAUDE.md" "slot rules"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" }, { "tier": "global", "path": "~/.claude" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian --dry-run
  jqt "colliding ids gain their home" "$STDOUT" '[.batches[].judge[].id] == ["global/CLAUDE.md@~/.claude", "global/CLAUDE.md@~/store"]'
}

pair() { grep -Fx -A1 -- "$2" "$LOG/$1/argv" | tail -1 | grep -Fxq -- "$3"; }
flag() { grep -Fxq -- "$2" "$LOG/$1/argv"; }
sent_manifest() { sed -n '/^<manifest>$/,/^<\/manifest>$/p' "$LOG/$1/stdin" | sed '1d;$d'; }

clone_runner() {
  mkdir -p "$WORLD/custodian"
  cp "$lib"/*.sh "$lib/schema.json" "$lib/prompt.md" "$WORLD/custodian/"
  RUN="$WORLD/custodian/run.sh"
}

invocation() {
  std_estate
  cfg_set '.model = "claude-sonnet-5" | .slots.acme = "~/.claude-acme/"'
  EXTRA_ENV=(CLAUDE_CONFIG_DIR=/parent/slot CLAUDE_CODE_PLUGIN_DIRS=/parent/mods)
  run_custodian
  t "the standard estate audits cleanly" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  t "each batch is announced on stderr as it starts, with its size and account" \
    '[ "$(grep -o "batch [a-z]*: judging [0-9]* items ([^)]*)" "$ERR" | tr "\n" "|")" = "batch global: judging 4 items (personal account)|batch acme: judging 7 items (account ~/.claude-acme/)|batch globex: judging 2 items (personal account)|batch unscoped: judging 1 items (personal account)|" ] && [ "$(grep -c "batch [a-z]*: done in [0-9]*s" "$ERR")" = 4 ]' "stderr=$(cat "$ERR")"
  t "progress never reaches stdout" '[ "$(wc -l < "$STDOUT" | tr -d " ")" = 1 ]'
  t "there is one invocation per batch" '[ "$(ls "$LOG" | wc -l | tr -d " ")" = 4 ]' "log=$(ls "$LOG")"
  t "batches are invoked global, acme, globex, unscoped" \
    '[ "$(for n in 1 2 3 4; do sent_manifest $n | jq -r .batch; done | tr "\n" " ")" = "global acme globex unscoped " ]'
  t "the verified flag set is passed" \
    'flag 1 -p && flag 1 --safe-mode && flag 1 --restricted && pair 1 --tools "Read,Glob,Grep" && pair 1 --allowedTools "Read,Glob,Grep" && flag 1 --strict-mcp-config && pair 1 --permission-mode dontAsk && pair 1 --permission-prompts none && pair 1 --output-format stream-json && flag 1 --verbose && flag 1 --no-session-persistence && flag 1 --json-schema && flag 1 --add-dir' \
    "argv=$(tr "\n" " " < "$LOG/1/argv" | cut -c1-400)"
  t "the configured model is passed" 'pair 1 --model claude-sonnet-5'
  t "nothing bypasses permissions" '! grep -qi "skip-permissions\|bypassPermissions" "$LOG/1/argv"'
  t "the response schema argument is self-contained JSON" \
    'grep -Fx -A1 -- --json-schema "$LOG/1/argv" | tail -1 | jq -e ".properties.items and .[\"\$defs\"].judgement" >/dev/null'
  t "the prompt arrives on stdin and not in the arguments" \
    'grep -q "^# The Custodian" "$LOG/1/stdin" && ! grep -q "Custodian" "$LOG/1/argv"'
  t "the working directory is empty and outside every root" \
    '[ ! -s "$LOG/1/cwd_listing" ] && case "$(cat "$LOG/1/cwd")" in "$FAKE_HOME"/*) false;; *) true;; esac' "cwd=$(cat "$LOG/1/cwd")"
  t "the granted directory holds only that batch's copies" \
    '[ "$(ls "$LOG/2/staging" | tr "\n" " ")" = "001.md 002.md 003.md 004.md 005.md 006.md 007.md " ] && [ "$(ls "$LOG/3/staging" | tr "\n" " ")" = "001.md 002.md ref-001.md " ]' "staging=$(ls "$LOG/2/staging" "$LOG/3/staging" | tr "\n" " ")"
  local mismatch=0 at rp
  while IFS=$'\t' read -r at rp; do
    cmp -s "$FAKE_HOME/${at#\~/}" "$LOG/2/staging/$(basename "$rp")" || mismatch=$((mismatch+1))
  done < <(sent_manifest 2 | jq -r '(.judge + .reference)[] | [.sits_at, .read_path] | @tsv')
  t "every staged copy is byte-identical to its source" '[ "$mismatch" = 0 ]' "mismatches=$mismatch"
  t "read paths point into the granted directory" \
    '[ "$(sent_manifest 2 | jq -r ".judge[0].read_path" | xargs dirname)" = "$(grep -Fx -A1 -- --add-dir "$LOG/2/argv" | tail -1)" ]'
  t "the agent sees where an item sits but never its absolute path or the slot" \
    'sent_manifest 2 | jq -e "(has(\"slot\") | not) and all(.judge[]; (has(\"path\") | not) and (.sits_at | startswith(\"~/\")))" >/dev/null'
  t "a slotted scope gets its config dir byte for byte" '[ "$(cat "$LOG/2/config_dir")" = "$FAKE_HOME/.claude-acme/" ]' "got=$(cat "$LOG/2/config_dir")"
  t "every other batch runs with the variable unset, whatever the parent exported" \
    '[ "$(cat "$LOG/1/config_dir" "$LOG/3/config_dir" "$LOG/4/config_dir")" = "__UNSET____UNSET____UNSET__" ]'
  t "no batch inherits a plugin folder, whatever the parent exported" \
    '[ "$(cat "$LOG"/[1-4]/plugin_dirs)" = "__UNSET____UNSET____UNSET____UNSET__" ]' "got=$(cat "$LOG"/[1-4]/plugin_dirs 2>&1)"
  t "no batch receives another scope's paths" \
    '! grep -q "Developer/acme\|Developer/globex" "$LOG/1/stdin" && ! grep -q "Developer/acme" "$LOG/3/stdin" && ! grep -q "Developer/acme\|Developer/globex" "$LOG/4/stdin"'
  t "a batch under its own account is sent no other group's name, no standalone repo and no path in the personal folders" \
    '! sent_manifest 2 | grep -q "globex\|Personal\|~/store\|~/\.claude/" && sent_manifest 2 | jq -e ".known_scopes == [\"acme\"] and .unscoped_projects == [] and .reference == []" >/dev/null' \
    "sent=$(sent_manifest 2 | grep -o "[^\"]*\(globex\|Personal\|~/store\|~/\.claude/\)[^\"]*" | tr "\n" " ")"
  t "where such a path was, the batch is told only that it lies outside the group" \
    'sent_manifest 2 | jq -e "[.judge[] | select(.id == \"acme/claude/skills/shared\" or .id == \"acme/claude/skills/pr-review\") | .linked_from] == [[\"outside this group\"], [\"~/Developer/acme/.claude/skills/shared\", \"outside this group\"]]" >/dev/null' \
    "sent=$(sent_manifest 2 | jq -c "[.judge[] | {id, linked_from}]")"
  t "a batch under the personal account keeps every path" \
    'sent_manifest 1 | jq -e "[.judge[] | select(.id == \"external/~/notes/both\") | .linked_from] == [[\"~/.claude/agents/both.md\"]]" >/dev/null && sent_manifest 3 | jq -e "[.judge[] | select(.id == \"external/~/notes/rules\") | .linked_from] == [[\"~/Developer/globex/.claude/agents/ext.md\"]]" >/dev/null'
  jqt "the report keeps every path, whoever read the file" "$OUT" \
    '[.items[] | select(.id == "acme/claude/skills/shared") | .linked_from] == [["~/Developer/acme/.claude/skills/shared", "~/Developer/globex/.claude/skills/shared"]]'
  std_estate; mk "$FAKE_HOME/Developer/acme/docs/notes.md" "acme notes that only globex imports"
  printf 'Read @../acme/docs/notes.md first.\n' >> "$FAKE_HOME/Developer/globex/CLAUDE.md"; run_custodian
  t "a file of the group's that only another group loads is said to be loaded outside the group, with no name" \
    '[ "$rc" = 0 ] && sent_manifest 2 | jq -e "[.judge[] | select(.id == \"acme/docs/notes.md\") | [.tier, .scope, .imported_by]] == [[\"client\", \"outside this group\", [\"outside this group\"]]]" >/dev/null && ! grep -q "globex" "$LOG/2/stdin"' \
    "rc=$rc sent=$(sent_manifest 2 | jq -c "[.judge[] | select(.id == \"acme/docs/notes.md\")]" 2>&1) named=$(grep -c globex "$LOG/2/stdin")"
  jqt "the report says which group it is" "$OUT" '[.items[] | select(.id == "acme/docs/notes.md") | [.tier, .scope]] == [["client", "globex"]]'
  std_estate; mk "$FAKE_HOME/shared/a.md" "Shared notes. See @b.md too."; mk "$FAKE_HOME/shared/b.md" "more shared notes"
  printf 'Read @~/shared/a.md first.\n' >> "$FAKE_HOME/Developer/acme/CLAUDE.md"; run_custodian
  t "a file of the batch's own that sits outside the group's folders is still named to that batch" \
    'sent_manifest 2 | jq -e "[.judge[] | select(.sits_at == \"~/shared/b.md\") | .imported_by] == [[\"~/shared/a.md\"]] and ([.judge[] | select(.sits_at == \"~/shared/a.md\") | .imported_by] == [[\"~/Developer/acme/CLAUDE.md\"]])" >/dev/null' \
    "sent=$(sent_manifest 2 | jq -c "[.judge[] | select(.sits_at | startswith(\"~/shared\")) | {sits_at, imported_by}]" 2>&1)"
  std_estate; cfg_set '.model = "claude-sonnet-5" | .slots.acme = "~/.claude-acme/"'; run_custodian
  t "no batch is sent which account it runs under or which roots are its own" \
    '[ "$(for n in 1 2 3 4; do sent_manifest $n | jq -r "has(\"slot\") or has(\"own_account\") or has(\"own_roots\")"; done | tr "\n" " ")" = "false false false false " ]'
  t "nothing is left in the temp directory" '[ -z "$(ls -A "$TMPD")" ]' "left=$(ls -A "$TMPD")"
  t "the response schema sticks to structural keywords" \
    'grep -Fx -A1 -- --json-schema "$LOG/1/argv" | tail -1 | jq -e "[.. | objects | keys[]] | all(. != \"if\" and . != \"then\" and . != \"else\" and . != \"allOf\" and . != \"pattern\" and . != \"const\")" >/dev/null'
  t "an earlier batch's copies are gone before the next account runs" '[ "$(wc -l < "$LOG/2/stagings" | tr -d " ")" = 1 ]' "stagings=$(cat "$LOG/2/stagings")"
  jqt "every item in the report carries its home" "$OUT" \
    '([.items[] | select(.id == "acme/web/CLAUDE.md") | .home] == [{tier: "project", scope: "acme", project: "web", root: "~/Developer/acme/web"}]) and ([.items[] | select(.id == "acme/claude/skills/pr-review") | .home] == [{tier: "client", scope: "acme", project: null, root: "~/Developer/acme"}]) and ([.items[] | select(.id == "external/~/notes/both") | .home] == [{tier: null, scope: null, project: null, root: null}])'
  t "a report with homes validates" 'check-jsonschema --schemafile "$lib/schema.json" "$OUT" >/dev/null 2>&1'
  jqt "the report lists items by tier, then scope, then id" "$OUT" \
    '[.items[].id] == ["acme/claude/skills/pr-review", "acme/claude/skills/shared", "external/~/notes/both", "global/CLAUDE.md", "global/agents/reviewer", "global/skills/commit-style", "acme/CLAUDE.md", "acme/claude/skills/pr-auditor", "external/~/notes/rules", "globex/CLAUDE.md", "project/side/CLAUDE.md", "acme/api/CLAUDE.md", "acme/claude/skills/solo", "acme/web/CLAUDE.md"]'

  jqt "what the batches used is summed" "$OUT" '.usage == {seconds: 6, input_tokens: 600, output_tokens: 160, api_equivalent_usd: 1}'
  std_estate; EXTRA_ENV=(FAKE_MODE_AT_3=no_usage); run_custodian
  jqt "when one batch does not say what it used, the report says nothing rather than a part" "$OUT" \
    '.usage == {seconds: null, input_tokens: null, output_tokens: null, api_equivalent_usd: null}'
  t "such a report still validates, and stderr claims no figure" '[ "$rc" = 0 ] && check-jsonschema --schemafile "$lib/schema.json" "$OUT" >/dev/null 2>&1 && ! grep -q "tokens" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  std_estate; EXTRA_ENV=("FAKE_RM_AT_1=$FAKE_HOME/Developer/acme/web/CLAUDE.md"); run_custodian
  t "a file that vanishes before it is staged stops the run" '[ "$rc" != 0 ] && [ ! -e "$OUT" ] && [ "$(ls "$LOG" | wc -l | tr -d " ")" = 1 ] && grep -q "acme/web/CLAUDE.md" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
}

asked() { cut -f"$1" "$LOG.auth" | tr "\n" "|"; }

accounts() {
  std_estate
  EXTRA_ENV=(ANTHROPIC_API_KEY=sk-made-up ANTHROPIC_AUTH_TOKEN=made-up ANTHROPIC_BASE_URL=http://127.0.0.1:9 ANTHROPIC_MODEL=another
             CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_OAUTH_TOKEN=made-up CLAUDE_CODE_SKIP_BEDROCK_AUTH=1
             CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1 AWS_BEARER_TOKEN_BEDROCK=made-up HTTPS_PROXY=http://127.0.0.1:9 DISABLE_TELEMETRY=1
             CLAUDE_CODE_API_BASE_URL=http://127.0.0.1:9 CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR=7 CLAUDE_CODE_CUSTOM_OAUTH_URL=http://127.0.0.1:9
             CLAUDE_CODE_GATEWAY_TOKEN_FILE_DESCRIPTOR=8 CLAUDE_CODE_SESSION_ACCESS_TOKEN=made-up CLAUDE_LOCAL_OAUTH_API_BASE=http://127.0.0.1:9
             CLAUDE_TRUSTED_DEVICE_TOKEN=made-up CLAUDE_CODE_NOT_YET_INVENTED=1 CLAUDECODE=1 CLAUDE_CODE_ENABLE_TELEMETRY=1
             AGENT_PROXY_AUTH_TOKEN=made-up CCR_AGENT_PROXY_TOKEN_FILE_DESCRIPTOR=9 CLAUDE_CODE_CLIENT_CERT=/made/up.pem CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000
             CLAUDE_CODE_CERT_STORE=system CLAUDE_CODE_PROXY_RESOLVES_HOSTS=1 NODE_EXTRA_CA_CERTS=/made/up-ca.pem LC_ALL=C
             USE_STAGING_OAUTH=1 USE_LOCAL_OAUTH=1 SESSION_INGRESS_URL=http://127.0.0.1:9 BETA_TRACING_ENDPOINT=http://127.0.0.1:9 ENABLE_BETA_TRACING_DETAILED=1
             OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:9 NODE_OPTIONS=--require=/made/up.js GH_TOKEN=made-up A_VARIABLE_OF_MY_OWN=1)
  run_custodian
  t "an audit runs whatever credentials the parent exported" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  local own="CLAUDE_CODE_CERT_STORE CLAUDE_CODE_CLIENT_CERT CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_PROXY_RESOLVES_HOSTS CUSTODIAN_AUDIT HOME HTTPS_PROXY LC_ALL NODE_EXTRA_CA_CERTS PATH TMPDIR "
  seen_by() { grep -vxE 'PWD|OLDPWD|SHLVL|_' "$LOG/$1/vars" | LC_ALL=C sort | tr "\n" " "; }
  t "a batch is given exactly these variables and no other, whatever the parent exported and whatever Claude Code may read next" \
    '[ "$(ls "$LOG" | wc -l | tr -d " ")" = 4 ] && [ "$(seen_by 1)" = "$own" ] && [ "$(seen_by 3)" = "$own" ] && [ "$(seen_by 4)" = "$own" ]' "got=$(seen_by 1)"
  t "a batch under a group's own account is given the same, and its config folder" '[ "$(seen_by 2)" = "CLAUDE_CODE_CERT_STORE CLAUDE_CODE_CLIENT_CERT CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_PROXY_RESOLVES_HOSTS CLAUDE_CONFIG_DIR CUSTODIAN_AUDIT HOME HTTPS_PROXY LC_ALL NODE_EXTRA_CA_CERTS PATH TMPDIR " ]' "got=$(seen_by 2)"
  t "every batch runs with Claude Code's own analytics and error reports switched off" '[ "$(for n in 1 2 3 4; do grep -c "^CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC$" "$LOG/$n/vars"; done | tr "\n" " ")" = "1 1 1 1 " ]'
  t "a proxy, the certificates and the output limit are passed on, with their values" \
    'grep -qx HTTPS_PROXY "$LOG/1/vars" && grep -qx NODE_EXTRA_CA_CERTS "$LOG/1/vars" && grep -qx CLAUDE_CODE_MAX_OUTPUT_TOKENS "$LOG/1/vars" && [ "$(cat "$LOG/1/kept_values")" = "http://127.0.0.1:9 /made/up-ca.pem 64000" ]' "vars=$(tr "\n" " " < "$LOG/1/vars") values=$(cat "$LOG/1/kept_values" 2>&1)"
  t "each account is asked once who is logged in, under its own folder" '[ "$(asked 1)" = "__UNSET__|$FAKE_HOME/.claude-acme|" ]' "asked=$(asked 1)"
  t "the question is put before any batch runs, in the judge's own environment" '[ "$(asked 2)" = "0|0|" ] && [ "$(asked 3)" = "CLAUDE_CODE_CERT_STORE,CLAUDE_CODE_CLIENT_CERT,CLAUDE_CODE_MAX_OUTPUT_TOKENS,CLAUDE_CODE_PROXY_RESOLVES_HOSTS,|CLAUDE_CODE_CERT_STORE,CLAUDE_CODE_CLIENT_CERT,CLAUDE_CODE_MAX_OUTPUT_TOKENS,CLAUDE_CODE_PROXY_RESOLVES_HOSTS,|" ]' "asked=$(cat "$LOG.auth")"
  t "nothing Claude Code says about who is logged in is repeated or kept" '! grep -rq "SECRET" "$ERR" "$STDOUT" "$OUTDIR"'

  std_estate; auth_as "$FAKE_HOME/.claude-acme" out; run_custodian
  expect_preflight "a group's account that is logged out" "account at ~/.claude-acme, which reads acme, is not logged in"
  t "the refusal says how to log that account in" 'grep -q "CLAUDE_CONFIG_DIR=~/.claude-acme claude" "$ERR"' "stderr=$(cat "$ERR")"
  t "a refused run creates nothing beside the report" '[ ! -e "$OUTDIR" ]'
  std_estate; auth_as "$FAKE_HOME/.claude" out; run_custodian
  expect_preflight "a personal account that is logged out" "personal account is not logged in"
  t "the way to log it in is the plain command" 'grep -q "Run claude, log in" "$ERR"' "stderr=$(cat "$ERR")"
  std_estate; auth_as "$FAKE_HOME/.claude" out; EXTRA_ENV=(CLAUDE_CONFIG_DIR=/parent/slot); run_custodian
  t "in a shell that names another config folder, the way to log the default one in says to leave that name out" 'grep -q "Run env -u CLAUDE_CONFIG_DIR claude, log in" "$ERR"' "stderr=$(cat "$ERR")"
  std_estate; auth_as "$FAKE_HOME/.claude" key; run_custodian
  expect_preflight "an account set up with a key" "personal account is set up with an API key (ANTHROPIC_API_KEY).*subscription only"
  std_estate; auth_as "$FAKE_HOME/.claude" helper; run_custodian
  expect_preflight "an account whose key comes from a helper" "API key (apiKeyHelper)"
  std_estate; auth_as "$FAKE_HOME/.claude-acme" token; run_custodian
  expect_preflight "an account logged in by a token" "claude-acme.*logged in by oauth_token"
  std_estate; auth_as "$FAKE_HOME/.claude" bedrock; run_custodian
  expect_preflight "an account set up for another provider" "set up for bedrock"
  std_estate; auth_as "$FAKE_HOME/.claude" garbage; run_custodian
  expect_preflight "an answer that is not JSON" "could not be read"
  std_estate; auth_as "$FAKE_HOME/.claude" old; run_custodian
  expect_preflight "a Claude Code that cannot say who is logged in" "could not be read"
  std_estate; rm "$FAKE_HOME/.claude-acme/.claude.json"; run_custodian
  expect_preflight "a slot folder Claude Code has never used" "account at ~/.claude-acme, which reads acme, has never been set up as a Claude Code config folder"
  t "such a folder is not shown to Claude Code, which would set it up and migrate what settings it found there" \
    '[ "$(asked 1)" = "__UNSET__|" ] && [ -z "$(ls -A "$FAKE_HOME/.claude-acme")" ]' "asked=$(asked 1) folder=$(ls -A "$FAKE_HOME/.claude-acme" | tr "\n" " ")"
  judging_estate; auth_as "$FAKE_HOME/.claude-acme" out; run_custodian
  t "an account no batch runs under is not asked" '[ "$rc" = 0 ] && [ "$(asked 1)" = "__UNSET__|" ]' "rc=$rc asked=$(asked 1)"
  std_estate; auth_as "$FAKE_HOME/.claude-acme" out; run_custodian --dry-run
  t "a dry run asks nobody" '[ "$rc" = 0 ] && [ ! -e "$LOG.auth" ]' "rc=$rc"

  std_estate; account_folder "$FAKE_HOME/.claude-me"; cfg_set '.default_slot = "~/.claude-me"'; run_custodian
  t "with a default slot every batch without a slot of its own runs under it" \
    '[ "$rc" = 0 ] && [ "$(cat "$LOG/1/config_dir" "$LOG/3/config_dir" "$LOG/4/config_dir")" = "$FAKE_HOME/.claude-me$FAKE_HOME/.claude-me$FAKE_HOME/.claude-me" ] && [ "$(cat "$LOG/2/config_dir")" = "$FAKE_HOME/.claude-acme" ]' \
    "rc=$rc got=$(cat "$LOG"/[1-4]/config_dir 2>&1) stderr=$(cat "$ERR")"
  t "a batch under the default slot says so" 'grep -q "batch global: judging 4 items (personal account at ~/.claude-me)" "$ERR" && grep -q "batch acme: judging 7 items (account ~/.claude-acme)" "$ERR"' "stderr=$(cat "$ERR")"
  t "the default slot is asked about, and the default folder is not" '[ "$(asked 1)" = "$FAKE_HOME/.claude-acme|$FAKE_HOME/.claude-me|" ]' "asked=$(asked 1)"
  std_estate; account_folder "$FAKE_HOME/.claude-me"; cfg_set '.default_slot = "~/.claude-me"'; auth_as "$FAKE_HOME/.claude-me" out; run_custodian
  expect_preflight "a default slot that is logged out" "personal account at ~/.claude-me is not logged in"
  t "the refusal says how to log the default slot in" 'grep -q "CLAUDE_CONFIG_DIR=~/.claude-me claude" "$ERR"' "stderr=$(cat "$ERR")"
  std_estate; cfg_set '.default_slot = "~/.claude-me"'; run_custodian; expect_preflight "a default slot that does not exist" "default_slot.*claude-me"
  std_estate; cfg_set '.default_slot = "claude-me"'; run_custodian; expect_preflight "a relative default slot" "default_slot must be an absolute path"
  std_estate; cfg_set '.default_slot = "~/.claude/"'; run_custodian
  expect_preflight "a default slot that names the default folder, whose login Claude Code keeps under no name" "default_slot is for a login kept somewhere other than ~/.claude"
  std_estate; account_folder "$FAKE_HOME/.claude-me"; mk "$FAKE_HOME/.claude-me/CLAUDE.md" "my rules"; mk "$FAKE_HOME/.claude-me/rules/style.md" "my style"
  cfg_set '.default_slot = "~/.claude-me" | .tiers += [{"tier": "client", "path": "~/.claude-me", "scope": "globex"}]'; run_custodian --dry-run; judged
  jqt "a root that is the default slot is read as a config folder" "$WORLD/judged.json" 'any(.[]; .sits_at == "~/.claude-me/rules/style.md" and .kind == "rule")'
}

rendering() {
  new_world
  mk "$FAKE_HOME/store/CLAUDE.md" "global rules"
  mk "$FAKE_HOME/store/custodian.examples.md" '# Custodian examples

## Correctly global

- Escape with `sed "s/&/\\&/g"` & friends.
- Never trust $(whoami) or `backticks` in a path.
- A literal {{MANIFEST}} and a trailing backslash \

## Leakage

- acme-staging.internal
- GLOBEX-1234
- acme_core schema

## Correctly client-tier

- acme-release: the acme change board exists nowhere else.
'
  config <<'EOF'
{ "canonical_store": "~/store", "tiers": [ { "tier": "global", "path": "~/store" } ], "output": "~/Developer/.custodian/audit.json" }
EOF
  run_custodian
  t "a run with awkward examples succeeds" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  t "examples arrive verbatim" \
    'grep -Fq -- "- Escape with \`sed \"s/&/\\\\&/g\"\` & friends." "$LOG/1/stdin" && grep -Fq -- "- Never trust \$(whoami) or \`backticks\` in a path." "$LOG/1/stdin" && grep -Fq -- "- A literal {{MANIFEST}} and a trailing backslash \\" "$LOG/1/stdin"' \
    "stdin=$(grep -n "Escape\|whoami\|literal" "$LOG/1/stdin")"
  local sections="## Vocabulary|## The test|## Verdicts|## The passes|## The owner's taste|## Correctly global|## Leakage|## Correctly client-tier|## Specimens|## Procedure|## Quoting|## Done when|## The manifest|"
  t "the prompt carries its sections in order" '[ "$(grep "^## " "$LOG/1/stdin" | tr "\n" "|")" = "$sections" ]' "got=$(grep "^## " "$LOG/1/stdin" | tr "\n" "|")"
  t "inserted text is never rescanned" '[ "$(grep -c "^<manifest>$" "$LOG/1/stdin")" = 1 ] && sent_manifest 1 | jq -e ".judge | length == 1" >/dev/null && ! grep -q "{{EXAMPLES}}" "$LOG/1/stdin"'

  clone_runner
  sed 's/{{EXAMPLES}}/no placeholder here/' "$lib/prompt.md" > "$WORLD/custodian/prompt.md"
  run_custodian
  t "a template without a placeholder is exit 2" '[ "$rc" = 2 ] && grep -q "EXAMPLES" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  { cat "$lib/prompt.md"; echo "{{MANIFEST}}"; } > "$WORLD/custodian/prompt.md"
  run_custodian
  t "a template with a repeated placeholder is exit 2" '[ "$rc" = 2 ] && grep -q "MANIFEST" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  RUN="$lib/run.sh"
}

LEAK='- Always run the staging smoke test against acme-staging.internal before opening a PR.'

judging_estate() {
  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" "# Global

- Use conventional commits.
$LEAK
## Databases
The orders table lives in the acme_core schema. $(printf 'x%.0s' $(seq 1 300))

## Again
- Use conventional commits.
"
  mk "$FAKE_HOME/store/skills/commit-style/SKILL.md" "---
description: Commit conventions for the acme change board
---
Write imperative subjects.
"
  mk "$FAKE_HOME/Developer/acme/.claude/skills/deploy/SKILL.md" "---
description: Generic deploy checklist
---
Check the build is green.
"
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" },
             { "tier": "client", "path": "~/Developer/acme", "scope": "acme" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
}

finding() { printf '{"line": %s, "text": %s, "verdict": "%s", "suggested_tier": "%s", "rationale": "Names something that belongs to acme."}' "$1" "$(jq -Rn --arg t "$2" '$t')" "$3" "$4"; }
with_findings() { EXTRA_ENV=("FAKE_FILTER=.items |= map(if .id == \"global/CLAUDE.md\" then .findings = [$1] else . end)"); }
claude_md() { jq -c '.items[] | select(.id == "global/CLAUDE.md")' "$OUT" > "$WORLD/item.json"; }

hub_estate() {
  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" "global rules"
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" '# Acme

Deploys go through the acme change board.
<!-- context-central:start -->
## The parts of the map

- `.context-central/repos/`: one note per repo.
Staging lives at globex-staging.internal.
<!-- context-central:end -->
Write commit subjects in the imperative mood.
'
  mk "$FAKE_HOME/Developer/acme/.claude/rules/open.md" 'a rule
  <!-- context-central:start -->
a block that is never closed
'
  mk "$FAKE_HOME/Developer/acme/.claude/rules/twice.md" '<!-- context-central:start -->
one
<!-- context-central:end -->
between
<!-- context-central:start -->
two
<!-- context-central:end -->
<!-- context-central:end -->
'
  mk "$FAKE_HOME/Developer/acme/.claude/skills/marked/SKILL.md" '<!-- context-central:start -->
a skill is judged whole
<!-- context-central:end -->
'
  config <<'EOF'
{ "canonical_store": "~/store",
  "tiers": [ { "tier": "global", "path": "~/store" }, { "tier": "client", "path": "~/Developer/acme", "scope": "acme" } ],
  "output": "~/Developer/.custodian/audit.json" }
EOF
}
hub_findings() { EXTRA_ENV=("FAKE_FILTER=.items |= map(if .id == \"acme/CLAUDE.md\" then .findings = [$1] else . end)"); }
hub_item() { jq -c '.items[] | select(.id == "acme/CLAUDE.md")' "$OUT" > "$WORLD/item.json"; }

generated_blocks() {
  hub_estate; run_custodian --dry-run
  jqt "the lines a tool wrote into a file are a fact of the manifest, first line and last" "$STDOUT" \
    '[.batches[].judge[] | select(.id == "acme/CLAUDE.md") | .generated] == [[[4, 9]]]'
  jqt "a block that is never closed is no block, two blocks are two, and a stray end is nothing" "$STDOUT" \
    '([.batches[].judge[] | select(.id == "acme/.claude/rules/open") | .generated] == [[]]) and ([.batches[].judge[] | select(.id == "acme/.claude/rules/twice") | .generated] == [[[1, 3], [5, 7]]])'
  jqt "a file judged whole has none, and neither has a file without the marks" "$STDOUT" \
    '([.batches[].judge[] | select(.kind == "skill") | .generated] == [[]]) and ([.batches[].judge[] | select(.id == "global/CLAUDE.md") | .generated] == [[]])'

  hub_estate; hub_findings "$(finding 5 "## The parts of the map" warn global), $(finding 7 "- \`.context-central/repos/\`: one note per repo." warn global), $(finding 10 "Write commit subjects in the imperative mood." warn global)"; run_custodian; hub_item
  t "an audit over a file with a generated block runs" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "a finding that the block is too generic is dropped, and one outside the block is kept" "$WORLD/item.json" '[.findings[].line] == [10] and .verdict == "warn"'
  t "the judge is told which lines they are" 'sent_manifest 2 | jq -e "[.judge[] | select(.id == \"acme/CLAUDE.md\") | .generated] == [[[4, 9]]]" >/dev/null && grep -q "generated" "$lib/prompt.md"'
  hub_estate; hub_findings "$(finding 5 "## The parts of the map" warn global)"; run_custodian; hub_item
  jqt "a file whose only findings were of that kind passes" "$WORLD/item.json" '.findings == [] and .verdict == "pass" and .suggested_tier == null'
  hub_estate; hub_findings "$(finding 8 "Staging lives at globex-staging.internal." fail client), $(finding 7 "- \`.context-central/repos/\`: one note per repo." warn project)"; run_custodian; hub_item
  jqt "a leak inside the block is still a leak, and so is text there that is too specific" "$WORLD/item.json" '[.findings[] | [.line, .verdict]] == [[7, "warn"], [8, "fail"]] and .verdict == "fail"'
  hub_estate; hub_findings "$(finding 5 "no such line anywhere" warn global)"; run_custodian
  t "a quote that is not in the file still fails the run, block or no block" '[ "$rc" = 4 ] && grep -q "quote not found" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
}

response_handling() {
  judging_estate; with_findings "$(finding 4 "$LEAK" fail client)"; run_custodian; claude_md
  t "a report full of findings still exits 0" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  jqt "a CLAUDE.md verdict is the worst of its findings, whatever the agent said" "$WORLD/item.json" '.verdict == "fail" and .suggested_tier == "client"'
  jqt "summary counts items by verdict" "$OUT" '.summary == {total: 3, pass: 2, warn: 0, fail: 1}'
  t "the mixed report validates" 'check-jsonschema --schemafile "$lib/schema.json" "$OUT" >/dev/null 2>&1'

  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "global/CLAUDE.md" then .verdict = "fail" | .suggested_tier = "client" else . end)'); run_custodian; claude_md
  jqt "a CLAUDE.md with no findings passes, whatever the agent said" "$WORLD/item.json" '.verdict == "pass" and .suggested_tier == null'

  judging_estate; with_findings "$(finding 6 "The orders table lives in the acme_core schema." fail project), $(finding 3 "- Use conventional commits." warn global), $(finding 4 "$LEAK" fail client)"; run_custodian; claude_md
  jqt "the suggested tier comes from the first worst finding by line" "$WORLD/item.json" '.verdict == "fail" and .suggested_tier == "client" and ([.findings[].line] == [3, 4, 6])'

  judging_estate; EXTRA_ENV=("FAKE_FILTER=.items |= map(if .id == \"global/skills/commit-style\" then .findings = [$(finding 2 "description: Commit conventions for the acme change board" fail client)] else . end)"); run_custodian
  t "a skill with findings is exit 4" '[ "$rc" = 4 ] && grep -q "global/skills/commit-style" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "global/skills/commit-style" then .verdict = "fail" | .suggested_tier = "client" else . end)'); run_custodian
  t "a fail on a skill without evidence is exit 4" '[ "$rc" = 4 ] && grep -q "evidence" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "global/skills/commit-style" then .verdict = "fail" | .suggested_tier = "client" | .evidence = {line: 2, text: "Commit conventions for the acme change board"} else . end)'); run_custodian
  t "a fail on a skill with evidence is accepted" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  jqt "skill evidence is replaced by the file's own line" "$OUT" '.items[] | select(.id == "global/skills/commit-style") | .evidence == {line: 2, text: "description: Commit conventions for the acme change board"}'

  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "acme/.claude/skills/deploy" then .verdict = "warn" | .suggested_tier = "global" else . end)'); run_custodian
  t "a too-generic warn needs no evidence" '[ "$rc" = 0 ]' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "acme/.claude/skills/deploy" then .verdict = "warn" | .suggested_tier = "project" else . end)'); run_custodian
  t "a too-specific warn without evidence is exit 4" '[ "$rc" = 4 ]' "rc=$rc"
  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "acme/.claude/skills/deploy" then .suggested_tier = "global" else . end)'); run_custodian
  t "a pass carrying a suggested tier is exit 4" '[ "$rc" = 4 ]' "rc=$rc"
  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "acme/.claude/skills/deploy" then .verdict = "warn" else . end)'); run_custodian
  t "a warn without a suggested tier is exit 4" '[ "$rc" = 4 ]' "rc=$rc"

  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items |= map(select(.id != "global/CLAUDE.md"))'); run_custodian
  t "a missing id is exit 4" '[ "$rc" = 4 ] && grep -q "global/CLAUDE.md" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items += [.items[0] | .id = "global/invented"]'); run_custodian
  t "an extra id is exit 4" '[ "$rc" = 4 ] && grep -q "global/invented" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items += [.items[0]]'); run_custodian
  t "a duplicated id is exit 4" '[ "$rc" = 4 ]' "rc=$rc"
  judging_estate; EXTRA_ENV=('FAKE_FILTER=.items[0].tier = "client"'); run_custodian
  t "an unknown field in the response is exit 4" '[ "$rc" = 4 ]' "rc=$rc"
  t "a rejected response writes no report" '[ ! -e "$OUT" ]'
}

quote_verification() {
  judging_estate; with_findings "$(finding 4 "$LEAK" fail client)"; run_custodian; claude_md
  t "an exact quote is verified and the finding is kept whole" \
    'jq -e --arg leak "$LEAK" ".findings == [{line: 4, text: \$leak, verdict: \"fail\", suggested_tier: \"client\", rationale: \"Names something that belongs to acme.\"}]" "$WORLD/item.json" >/dev/null' "item=$(cut -c1-300 "$WORLD/item.json")"

  judging_estate; with_findings "$(finding 4 "acme-staging.internal before opening" fail client)"; run_custodian; claude_md
  t "a fragment of the line is verified and replaced by the whole line" 'jq -e --arg leak "$LEAK" ".findings[0] | .line == 4 and .text == \$leak" "$WORLD/item.json" >/dev/null' "item=$(cat "$WORLD/item.json" | cut -c1-300)"

  judging_estate; with_findings "$(finding 4 "Names a host: \"$LEAK\" which every client can load" fail client)"; run_custodian; claude_md
  t "a sentence wrapping the whole line is verified" 'jq -e --arg leak "$LEAK" ".findings[0] | .line == 4 and .text == \$leak" "$WORLD/item.json" >/dev/null' "rc=$rc stderr=$(cat "$ERR")"

  judging_estate; with_findings "$(finding 5 "Databases" warn client)"; run_custodian; claude_md
  jqt "list and heading markers are ignored when matching" "$WORLD/item.json" '.findings[0] | .line == 5 and .text == "## Databases"'

  judging_estate; with_findings "$(finding 3 "* Use conventional commits." warn global)"; run_custodian; claude_md
  jqt "a different list marker still matches the line" "$WORLD/item.json" '.findings[0] | .line == 3 and .text == "- Use conventional commits."'

  new_world; examples_ok
  mk "$FAKE_HOME/store/CLAUDE.md" "# Global
$LEAK"
  mk "$FAKE_HOME/store/skills/commit-style/SKILL.md" "---
description: Commit conventions for the acme change board
---
"
  config <<'EOF'
{ "canonical_store": "~/store", "tiers": [ { "tier": "global", "path": "~/store" } ], "output": "~/Developer/.custodian/audit.json" }
EOF
  EXTRA_ENV=("FAKE_FILTER=.items |= map(if .id == \"global/CLAUDE.md\" then .findings = [$(finding 2 "$LEAK" fail client)] else .verdict = \"fail\" | .suggested_tier = \"client\" | .evidence = {line: 1, text: \"---\"} end)")
  run_custodian; claude_md
  t "a file without a trailing newline keeps its last line" '[ "$rc" = 0 ] && jq -e --arg leak "$LEAK" ".findings[0] | .line == 2 and .text == \$leak" "$WORLD/item.json" >/dev/null' "rc=$rc stderr=$(cat "$ERR")"
  jqt "the next file's first line is its own" "$OUT" '.items[] | select(.id == "global/skills/commit-style") | .evidence == {line: 1, text: "---"}'

  judging_estate; with_findings "$(finding 1 "$LEAK" fail client)"; run_custodian; claude_md
  jqt "a wrong line number is repaired" "$WORLD/item.json" '.findings[0].line == 4'

  judging_estate; with_findings "$(finding 8 "- Use conventional commits." warn global)"; run_custodian; claude_md
  jqt "a repair takes the nearest matching line" "$WORLD/item.json" '.findings[0].line == 9'

  judging_estate; with_findings "$(finding 6 "The orders table lives in the acme_core schema." fail client)"; run_custodian; claude_md
  jqt "the reported text is capped at 300 characters and stays a verbatim prefix" "$WORLD/item.json" '.findings[0].text | length == 300 and endswith("x") and startswith("The orders table lives in the acme_core schema. xxx")'

  judging_estate; with_findings "$(finding 4 "Always deploy to the production cluster on Fridays" fail client)"; run_custodian
  t "text found nowhere is exit 4" '[ "$rc" = 4 ]' "rc=$rc"
  t "the rejection names the id and line but never the text" 'grep -q "global/CLAUDE.md" "$ERR" && grep -q "line 4" "$ERR" && ! grep -q "production cluster" "$ERR"' "stderr=$(cat "$ERR")"

  judging_estate; with_findings "$(finding 4 "acme" fail client)"; run_custodian
  t "a short fragment is not enough to match" '[ "$rc" = 4 ]' "rc=$rc"
}

prints_match() {
  local path print n=0
  while IFS=$'\t' read -r path print; do
    [ "$(sha "$path")" = "$print" ] || return 1
    n=$((n+1))
  done < <(jq -r "$1" "$2")
  [ "$n" -gt 0 ]
}

freshness_facts() {
  std_estate
  mkdir -p "$WORLD/conf"; mv "$CFG" "$WORLD/conf/custodian.config.json"; CFG="$WORLD/conf/custodian.config.json"; BASE="$WORLD/conf/baseline.json"
  mk "$FAKE_HOME/Developer/acme/vendored/CLAUDE.md" "someone else's rules"
  cfg_set '.exclude = ["~/Developer/acme/vendored"] | .tiers[0].path = "~/store/"'
  lnk "$FAKE_HOME/notes/nowhere.md" "$FAKE_HOME/store/agents/ghost.md"
  run_custodian --dry-run
  jqt "a dry run lists every place each item was found" "$STDOUT" \
    '[.batches[].judge[] | select(.sits_at == "~/Developer/acme/claude/skills/shared/SKILL.md") | .found_at | map(sub("^.*/home/"; "~/"))] == [["~/Developer/acme/.claude/skills/shared/SKILL.md", "~/Developer/globex/.claude/skills/shared/SKILL.md"]]'
  jqt "a root written with a trailing slash is found at the same paths as one without" "$STDOUT" \
    '[.batches[].judge[].found_at[] | select(contains("//"))] == [] and any(.batches[].judge[]; .found_at == [.path] and (.path | endswith("/store/CLAUDE.md")))'
  t "a dry run writes no baseline" '[ ! -e "$BASE" ]'

  printf '{"report_generated_at": "2020-01-01T00:00:00Z", "open_leaks": 9}' > "$WORLD/conf/status.json"
  run_custodian
  t "the run with fingerprints succeeds and still validates" '[ "$rc" = 0 ] && check-jsonschema --schemafile "$lib/schema.json" "$OUT" >/dev/null 2>&1' "rc=$rc stderr=$(cat "$ERR")"
  t "every item carries the SHA-256 of its file" 'prints_match ".items[] | [.path, (.sha256 // \"none\")] | @tsv" "$OUT"' "prints=$(jq -c '[.items[] | .sha256]' "$OUT" 2>&1 | cut -c1-200)"
  t "the report says which examples it judged with" \
    'jq -e --arg examples "$(sha "$FAKE_HOME/store/custodian.examples.md")" ".examples_sha256 == \$examples" "$OUT" >/dev/null' "report=$(jq -c '{examples_sha256}' "$OUT" 2>&1)"
  jq 'del(.examples_sha256) | .items |= map(del(.sha256))' "$OUT" > "$WORLD/older.json"
  t "a report from before fingerprints still validates" 'check-jsonschema --schemafile "$lib/schema.json" "$WORLD/older.json" >/dev/null 2>&1'
  t "the agent is never shown a fingerprint, a found path or a real path" \
    '[ "$(for n in 1 2 3 4; do sent_manifest $n | jq -r "[(.judge + .reference)[] | select(has(\"sha256\") or has(\"found_at\") or has(\"path\"))] | length"; done | tr "\n" " ")" = "0 0 0 0 " ]'
  t "every session the audit starts carries its mark" '[ "$(cat "$LOG"/1/audit_mark "$LOG"/2/audit_mark "$LOG"/3/audit_mark "$LOG"/4/audit_mark)" = 1111 ]' "marks=$(cat "$LOG"/*/audit_mark 2>&1)"

  t "a successful run writes a private baseline beside its config" '[ -f "$BASE" ] && [ "$(stat -f %Lp "$BASE")" = 600 ]' "dir=$(ls -A "$WORLD/conf")"
  t "and removes the status of the report it replaced" '[ ! -e "$WORLD/conf/status.json" ]' "dir=$(ls -A "$WORLD/conf")"
  t "the baseline belongs to this report" 'jq -e --slurpfile report "$OUT" ".report_generated_at == \$report[0].generated_at" "$BASE" >/dev/null' "baseline=$(jq -c '{report_generated_at}' "$BASE" 2>&1)"
  t "every judged found path carries the fingerprint of the file it resolved to" \
    'prints_match ".found[] | select(.sha256 != null) | [.path, .sha256] | @tsv" "$BASE" && jq -e --slurpfile report "$OUT" "([.found[].sha256 | select(. != null)] | unique) == ([\$report[0].items[].sha256] | unique)" "$BASE" >/dev/null'
  local linked="$FAKE_HOME/.claude/skills/pr-review/SKILL.md"
  t "the baseline records what each found path resolved to: its file, size and modification time" \
    'jq -e --arg p "$linked" --arg inode "$(stat -L -f %d:%i "$linked")" --argjson size "$(stat -L -f %z "$linked")" --argjson mtime "$(stat -L -f %m "$linked")" ".found[] | select(.path == \$p) | .inode == \$inode and .size == \$size and .mtime == \$mtime" "$BASE" >/dev/null' "row=$(jq -c --arg p "$linked" '.found[] | select(.path == $p)' "$BASE" 2>&1)"
  t "the baseline fingerprints the examples too" \
    'jq -e --slurpfile report "$OUT" --arg p "$FAKE_HOME/store/custodian.examples.md" ".examples.sha256 == \$report[0].examples_sha256 and .examples.path == \$p and (.examples.size | type) == \"number\" and (.examples.mtime | type) == \"number\"" "$BASE" >/dev/null' "examples=$(jq -c '.examples' "$BASE" 2>&1)"
  t "the baseline lists every found path once, link locations included" \
    'jq -e --arg h "$FAKE_HOME" "([.found[].path] | index(\$h + \"/.claude/skills/pr-review/SKILL.md\")) != null and ([.found[].path] | index(\$h + \"/Developer/globex/.claude/skills/shared/SKILL.md\")) != null and ([.found[].path] == ([.found[].path] | unique))" "$BASE" >/dev/null' "found=$(jq -c '.found | length' "$BASE" 2>&1)"
  t "found paths are the raw expansion: a dangling link and an excluded file are listed, unjudged" \
    'jq -e --arg h "$FAKE_HOME" "([.found[] | select(.path == \$h + \"/store/agents/ghost.md\") | [.inode, .sha256]] == [[null, null]]) and ([.found[] | select(.path == \$h + \"/Developer/acme/vendored/CLAUDE.md\") | [(.inode | type), .sha256]] == [[\"string\", null]])" "$BASE" >/dev/null' "rows=$(jq -c '[.found[] | select(.path | test("ghost|vendored"))]' "$BASE" 2>&1)"
  t "the baseline keeps a copy of the roots and exclusions it was made with" \
    'jq -e --slurpfile config "$CFG" ".roots == (\$config[0] | [.tiers, (.exclude // [])] | tojson)" "$BASE" >/dev/null' "roots=$(jq -c .roots "$BASE" 2>&1 | cut -c1-200)"

  cp "$OUT" "$WORLD/report.before"; cp "$BASE" "$WORLD/baseline.before"
  printf 'one more line\n' >> "$FAKE_HOME/store/CLAUDE.md"
  EXTRA_ENV=(FAKE_MODE=exit1); run_custodian
  t "a failed run leaves the old report and the old baseline byte for byte" '[ "$rc" = 3 ] && cmp -s "$OUT" "$WORLD/report.before" && cmp -s "$BASE" "$WORLD/baseline.before"' "rc=$rc"

  EXTRA_ENV=(); chmod 555 "$WORLD/conf"; run_custodian; chmod 755 "$WORLD/conf"
  t "a run that cannot write its baseline leaves the old report in place" '[ "$rc" != 0 ] && cmp -s "$OUT" "$WORLD/report.before" && cmp -s "$BASE" "$WORLD/baseline.before"' "rc=$rc stderr=$(cat "$ERR")"

  std_estate; local before; before=$(sha "$FAKE_HOME/store/CLAUDE.md"); local size; size=$(stat -f %z "$FAKE_HOME/store/CLAUDE.md")
  EXTRA_ENV=("FAKE_APPEND_AT_2=$FAKE_HOME/store/CLAUDE.md"); run_custodian
  t "a file edited while the audit runs keeps the fingerprint and the size of what was judged" \
    '[ "$rc" = 0 ] && [ "$(sha "$FAKE_HOME/store/CLAUDE.md")" != "$before" ] && jq -e --arg print "$before" ".items[] | select(.id == \"global/CLAUDE.md\") | .sha256 == \$print" "$OUT" >/dev/null && jq -e --arg p "$FAKE_HOME/store/CLAUDE.md" --argjson size "$size" ".found[] | select(.path == \$p) | .size == \$size" "$WORLD/baseline.json" >/dev/null' "rc=$rc stderr=$(cat "$ERR")"
}

seed_stale() { mkdir -p "$OUTDIR"; printf 'STALE' > "$OUT"; }
untouched() { [ "$(cat "$OUT")" = "STALE" ] && [ "$(ls -A "$OUTDIR" | tr "\n" " ")" = "$1" ] && [ -z "$(ls -A "$TMPD")" ]; }

failure_behaviour() {
  local mode started
  for mode in exit1 garbage scalars error_result init_bash init_mcp init_mode no_mcp_field init_plugin no_plugins_field plugins_not_array plugin_not_object plugin_named_oddly tools_not_names mcp_not_named analytics_on init_key no_key_source init_old no_version limit logged_out api_error denial no_denials_field no_output hang hang_hard; do
    judging_estate; seed_stale
    cfg_set '.timeout_seconds = 1'
    EXTRA_ENV=("FAKE_MODE=$mode"); started=$SECONDS; run_custodian
    t "agent failure ($mode) is exit 3, promptly" '[ "$rc" = 3 ] && [ $((SECONDS - started)) -lt 20 ]' "rc=$rc seconds=$((SECONDS - started)) stderr=$(cat "$ERR")"
    t "agent failure ($mode) leaves the old report, no strays and no lock" 'untouched "audit.json failed "' "dir=$(ls -A "$OUTDIR" | tr "\n" " ") tmp=$(ls -A "$TMPD")"
    t "agent failure ($mode) keeps the prompt, the stream and the reason" \
      '[ -s "$OUTDIR/failed/prompt.md" ] && [ -e "$OUTDIR/failed/stream.jsonl" ] && [ -s "$OUTDIR/failed/reason.txt" ]'
  done
  t "a child that ignores termination is killed once the grace period ends" 'gone "$(cat "$LOG/1/pid")"'
  judging_estate; EXTRA_ENV=(FAKE_MODE=denial); run_custodian
  t "a refused read is named on stderr" 'grep -q "/etc/passwd" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=init_plugin); run_custodian
  t "a plugin that is not Claude Code's own is named on stderr" 'grep -q "own is listed: probe-mod" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=no_plugins_field); run_custodian
  t "an init event with no plugin list says so" 'grep -q "does not report its plugins" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=init_key); run_custodian
  t "a session that used a key is named on stderr" 'grep -q "used a key (ANTHROPIC_API_KEY)" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; cfg_set '.timeout_seconds = 300'; EXTRA_ENV=(FAKE_MODE=tools_not_names FAKE_HANG_AFTER_INIT=1); started=$SECONDS; run_custodian
  t "tools that are not names are a wider surface, seen at the first event and kept as evidence" \
    '[ "$rc" = 3 ] && [ $((SECONDS - started)) -lt 15 ] && grep -q "wider than Read, Glob, Grep" "$ERR" && [ -s "$OUTDIR/failed/stream.jsonl" ]' "rc=$rc seconds=$((SECONDS - started)) stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=mcp_not_named); run_custodian
  t "an MCP server with no name of its own is still named in the refusal" 'grep -q "MCP servers are connected: {\"a\":1}, unnamed" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=analytics_on); run_custodian
  t "a session that would send Claude Code's own analytics is named on stderr" 'grep -q "would send Claude Code.s own analytics" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=no_analytics_field); run_custodian
  t "a Claude Code that does not say whether analytics are off is not refused for it" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=limit); run_custodian
  t "a usage limit is said in so many words, with Claude Code's own first line" \
    'grep -q "batch global: the account has reached its usage limit, so wait for it to reset and audit again (Claude Code said: You have hit your limit. It resets at 3pm.)" "$ERR" && ! grep -q "second line" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=logged_out); run_custodian
  t "a session that turns out to be logged out says so" 'grep -q "the account is not logged in (Claude Code said: Not logged in" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=api_error); run_custodian
  t "any other error carries Claude Code's own words" 'grep -q "the session ended in an error (Claude Code said: API Error: overloaded)" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=exit1); run_custodian
  t "a session that dies without a result says how it exited and what it last printed" 'grep -q "claude exited with status 1: boom" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=init_old); run_custodian
  t "a session on a Claude Code older than the seal needs is named on stderr" 'grep -q "the session ran on Claude Code 2.1.294, older than 2.1.295" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=no_version); run_custodian
  t "an init event with no version says so" 'grep -q "does not report its version" "$ERR"' "stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=no_key_source); run_custodian
  t "an init event that does not say where its key came from says so" 'grep -q "does not report where its key came from" "$ERR"' "stderr=$(cat "$ERR")"

  judging_estate; seed_stale; cfg_set '.timeout_seconds = 300'
  EXTRA_ENV=(FAKE_MODE=init_bash FAKE_HANG_AFTER_INIT=1); started=$SECONDS; run_custodian
  t "a broken seal stops the session at its first event, long before the timeout" \
    '[ "$rc" = 3 ] && [ $((SECONDS - started)) -lt 15 ] && grep -q "wider than Read, Glob, Grep: Bash" "$ERR"' "rc=$rc seconds=$((SECONDS - started)) stderr=$(cat "$ERR")"
  t "the stopped session is gone, the old report stands and the evidence is kept" \
    'gone "$(cat "$LOG/1/pid")" && untouched "audit.json failed " && [ -s "$OUTDIR/failed/stream.jsonl" ] && [ -s "$OUTDIR/failed/prompt.md" ]' "dir=$(ls -A "$OUTDIR" | tr "\n" " ")"
  judging_estate; cfg_set '.timeout_seconds = 300'
  EXTRA_ENV=(FAKE_MODE=init_key FAKE_HANG_AFTER_INIT=1); started=$SECONDS; run_custodian
  t "a session that reports a key is stopped at its first event too" \
    '[ "$rc" = 3 ] && [ $((SECONDS - started)) -lt 15 ] && grep -q "used a key (ANTHROPIC_API_KEY)" "$ERR" && gone "$(cat "$LOG/1/pid")"' "rc=$rc seconds=$((SECONDS - started)) stderr=$(cat "$ERR")"
  judging_estate; cfg_set '.timeout_seconds = 2'; EXTRA_ENV=(FAKE_HANG_AFTER_INIT=1); run_custodian
  t "a sealed session that then hangs still times out" '[ "$rc" = 3 ] && grep -q "timed out after 2s" "$ERR" && gone "$(cat "$LOG/1/pid")"' "rc=$rc stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=slow_start); run_custodian
  t "a session that is slow to start is waited for" '[ "$rc" = 0 ] && [ -f "$OUT" ]' "rc=$rc stderr=$(cat "$ERR")"

  std_estate; seed_stale; EXTRA_ENV=(FAKE_MODE_AT_2=exit1); run_custodian
  t "a later batch failing fails the run" '[ "$rc" = 3 ] && untouched "audit.json failed "' "rc=$rc"
  t "the run stops at the first failing batch" '[ "$(ls "$LOG" | wc -l | tr -d " ")" = 2 ]' "invocations=$(ls "$LOG" | wc -l)"
  t "the failing batch is named" 'grep -q "acme" "$ERR" && grep -q "acme" "$OUTDIR/failed/reason.txt"' "stderr=$(cat "$ERR")"

  judging_estate; seed_stale; with_findings "$(finding 4 "Always deploy to the production cluster on Fridays" fail client)"; run_custodian
  t "a rejected response leaves the old report and keeps the evidence" '[ "$rc" = 4 ] && untouched "audit.json failed " && [ -s "$OUTDIR/failed/stream.jsonl" ]' "rc=$rc"
  t "the failed folder and everything in it are private" '[ "$(stat -f %Lp "$OUTDIR/failed")" = 700 ] && [ -z "$(find "$OUTDIR/failed" -type f -not -perm 600)" ]' "modes=$(stat -f "%Lp %N" "$OUTDIR/failed"/* | tr "\n" " ")"
}

expect_preflight() {
  local name=$1 needle=$2
  t "$name is exit 2 and invokes nothing" '[ "$rc" = 2 ] && [ -z "$(ls -A "$LOG")" ] && grep -qi -- "$needle" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
}

preflight() {
  judging_estate; printf '{ not json' > "$CFG"; run_custodian; expect_preflight "invalid JSON" "not valid JSON"
  judging_estate; cfg_set '.tiers[0].tier = "galaxy"'; run_custodian; expect_preflight "an unknown tier" "galaxy"
  judging_estate; cfg_set '.slot = {"acme": "~/.claude-acme"}'; run_custodian; expect_preflight "an unknown top-level key" "unknown config key: slot"
  judging_estate; cfg_set '.tiers[1].scop = "acme"'; run_custodian; expect_preflight "an unknown tier key" "scop"
  judging_estate; cfg_set '.tiers[1].scope = "global"'; run_custodian; expect_preflight "a reserved scope name" "scope"
  judging_estate; cfg_set '.tiers[1].scope = "Acme Corp"'; run_custodian; expect_preflight "a malformed scope name" "scope"
  judging_estate; cfg_set 'del(.tiers[1].scope)'; run_custodian; expect_preflight "a client root without a scope" "scope"
  judging_estate; cfg_set '.tiers[1].scope = "acme\n"'; run_custodian; expect_preflight "a scope that ends in a line break" "needs a scope"
  judging_estate; cfg_set '.tiers[1].scope = "?\nacme"'; run_custodian; expect_preflight "a scope with a good second line" "needs a scope"
  judging_estate; cfg_set '.slots = {"globex": "~/.claude-globex"}'; run_custodian; expect_preflight "a slot for an unknown scope" "globex"
  judging_estate; cfg_set '.slots = {"acme": "~/.claude-acme"}'; run_custodian; expect_preflight "a slot directory that does not exist" "claude-acme"
  judging_estate; cfg_set 'del(.output)'; run_custodian
  t "a missing output defaults to a report beside the config" '[ "$rc" = 0 ] && [ -f "$WORLD/audit.json" ] && [ ! -e "$OUT" ]' "rc=$rc"
  judging_estate; cfg_set '.tiers = []'; run_custodian; expect_preflight "an empty tiers list" "tiers"
  judging_estate; cfg_set '.timeout_seconds = "soon"'; run_custodian; expect_preflight "a non-numeric timeout" "timeout_seconds"
  judging_estate; cfg_set '.tiers += [{"tier": "project", "glob": "~/x/*", "path": "~/y"}]'; run_custodian; expect_preflight "a project root with both glob and path" "glob"
  judging_estate; run_custodian --frobnicate; expect_preflight "an unknown argument" "frobnicate"
  judging_estate; cfg_set '.output = "audit.json"'; run_custodian; expect_preflight "a relative output path" "output must be an absolute path"
  judging_estate; cfg_set '.tiers[0].path = "store"'; run_custodian; expect_preflight "a relative root path" "tiers\[0\].*absolute path"
  judging_estate; cfg_set '.exclude = ["vendored"]'; run_custodian; expect_preflight "a relative exclude prefix" "exclude"

  judging_estate; rm "$FAKE_HOME/store/custodian.examples.md"; run_custodian; expect_preflight "a missing examples file" "custodian.examples.md"
  judging_estate; examples_stub; run_custodian; expect_preflight "the unfilled examples stub" "Correctly global"
  judging_estate
  grep -v "GLOBEX-1234" "$FAKE_HOME/store/custodian.examples.md" > "$WORLD/ex" && mv "$WORLD/ex" "$FAKE_HOME/store/custodian.examples.md"
  run_custodian; expect_preflight "too few leakage examples" "Leakage"
  judging_estate
  grep -v "acme-release" "$FAKE_HOME/store/custodian.examples.md" > "$WORLD/ex" && mv "$WORLD/ex" "$FAKE_HOME/store/custodian.examples.md"
  run_custodian; expect_preflight "no group example where the config has a group" "Correctly client-tier"
  cfg_set '.tiers |= map(select(.tier != "client"))'; run_custodian
  t "a config with no group needs no group example" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  judging_estate; examples_stub; run_custodian --dry-run
  t "a dry run only warns about unfilled examples" '[ "$rc" = 0 ] && grep -qi "examples" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  judging_estate; rm "$BIN/check-jsonschema"; run_custodian; expect_preflight "a missing validator" "brew install check-jsonschema"

  judging_estate; EXTRA_ENV=(FAKE_VERSION=2.1.294); run_custodian
  expect_preflight "a Claude Code older than the seal needs" "Claude Code 2.1.294 is older than 2.1.295.*claude update"
  judging_estate; EXTRA_ENV=(FAKE_VERSION=2.0.999); run_custodian; expect_preflight "an older minor version, whatever its patch" "older than 2.1.295"
  judging_estate; EXTRA_ENV=(FAKE_VERSION=nonsense); run_custodian; expect_preflight "a version that cannot be read" "version could not be read"
  local ver; for ver in 2.1.295 2.1.1000 2.2.0 3.0.0; do
    judging_estate; EXTRA_ENV=("FAKE_VERSION=$ver"); run_custodian
    t "Claude Code $ver is new enough" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  done
  judging_estate; EXTRA_ENV=(FAKE_VERSION=2.1.294); run_custodian --dry-run
  t "a dry run does not ask the version" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
}

data_folder_defaults() {
  new_world
  mk "$FAKE_HOME/store/CLAUDE.md" "global rules"
  mkdir -p "$FAKE_HOME/.custodian"
  CFG="$FAKE_HOME/.custodian/config.json"
  config <<'EOF'
{ "tiers": [ { "tier": "global", "path": "~/store" } ], "editor_url": "zed://file/{path}:{line}" }
EOF
  run_custodian
  t "a config without examples beside it says where they belong" '[ "$rc" = 2 ] && grep -q "\.custodian/examples.md" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  examples_stub; mv "$FAKE_HOME/store/custodian.examples.md" "$FAKE_HOME/.custodian/examples.md"; run_custodian
  t "an unfilled examples file is named as the file it is" '[ "$rc" = 2 ] && grep -q "custodian: examples.md needs at least 3 list items" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  examples_ok; mv "$FAKE_HOME/store/custodian.examples.md" "$FAKE_HOME/.custodian/examples.md"
  run_custodian
  t "output and canonical_store default to the config's own folder" '[ "$rc" = 0 ] && [ -f "$FAKE_HOME/.custodian/audit.json" ] && [ ! -e "$OUT" ]' "rc=$rc stderr=$(cat "$ERR")"
  t "the summary line names the defaulted report" 'grep -q "~/.custodian/audit.json" "$STDOUT"' "stdout=$(cat "$STDOUT")"
  judging_estate; cfg_set '.editor_url = 7'; run_custodian; expect_preflight "a non-text editor_url" "editor_url"
  judging_estate; cfg_set '.stale_after_days = 0'; run_custodian; expect_preflight "a backstop under one day" "whole number of days"
  judging_estate; cfg_set '.stale_after_days = 2.5'; run_custodian; expect_preflight "a backstop that is not a whole number" "whole number of days"
  judging_estate; cfg_set '.remind = "no"'; run_custodian; expect_preflight "a remind that is not true or false" "remind must be true or false"
  judging_estate; cfg_set '.remind = false | .stale_after_days = 14'; run_custodian
  t "remind and stale_after_days are accepted" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  judging_estate; cfg_set '.editor_url = "javascript:alert({path})"'; run_custodian; expect_preflight "an editor_url that would run script" "editor_url"
  judging_estate; cfg_set '.editor_url = "https://example.com/open?f={path}"'; run_custodian; expect_preflight "an editor_url that would send a path to a website" "editor_url"
  judging_estate; cfg_set '.editor_url = "zed://file/somewhere"'; run_custodian; expect_preflight "an editor_url with nowhere to put the path" "{path}"
}

output_and_locking() {
  judging_estate; run_custodian
  t "the report and the folder the runner made are private" '[ "$(stat -f %Lp "$OUT")" = 600 ] && [ "$(stat -f %Lp "$OUTDIR")" = 700 ]' "file=$(stat -f %Lp "$OUT") dir=$(stat -f %Lp "$OUTDIR")"
  judging_estate; mkdir -p "$OUTDIR"; chmod 755 "$OUTDIR"; run_custodian
  t "an output folder that already existed keeps its mode" '[ "$(stat -f %Lp "$OUTDIR")" = 755 ] && [ "$(stat -f %Lp "$OUT")" = 600 ]'

  judging_estate; EXTRA_ENV=(FAKE_MODE=exit1); run_custodian; EXTRA_ENV=(); run_custodian
  t "a successful run removes the failed folder" '[ "$rc" = 0 ] && [ "$(ls -A "$OUTDIR" | tr "\n" " ")" = "audit.json " ]' "dir=$(ls -A "$OUTDIR" | tr "\n" " ")"

  judging_estate; mkdir -p "$OUTDIR/failed"; echo mine > "$OUTDIR/failed/keep.txt"; run_custodian
  t "a successful run leaves alone a failed folder that is not its own" '[ "$rc" = 0 ] && [ -f "$OUT" ] && [ "$(cat "$OUTDIR/failed/keep.txt" 2>&1)" = mine ]' "rc=$rc dir=$(ls -A "$OUTDIR" | tr "\n" " ")"
  judging_estate; mkdir -p "$OUTDIR/failed"; echo mine > "$OUTDIR/failed/keep.txt"; EXTRA_ENV=(FAKE_MODE=exit1); run_custodian
  t "a failing run leaves it alone too, and says the evidence was not kept" \
    '[ "$rc" = 3 ] && [ "$(cat "$OUTDIR/failed/keep.txt" 2>&1)" = mine ] && [ "$(ls "$OUTDIR/failed" | tr "\n" " ")" = "keep.txt " ] && grep -q "the evidence was not kept, because ~/Developer/.custodian/failed is not a folder Custodian made" "$ERR"' \
    "rc=$rc dir=$(ls -A "$OUTDIR/failed" 2>&1 | tr "\n" " ") stderr=$(cat "$ERR")"
  judging_estate; mkdir -p "$OUTDIR/failed"; echo mine > "$OUTDIR/failed/mine.txt"; chmod 000 "$OUTDIR/failed"; EXTRA_ENV=(FAKE_MODE=exit1); run_custodian
  t "a failed folder that cannot be read is not taken for an empty one" \
    '[ "$rc" = 3 ] && grep -q "the evidence was not kept" "$ERR" && [ "$(stat -f %Lp "$OUTDIR/failed")" = 0 ]' "rc=$rc mode=$(stat -f %Lp "$OUTDIR/failed") stderr=$(cat "$ERR")"
  EXTRA_ENV=(); run_custodian; chmod 700 "$OUTDIR/failed"
  t "nor is it deleted by the next good run" '[ "$rc" = 0 ] && [ "$(ls -A "$OUTDIR/failed" | tr "\n" " ")" = "mine.txt " ]' "rc=$rc dir=$(ls -A "$OUTDIR/failed" 2>&1 | tr "\n" " ")"
  judging_estate; mkdir -p "$OUTDIR/failed"; EXTRA_ENV=(FAKE_MODE=exit1); run_custodian
  t "an empty failed folder is taken for the evidence" '[ "$rc" = 3 ] && [ -s "$OUTDIR/failed/reason.txt" ] && grep -q "kept in ~/Developer/.custodian/failed" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  judging_estate; mkdir -p "$OUTDIR/.custodian.lock"; echo $$ > "$OUTDIR/.custodian.lock/pid"; run_custodian
  t "a live lock is exit 2 without invoking anything" '[ "$rc" = 2 ] && [ -z "$(ls -A "$LOG")" ] && grep -qi "another run" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  t "a refused run leaves the other run's lock alone" '[ -d "$OUTDIR/.custodian.lock" ]'

  judging_estate; mkdir -p "$OUTDIR/.custodian.lock"
  sleep 0 & local dead=$!; wait "$dead"; echo "$dead" > "$OUTDIR/.custodian.lock/pid"; run_custodian
  t "a lock whose pid is dead is taken over" '[ "$rc" = 0 ] && [ -f "$OUT" ] && [ ! -e "$OUTDIR/.custodian.lock" ]' "rc=$rc stderr=$(cat "$ERR")"

  judging_estate; mkdir -p "$OUTDIR/.custodian.lock"
  printf '%s\n%s\n' "$$" "$(LC_ALL=C ps -o lstart= -p $$)" > "$OUTDIR/.custodian.lock/pid"; run_custodian
  t "a lock whose pid and start time are a live process's is respected" '[ "$rc" = 2 ] && [ -z "$(ls -A "$LOG")" ] && grep -qi "another run" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  judging_estate; mkdir -p "$OUTDIR/.custodian.lock"
  printf '%s\n%s\n' "$$" "Thu Jan  1 00:00:00 1970" > "$OUTDIR/.custodian.lock/pid"; run_custodian
  t "a lock whose pid now belongs to a process started at another time is taken over" '[ "$rc" = 0 ] && [ -f "$OUT" ] && [ ! -e "$OUTDIR/.custodian.lock" ]' "rc=$rc stderr=$(cat "$ERR")"
  judging_estate; EXTRA_ENV=(FAKE_MODE=hang); cfg_set '.timeout_seconds = 3'
  fake_settings FAKE_MODE=hang
  ( cd "$WORLD/cwd" && env -i HOME="$FAKE_HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$TMPD" "$RUN" --config "$CFG" >/dev/null 2>&1 ) &
  local held=$! n=0
  until [ -s "$OUTDIR/.custodian.lock/pid" ] || [ "$n" -ge 100 ]; do sleep 0.1; n=$((n+1)); done
  t "a run records its pid and when it started" '[ "$(wc -l < "$OUTDIR/.custodian.lock/pid" | tr -d " ")" = 2 ] && [ "$(sed -n 2p "$OUTDIR/.custodian.lock/pid")" = "$(LC_ALL=C ps -o lstart= -p "$(sed -n 1p "$OUTDIR/.custodian.lock/pid")" | sed "s/ *$//")" ]' "lock=$(cat "$OUTDIR/.custodian.lock/pid" 2>&1)"
  wait "$held"

  judging_estate; run_custodian --dry-run
  t "a dry run creates nothing beside the output" '[ ! -e "$OUTDIR" ]'
}


signals() {
  judging_estate
  cfg_set '.timeout_seconds = 7777'
  fake_settings FAKE_MODE=hang
  env -i HOME="$FAKE_HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$TMPD" "$RUN" --config "$CFG" >"$STDOUT" 2>"$ERR" &
  local runner=$! n=0
  until [ -s "$LOG/1/pid" ] || [ "$n" -ge 100 ]; do sleep 0.1; n=$((n+1)); done
  kill -TERM "$runner"; wait "$runner"; rc=$?
  t "termination exits 143" '[ "$rc" = 143 ]' "rc=$rc"
  t "termination kills the agent" 'gone "$(cat "$LOG/1/pid")"'
  t "termination cleans up and releases the lock" '[ -z "$(ls -A "$TMPD")" ] && [ ! -e "$OUTDIR/.custodian.lock" ]' "tmp=$(ls -A "$TMPD")"
  n=0; while pgrep -f "sleep 7777" >/dev/null && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n+1)); done
  t "termination leaves no watchdog behind" '! pgrep -f "sleep 7777" >/dev/null'
  pkill -f "sleep 7777" 2>/dev/null
}

live_check() {
  local ESTATE="$SANDBOX/live" report
  report="$ESTATE/out/audit.json"
  mk "$ESTATE/store/CLAUDE.md" '# Working rules

## Commits
- Write commit subjects in the imperative mood.
- Keep each commit to one logical change.

## Code
- Prefer early returns over nested conditionals.
- Delete dead code instead of commenting it out.

## Before a pull request
- Run the test suite and the linter locally.
- Always run the staging smoke test against acme-staging.internal before opening a PR.
'
  mk "$ESTATE/store/skills/commit-style/SKILL.md" '---
name: commit-style
description: Writes commit messages in the imperative mood with a short subject and a body that explains why.
---
Write the subject in the imperative mood, under 60 characters. Explain why in the body.
'
  mk "$ESTATE/store/skills/acme-release/SKILL.md" '---
name: acme-release
description: Walks a release through the acme change board, which meets on Tuesdays and needs a CHG ticket in the ACME Jira project.
---
1. Open a CHG ticket in the ACME Jira project.
2. Ask the acme change board for approval in #acme-releases.
3. Tag the release and wait for the Argo sync on the acme production cluster.
'
  mk "$ESTATE/store/rules/deploys.md" '# Deploys

- Tag a release only from a clean main branch.
- Wait for the Argo sync on the acme production cluster before closing the CHG ticket.
'
  mk "$ESTATE/store/rules/testing.md" '# Testing

- Run the test suite before pushing.
- Name a test after the behaviour it checks.
'
  mk "$ESTATE/clients/acme/CLAUDE.md" '# acme

- Tickets live in the ACME Jira project and branch names start with the ticket key.
- Deploys go through the acme change board.
'
  mk "$ESTATE/clients/acme/web/.claude/rules/commits.md" '---
paths:
  - "src/**/*.ts"
---
# Commits in the web app

- Write commit subjects in the imperative mood.
'
  mk "$ESTATE/clients/acme/web/CLAUDE.md" '# acme web

- The checkout flow talks to the acme payments gateway through src/gateway.
- Feature flags live in config/flags.acme.yaml.
- Write commit subjects in the imperative mood.
'
  printf 'Habits: @notes/habits.md\nReleases: @%s/clients/acme/notes/release.md\n' "$ESTATE" >> "$ESTATE/store/CLAUDE.md"
  mk "$ESTATE/store/notes/habits.md" '# Habits

- Read the failing test before changing the code.
- Keep a change small enough to review in one sitting.
'
  mk "$ESTATE/clients/acme/notes/release.md" '# Releases

- Every acme release waits for a CHG ticket from the acme change board.
- Roll back through the acme Argo project, never by hand.
'
  mk "$ESTATE/store/commands/tidy.md" '---
description: Tidy the working tree before a commit
---
Remove stray debug output and run the formatter.
'
  mk "$ESTATE/store/commands/acme-deploy.md" '---
description: Deploy to acme staging through the acme change board
---
Open a CHG ticket, then sync the acme-staging Argo application.
'
  mk "$ESTATE/clients/CLAUDE.md" '# Client work

- Staging for every client is reached through acme-staging.internal.
'
  mk "$ESTATE/clients/CLAUDE.local.md" '# Mine

- Ask before force-pushing a shared branch.
'
  mk "$ESTATE/clients/globex/CLAUDE.md" '# Globex

- Globex services are written in Go and deployed by the globex platform team.
'
  local hub="$ESTATE/clients/globex/site/.claude/rules/context-map.md" block_from block_to
  mk "$hub" '# Globex site

The context map for the globex-site estate. This file routes a task to the notes that cover it. Status belongs in state files, not here.

## Where a task goes

| Repo | Role |
|---|---|
| [`site`](../../.context-central/repos/site.md) | the Globex storefront, deployed by the globex platform team |

## Write rules

- Nothing reaches the storefront main branch without a review from the globex platform team.

<!-- context-central:start -->
## The parts of the map

- `.context-central/repos/`: one note per repo: what it is, its traps, how to work in it.
- `.context-central/areas/`: one corner of a repo, in depth.
- `.context-central/concepts/`: the ideas the estate relies on, one per note.
- `.context-central/decisions/`: numbered records of what was decided and why.
- `.context-central/log/`: dated notes, one file a month.
- `.context-central/work/<item>/STATE.md`: where a piece of work stands and what is next. Files that are not text sit in `evidence/` beside it.
- `.context-central/glossary.md`: the estate'"'"'s terms.

`context-central resolve <item or words>` lists the notes behind a task. A work item'"'"'s name or title always answers. Other words answer when they single out one item or note; otherwise it says there is no confident match.
<!-- context-central:end -->
'
  block_from=$(grep -n "context-central:start" "$hub" | cut -d: -f1); block_to=$(grep -n "context-central:end" "$hub" | cut -d: -f1)
  FAKE_HOME="$ESTATE"; examples_ok
  cat > "$ESTATE/config.json" <<EOF
{ "canonical_store": "$ESTATE/store",
  "tiers": [ { "tier": "global", "path": "$ESTATE/store" },
             { "tier": "client", "path": "$ESTATE/clients/acme", "scope": "acme" },
             { "tier": "client", "path": "$ESTATE/clients/globex", "scope": "globex" },
             { "tier": "project", "glob": "$ESTATE/clients/*/*/CLAUDE.md" },
             { "tier": "project", "glob": "$ESTATE/clients/*/*/.claude" } ],
  "output": "$report" }
EOF
  cp "$ESTATE/store/custodian.examples.md" "$ESTATE/builtin.examples.md"
  cp "${CUSTODIAN_HOME:-$HOME/.custodian}/examples.md" "$ESTATE/store/custodian.examples.md" 2>/dev/null || true
  if "$RUN" --config "$ESTATE/config.json" --dry-run 2>&1 >/dev/null | grep -q "examples are not ready"; then
    cp "$ESTATE/builtin.examples.md" "$ESTATE/store/custodian.examples.md"
    echo "--- live taste check: your examples file is still a stub, so the built-in examples stand in"
  else
    echo "--- live taste check: judging with your own custodian.examples.md"
  fi
  echo "--- real claude, fictional estate, personal slot"
  "$RUN" --config "$ESTATE/config.json"; rc=$?
  t "the live run exits 0" '[ "$rc" = 0 ]' "rc=$rc"
  [ -f "$report" ] || return
  jq -r '.items[] | "     \(.verdict)\t\(.id)\t\(.rationale)", (.findings[] | "       line \(.line) \(.verdict): \(.rationale)")' "$report"
  jqt "the seeded staging host is a fail at its line" "$report" '.items[] | select(.id == "global/CLAUDE.md") | .verdict == "fail" and any(.findings[]; .line == 13 and .verdict == "fail")'
  jqt "the acme skill sitting in global is a fail" "$report" '.items[] | select(.id == "global/skills/acme-release") | .verdict == "fail"'
  jqt "the project line restating the global file is a warn" "$report" '.items[] | select(.id == "acme/web/CLAUDE.md") | any(.findings[]; .line == 5 and .verdict == "warn")'
  jqt "the clean generic skill passes" "$report" '.items[] | select(.id == "global/skills/commit-style") | .verdict == "pass"'
  jqt "the global rule file naming an acme system is a fail at its line" "$report" '.items[] | select(.id == "global/rules/deploys") | .verdict == "fail" and any(.findings[]; .line == 4 and .verdict == "fail")'
  jqt "the clean global rule file passes" "$report" '.items[] | select(.id == "global/rules/testing") | .verdict == "pass"'
  jqt "a repo rule file restating the global file is a warn at its line, frontmatter and all" "$report" '.items[] | select(.id == "acme/web/.claude/rules/commits") | any(.findings[]; .line == 7 and .verdict == "warn")'
  jqt "a group's notes imported by the global file are a fail, as global" "$report" '.items[] | select(.id == "acme/notes/release.md") | .kind == "import" and .tier == "global" and .verdict == "fail"'
  jqt "the clean imported notes pass" "$report" '.items[] | select(.id == "global/notes/habits.md") | .kind == "import" and .verdict == "pass"'
  jqt "the user-level command naming an acme system is a fail" "$report" '.items[] | select(.id == "global/commands/acme-deploy") | .verdict == "fail"'
  jqt "the clean user-level command passes" "$report" '.items[] | select(.id == "global/commands/tidy") | .verdict == "pass"'
  jqt "the file above both groups that names one group's host is a fail, as global" "$report" ".items[] | select(.path == \"$ESTATE/clients/CLAUDE.md\") | .tier == \"global\" and .verdict == \"fail\" and (.above | length) >= 2"
  jqt "the clean file above both groups passes" "$report" ".items[] | select(.path == \"$ESTATE/clients/CLAUDE.local.md\") | .verdict == \"pass\""
  jqt "a hub kept as a rule file in a repo with no CLAUDE.md is found and judged" "$report" '[.items[] | select(.id == "globex/site/.claude/rules/context-map") | .kind] == ["rule"]'
  jqt "the block context-central writes into a hub draws no finding" "$report" \
    '[.items[] | select(.id == "globex/site/.claude/rules/context-map") | .findings[] | select(.line >= $from and .line <= $to)] == []' --argjson from "$block_from" --argjson to "$block_to"
  jqt "the report says what the run used" "$report" '.usage | (.input_tokens > 0) and (.output_tokens > 0) and (.seconds > 0)'
}

loading_check() {
  local ESTATE="$SANDBOX/loaded" home conf folder name pid waited
  home="$ESTATE/home"; conf="$home/.claude"
  if ! command -v claude >/dev/null 2>&1; then t "the real claude is on PATH" 'false' "the loading check asks Claude Code itself"; return; fi
  mk "$conf/CLAUDE.md" '# Global

- Prefer early returns.
Notes: @notes/shared.md
The team: @~/Developer/acme/notes/team.md
'
  mk "$conf/notes/shared.md" 'Shared notes, then @deeper.md
'
  mk "$conf/notes/deeper.md" 'Deeper notes.
'
  mk "$conf/rules/tidy.md" 'Keep changes small.
'
  mk "$conf/commands/deploy.md" 'Ship the current branch.
'
  local n
  for n in front quotefence listfence spantwo htmlblock preblock tabcode listcode quotecode refdef tilde crlfcode; do mk "$conf/notes/skip-$n.md" "a note no session loads: $n
"; done
  mk "$conf/notes/skip-dot." 'a name that ends in a dot
'
  mk "$conf/notes/crlf.md" 'imported from a file with Windows line endings
'
  mk "$conf/notes/spanned.md" 'after a comment mark inside a code span
'
  printf -- '---\ndescription: see @../notes/skip-front.md here\n---\n> ```\n> @../notes/skip-quotefence.md\n> ```\n- ```\n  @../notes/skip-listfence.md\n  ```\ntext `code\n@../notes/skip-spantwo.md more` end\n\n<div>\n@../notes/skip-htmlblock.md\n</div>\n\n<pre>\n\n@../notes/skip-preblock.md\n</pre>\n\n  \t@../notes/skip-tabcode.md\n\n    - @../notes/skip-listcode.md\n\n>     @../notes/skip-quotecode.md\n\n[l]: @../notes/skip-refdef.md\n~~~\n@../notes/skip-tilde.md\n~~~\nA dot @../notes/skip-dot.\nA span `<!--` then @../notes/spanned.md here\n' > "$conf/rules/shapes.md"
  printf 'intro\r\n@../notes/crlf.md\r\n\r\n    @../notes/skip-crlfcode.md\r\n' > "$conf/rules/windows.md"
  mk "$home/Developer/CLAUDE.md" 'Above both groups.
'
  mk "$home/Developer/.claude/rules/shared.md" 'A rule above both groups.
'
  mk "$home/Developer/outside.md" 'Outside the web repo.
'
  mk "$home/Developer/acme/CLAUDE.md" 'acme rules
@notes/local.md
'
  mk "$home/Developer/acme/notes/team.md" 'The acme team.
'
  mk "$home/Developer/acme/notes/local.md" 'Notes the group imports.
'
  mk "$home/Developer/acme/.claude/rules/api.md" 'acme api rules
'
  mk "$home/Developer/acme/.claude/rules/scoped.md" '---
paths:
  - "src/**"
---
Only for the sources.
'
  mk "$home/Developer/acme/web/CLAUDE.md" 'web rules
@README.md
@../../outside.md
'
  mk "$home/Developer/acme/web/README.md" '# web
'
  mk "$home/Developer/acme/web/.claude/rules/routes.md" 'web route rules
'
  mk "$home/Developer/globex/CLAUDE.md" 'globex rules
'
  mk "$home/Developer/globex/api/CLAUDE.md" 'api rules
'
  jq -n --arg out "$ESTATE/loaded" '{hooks: {InstructionsLoaded: [{hooks: [{type: "command", command: "/bin/cat >> \"$LOADED_OUT\"; /bin/echo >> \"$LOADED_OUT\""}]}]}}' > "$conf/settings.json"
  FAKE_HOME="$ESTATE"; examples_ok
  cat > "$ESTATE/config.json" <<EOF
{ "canonical_store": "$ESTATE/store",
  "tiers": [ { "tier": "global", "path": "$conf" },
             { "tier": "client", "path": "$home/Developer/acme", "scope": "acme" },
             { "tier": "client", "path": "$home/Developer/globex", "scope": "globex" },
             { "tier": "project", "glob": "$home/Developer/*/*/CLAUDE.md" } ],
  "output": "$ESTATE/out/audit.json" }
EOF
  HOME="$home" "$RUN" --config "$ESTATE/config.json" --dry-run > "$ESTATE/manifest.json" 2> "$ESTATE/dry.err"; rc=$?
  t "the dry run of the invented estate lists cleanly" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ESTATE/dry.err")"
  mkdir -p "$ESTATE/loaded" "$ESTATE/streams"; printf 'ok\n' > "$ESTATE/prompt.txt"
  echo "--- real claude, invented estate, no login: nothing is spent"
  for folder in Developer/acme Developer/acme/web Developer/globex Developer/globex/api; do
    name=${folder//\//-}
    ( cd "$home/$folder" && exec env -i HOME="$home" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" CLAUDE_CONFIG_DIR="$conf" LOADED_OUT="$ESTATE/loaded/$name.jsonl" \
        claude -p --output-format stream-json --verbose --no-session-persistence < "$ESTATE/prompt.txt" > "$ESTATE/streams/$name.jsonl" 2> "$ESTATE/streams/$name.err" ) &
    pid=$!; waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 60 ]; do sleep 1; waited=$((waited+1)); done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; t "the session in $folder ends within a minute" 'false'; return; fi
    if ! jq -e -s 'any(.[]; .type == "result" and (.total_cost_usd // 0) == 0 and ((.result // "") | test("Not logged in")))' "$ESTATE/streams/$name.jsonl" >/dev/null 2>&1; then
      t "the session in $folder is refused for want of a login, at no cost" 'false' "nothing was compared: $(tail -c 300 "$ESTATE/streams/$name.jsonl")"; return
    fi
    if [ ! -s "$ESTATE/loaded/$name.jsonl" ]; then t "Claude Code says which files the session in $folder loaded" 'false' "its InstructionsLoaded hook wrote nothing"; return; fi
  done
  t "every session was refused for want of a login, at no cost" 'true'
  for name in Developer-acme Developer-acme-web Developer-globex Developer-globex-api; do
    jq -s --arg name "$name" '{($name): ([.[] | objects | .file_path] | unique)}' "$ESTATE/loaded/$name.jsonl"
  done | jq -s 'add' > "$ESTATE/loaded.json"
  jq --slurpfile loaded "$ESTATE/loaded.json" --arg home "$home" '
    ([.batches[].judge[] | select(.kind == "claude_md" or .kind == "rule" or .kind == "import")]) as $listed
    | ($loaded[0] | [.[][]] | unique) as $seen
    | [$home + "/Developer/acme/.claude/rules/scoped.md", $home + "/Developer/outside.md"] as $known
    | { unlisted: ($seen - [$listed[].path]),
        unloaded: ([$listed[].path] - $seen - $known),
        known_listed: ($known - [$listed[].path]),
        known_loaded: [$known[] | select(IN($seen[]))],
        across: [ $listed[] | . as $item
                  | select(($loaded[0]["Developer-acme"] + $loaded[0]["Developer-acme-web"] | index($item.path)) != null
                           and ($loaded[0]["Developer-globex"] + $loaded[0]["Developer-globex-api"] | index($item.path)) != null)
                  | select(.tier != "global") | .sits_at ] }' "$ESTATE/manifest.json" > "$ESTATE/compared.json"
  jq -r '"     loaded by Claude Code: \([.[][]] | unique | length) files over \(length) sessions"' "$ESTATE/loaded.json"
  jqt "Claude Code loaded no file the dry run does not list" "$ESTATE/compared.json" '.unlisted == []'
  jqt "the dry run lists no CLAUDE.md, rule file or imported file that no session loaded" "$ESTATE/compared.json" '.unloaded == []'
  jqt "a rule with paths and an import that leaves its project are listed, and Claude Code loads neither at the start" "$ESTATE/compared.json" '.known_listed == [] and .known_loaded == []'
  jqt "a file that the sessions of two groups loaded is global in the dry run" "$ESTATE/compared.json" '.across == []'

  local forms="$ESTATE/forms"
  mkdir -p "$forms/home" "$forms/cwd"; forms_into "$forms/config"
  cp "$conf/settings.json" "$forms/config/settings.json"
  cat > "$forms/config.json" <<EOF
{ "canonical_store": "$ESTATE/store", "tiers": [ { "tier": "global", "path": "$forms/config" } ], "output": "$forms/out/audit.json" }
EOF
  HOME="$forms/home" "$RUN" --config "$forms/config.json" --dry-run > "$forms/manifest.json" 2> "$forms/dry.err"; rc=$?
  t "the dry run over every recorded form of import lists cleanly" '[ "$rc" = 0 ]' "rc=$rc stderr=$(tail -3 "$forms/dry.err")"
  ( cd "$forms/cwd" && exec env -i HOME="$forms/home" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" CLAUDE_CONFIG_DIR="$forms/config" LOADED_OUT="$forms/loaded.jsonl" \
      claude -p --output-format stream-json --verbose --no-session-persistence < "$ESTATE/prompt.txt" > "$forms/stream.jsonl" 2> "$forms/stream.err" ) &
  pid=$!; waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 60 ]; do sleep 1; waited=$((waited+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; t "the session over the forms ends within a minute" 'false'; return; fi
  if ! jq -e -s 'any(.[]; .type == "result" and (.total_cost_usd // 0) == 0 and ((.result // "") | test("Not logged in")))' "$forms/stream.jsonl" >/dev/null 2>&1 || [ ! -s "$forms/loaded.jsonl" ]; then
    t "the session over the forms is refused for want of a login, and says what it loaded" 'false' "nothing was compared"; return
  fi
  jq -s "[.[] | objects | select(.load_reason == \"include\") | .file_path | $FORM_OF] | unique" "$forms/loaded.jsonl" > "$forms/loads.json"
  followed_forms "$forms/manifest.json" > "$forms/followed.json"
  jq -r -n --slurpfile loads "$forms/loads.json" --slurpfile followed "$forms/followed.json" --slurpfile forms "$here/import-forms.json" \
    '"     of \($forms[0] | length) forms Claude Code loads \($loads[0] | length) and the dry run follows \($followed[0] | length); \([$forms[0] | to_entries[] | select(.value.loads != (.key | IN($loads[0][])))] | length) differ from what was recorded for Claude Code"'
  t "of every recorded form of import, the dry run follows none that Claude Code does not load" \
    '[ "$(jq -c -n --slurpfile loads "$forms/loads.json" --slurpfile followed "$forms/followed.json" "\$followed[0] - \$loads[0]")" = "[]" ]' \
    "followed and not loaded: $(jq -c -n --slurpfile loads "$forms/loads.json" --slurpfile followed "$forms/followed.json" --slurpfile forms "$here/import-forms.json" '[($followed[0] - $loads[0])[] | $forms[0][.].text]' | cut -c1-600)"
}

if [ "$LIVE" = 1 ]; then
  live_check
fi
if [ "$LOADED" = 1 ]; then
  loading_check
fi

if [ "$LIVE" = 0 ] && [ "$LOADED" = 0 ]; then
  group happy_path
  group discovery
  group rule_files
  group above_roots
  group command_files
  group imports
  group reach_and_home
  group external_across_scopes
  group ids_and_order
  group invocation
  group accounts
  group rendering
  group response_handling
  group generated_blocks
  group quote_verification
  group failure_behaviour
  group preflight
  group data_folder_defaults
  group freshness_facts
  group output_and_locking
  group signals
fi

[ "$LIVE$LOADED" != 00 ] || t "no run wrote into its working directory" '[ -z "$dirtied" ]' "dirtied:$dirtied"

finish
