#!/bin/bash
# Smoke suite for bin/custodian: custodian.smoke.sh [group] drives every subcommand against a fixture data folder.
set -u
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd -P)
CUSTODIAN="$plugin/bin/custodian"
LIVE=0; FILTER=${1:-}
. "$here/helpers.sh"

run_cmd() {
  fake_settings
  ( cd "$WORLD/cwd" && env -i HOME="$FAKE_HOME" CUSTODIAN_HOME="$DATA" PATH="$BIN:/usr/bin:/bin" TMPDIR="$TMPD" FAKE_LOG="$LOG" \
      ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$CUSTODIAN" "$@" >"$STDOUT" 2>"$ERR" )
  rc=$?
  [ -z "$(ls -A "$WORLD/cwd")" ] || dirtied="$dirtied $WORLD"
}

mode() { stat -f %Lp "$1"; }
as_system() { printf '#!/bin/bash\n%s\n' "$1" > "$BIN/uname"; chmod +x "$BIN/uname"; }

data_world() {
  new_world
  DATA="$FAKE_HOME/.custodian"
  mk "$FAKE_HOME/store/CLAUDE.md" "# Global

- Use conventional commits.
- Always run the staging smoke test against acme-staging.internal before opening a PR.
"
  mk "$FAKE_HOME/store/skills/commit-style/SKILL.md" "---
description: Commit conventions for the acme change board
---
Write imperative subjects.
"
  mk "$FAKE_HOME/Developer/acme/CLAUDE.md" "acme rules"
  mk "$FAKE_HOME/Developer/acme/web/CLAUDE.md" "web rules"
  mk "$FAKE_HOME/Developer/Personal/side/CLAUDE.md" "side rules"
  mkdir -p "$DATA"; chmod 700 "$DATA"
  CFG="$DATA/config.json"
  config <<'EOF'
{ "tiers": [ { "tier": "global", "path": "~/store" },
             { "tier": "client", "path": "~/Developer/acme", "scope": "acme" },
             { "tier": "project", "glob": "~/Developer/*/*/CLAUDE.md" } ] }
EOF
  examples_ok; mv "$FAKE_HOME/store/custodian.examples.md" "$DATA/examples.md"
  chmod 600 "$CFG" "$DATA/examples.md"
}

data_folder() {
  new_world; DATA="$FAKE_HOME/elsewhere/custodian-data"
  run_cmd version
  t "version prints the plugin's version" '[ "$rc" = 0 ] && [ "$(cat "$STDOUT")" = "custodian $(jq -r .version "$plugin/.claude-plugin/plugin.json")" ]' "stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  t "the data folder named by CUSTODIAN_HOME is created private on first use" '[ -d "$DATA" ] && [ "$(mode "$DATA")" = 700 ]' "mode=$(mode "$DATA" 2>&1)"
  t "every invocation records where the plugin is installed" '[ "$(cat "$DATA/plugin-root")" = "$plugin" ]' "pointer=$(cat "$DATA/plugin-root" 2>&1)"

  printf '/somewhere/old' > "$DATA/plugin-root"; run_cmd version
  t "a stale pointer is refreshed by the next invocation" '[ "$(cat "$DATA/plugin-root")" = "$plugin" ]' "pointer=$(cat "$DATA/plugin-root")"

  new_world
  ( cd "$WORLD/cwd" && env -i HOME="$FAKE_HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$TMPD" "$CUSTODIAN" version >/dev/null 2>&1 )
  t "without CUSTODIAN_HOME the data folder is ~/.custodian" '[ -d "$FAKE_HOME/.custodian" ]'

  data_world; run_cmd frobnicate
  t "an unknown subcommand is exit 2 with the list of subcommands" '[ "$rc" = 2 ] && grep -q "audit" "$ERR" && grep -q "dashboard" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  new_world; DATA="$FAKE_HOME/.custodian"; run_cmd audit
  t "an audit with no config says to run init" '[ "$rc" = 2 ] && grep -qi "init" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
}

audit_command() {
  data_world; run_cmd dry-run
  t "dry-run prints one line per batch with its account and sizes" \
    '[ "$rc" = 0 ] && grep -Eq "^global +personal account +2 items +0 reference" "$STDOUT" && grep -Eq "^acme +personal account +2 items +1 reference" "$STDOUT" && grep -Eq "^unscoped +personal account +1 items +1 reference" "$STDOUT"' "stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  t "a dry run calls nothing and writes no report" '[ -z "$(ls -A "$LOG")" ] && [ ! -e "$DATA/audit.json" ]'
  data_world; account_folder "$FAKE_HOME/.claude-acme" "$FAKE_HOME/.claude-me"; cfg_set '.slots = {"acme": "~/.claude-acme"} | .default_slot = "~/.claude-me"'; run_cmd dry-run
  t "the table names the account as an audit does, and a group with its own account has no reference files" \
    '[ "$rc" = 0 ] && grep -Eq "^global +personal account at ~/.claude-me +2 items +0 reference" "$STDOUT" && grep -Eq "^acme +account ~/.claude-acme +2 items +0 reference" "$STDOUT" && grep -Eq "^unscoped +personal account at ~/.claude-me +1 items +1 reference" "$STDOUT"' "stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  run_cmd dry-run --json
  jqt "dry-run --json prints the manifest" "$STDOUT" '[.batches[].batch] == ["global", "acme", "unscoped"]'

  data_world; touch "$WORLD/marker"; sleep 1; run_cmd audit; run_cmd dashboard --no-open
  t "an audit and a page write nothing outside the data folder" '[ -z "$(find "$FAKE_HOME" -newer "$WORLD/marker" -type f -not -path "$DATA/*")" ] && [ -z "$(ls -A "$TMPD")" ]' "strays=$(find "$FAKE_HOME" -newer "$WORLD/marker" -type f -not -path "$DATA/*") tmp=$(ls -A "$TMPD")"

  data_world; mkdir -p "$FAKE_HOME/elsewhere"; mv "$DATA/examples.md" "$FAKE_HOME/elsewhere/custodian.examples.md"
  cfg_set '.canonical_store = "~/elsewhere" | .output = "~/elsewhere/out/audit.json"'; run_cmd audit; run_cmd dashboard --no-open
  t "a config that still carries the old keys works through custodian" '[ "$rc" = 0 ] && [ -f "$FAKE_HOME/elsewhere/out/audit.json" ] && [ ! -e "$DATA/audit.json" ] && [ -f "$DATA/dashboard.html" ]' "rc=$rc stderr=$(cat "$ERR")"

  data_world; run_cmd audit
  t "audit runs the runner with the data folder's config" '[ "$rc" = 0 ] && [ -f "$DATA/audit.json" ] && [ "$(mode "$DATA/audit.json")" = 600 ]' "rc=$rc stderr=$(cat "$ERR")"
  t "audit relays the runner's summary line" 'grep -q "5 items" "$STDOUT"' "stdout=$(cat "$STDOUT")"

  data_world; EXTRA_ENV=(FAKE_MODE=exit1); run_cmd audit
  t "audit propagates the runner's exit code" '[ "$rc" = 3 ] && [ ! -e "$DATA/audit.json" ]' "rc=$rc"
}

HOSTILE='Close tags like </script><script>alert(1)</script> and <!-- comments & "quotes" stay text.'

audited_world() {
  data_world
  printf '%s\n' "$HOSTILE" >> "$FAKE_HOME/store/CLAUDE.md"
  mk "$FAKE_HOME/notes/ext.md" "external agent"
  lnk "$FAKE_HOME/notes/ext.md" "$FAKE_HOME/Developer/acme/.claude/agents/ext.md"
  local leak='- Always run the staging smoke test against acme-staging.internal before opening a PR.'
  local filter='.items |= map(
    if .id == "global/CLAUDE.md" then .findings = [
      {line: 4, text: $leak, verdict: "fail", suggested_tier: "client", rationale: "Names the acme staging host."},
      {line: 5, text: $hostile, verdict: "warn", suggested_tier: "project", rationale: "About one codebase."}]
    elif .id == "global/skills/commit-style" then .verdict = "fail" | .suggested_tier = "client" | .evidence = {line: 2, text: "description: Commit conventions for the acme change board"} | .rationale = "Describes the acme change board."
    elif .id == "acme/web/CLAUDE.md" then .findings = [{line: 1, text: "web rules", verdict: "warn", suggested_tier: "global", rationale: "Generic."}]
    else . end)'
  filter=$(jq -rn --arg leak "$leak" --arg hostile "$HOSTILE" --arg f "$filter" '$f | gsub("\\$leak"; ($leak | tojson)) | gsub("\\$hostile"; ($hostile | tojson))')
  EXTRA_ENV=("FAKE_FILTER=$filter")
  run_cmd audit
  EXTRA_ENV=()
}

view() { sed -n 's/.*<script id="custodian-data" type="application\/json">\(.*\)<\/script>.*/\1/p' "$DATA/dashboard.html" > "$WORLD/view.json"; }

dashboard_view() {
  audited_world
  t "the fixture audit succeeds" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd dashboard --no-open; view
  t "dashboard writes one private page into the data folder" '[ "$rc" = 0 ] && [ "$(mode "$DATA/dashboard.html")" = 600 ] && [ -z "$(ls -A "$DATA" | grep "^\.dashboard")" ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "the summary counts items and nothing is acknowledged yet" "$WORLD/view.json" '.summary == {total: 6, pass: 3, warn: 1, fail: 2, acknowledged: 0}'
  jqt "the tree follows home, with counts that include children" "$WORLD/view.json" \
    '[.tree[] | {node, fail, warn, children: [.children[] | {node, fail, warn}]}] == [
       {node: "global", fail: 2, warn: 0, children: []},
       {node: "group:acme", fail: 0, warn: 0, children: [{node: "repo:acme/web", fail: 0, warn: 0}]},
       {node: "standalone", fail: 0, warn: 0, children: [{node: "standalone:side", fail: 0, warn: 0}]},
       {node: "external", fail: 0, warn: 0, children: []}]'
  jqt "leaks come first, then warnings, then passes" "$WORLD/view.json" \
    '[.items[].id] == ["global/CLAUDE.md", "global/skills/commit-style", "acme/web/CLAUDE.md", "acme/CLAUDE.md", "external/~/notes/ext", "project/side/CLAUDE.md"]'
  jqt "a card says where the file lives and who loads it" "$WORLD/view.json" \
    '.items[] | select(.id == "external/~/notes/ext") | .lives_in == "~/notes/ext.md" and .loaded_by == {tier: "client", scope: "acme"} and .node == "external" and .linked_from == ["~/Developer/acme/.claude/agents/ext.md"]'
  jqt "a CLAUDE.md has one entry per finding, a skill has one entry from its evidence" "$WORLD/view.json" \
    '([.items[] | select(.id == "global/CLAUDE.md") | .entries[] | [.line, .verdict]] == [[4, "fail"], [5, "warn"]]) and ([.items[] | select(.id == "global/skills/commit-style") | .entries[] | [.line, .verdict, .suggested_tier]] == [[2, "fail", "client"]])'
  jqt "every entry has a twelve character key and passes have no entries" "$WORLD/view.json" \
    'all(.items[].entries[]; .key | test("^[0-9a-f]{12}$")) and all(.items[] | select(.verdict == "pass"); .entries == [])'
  jqt "no failure banner and no editor links by default" "$WORLD/view.json" '.last_failure == null and .editor_url == null'
  jqt "every item says which band and which top-level node it belongs to" "$WORLD/view.json" \
    '([.items[] | [.id, .band, .top]] | .[0:4]) == [["global/CLAUDE.md", "fail", "global"], ["global/skills/commit-style", "fail", "global"], ["acme/web/CLAUDE.md", "generic", "group:acme"], ["acme/CLAUDE.md", "pass", "group:acme"]]'
  t "nothing is left in the temp directory" '[ -z "$(ls -A "$TMPD")" ]' "left=$(ls -A "$TMPD")"

  t "hostile text cannot close the data block" '[ "$(grep -o "</script>" "$DATA/dashboard.html" | wc -l | tr -d " ")" = 2 ]' "count=$(grep -o "</script>" "$DATA/dashboard.html" | wc -l)"
  t "hostile text comes back unchanged" 'jq -e --arg h "$HOSTILE" ".items[0].entries[1].text == \$h" "$WORLD/view.json" >/dev/null'
  t "the page refers to nothing on the network" '! sed "s/<script id=\"custodian-data\".*<\/script>//" "$DATA/dashboard.html" | grep -Eqi "https?://|(src|href)=.?//"'
  awk '/^<script>/ { sub(/^<script>/, ""); on = 1 } /^<\/script>$/ { on = 0 } on { print }' "$DATA/dashboard.html" > "$WORLD/emitted.js"
  t "the policy allows exactly the script that was emitted" \
    '[ -s "$WORLD/emitted.js" ] && grep -q "script-src '"'"'sha256-$(shasum -a 256 "$WORLD/emitted.js" | cut -d" " -f1 | xxd -r -p | base64)'"'"'" "$DATA/dashboard.html"' "emitted=$(wc -c < "$WORLD/emitted.js")"
  t "the policy names nothing it does not need" '! grep -q "img-src" "$DATA/dashboard.html"'
  t "the policy forbids connections, forms and base addresses" 'grep -q "default-src '"'"'none'"'"'" "$DATA/dashboard.html" && grep -q "connect-src '"'"'none'"'"'" "$DATA/dashboard.html" && grep -q "form-action '"'"'none'"'"'" "$DATA/dashboard.html" && grep -q "base-uri '"'"'none'"'"'" "$DATA/dashboard.html"'

  cfg_set '.editor_url = "zed://file/{path}:{line}"'; mkdir -p "$DATA/failed"; printf 'batch acme: timed out after 900s\n' > "$DATA/failed/reason.txt"
  run_cmd dashboard --no-open; view
  jqt "a kept failure reason and an editor template reach the page" "$WORLD/view.json" '.last_failure == {reason: "batch acme: timed out after 900s"} and .editor_url == "zed://file/{path}:{line}"'

  jq '.items |= map(del(.home))' "$DATA/audit.json" > "$DATA/audit.tmp" && mv "$DATA/audit.tmp" "$DATA/audit.json"; run_cmd dashboard --no-open
  t "a report without homes is refused with the fix" '[ "$rc" = 2 ] && grep -q "custodian audit" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  rm "$DATA/audit.json"; run_cmd dashboard --no-open
  t "a missing report is a clear message" '[ "$rc" = 2 ] && grep -qi "no report" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  data_world; mk "$FAKE_HOME/Developer/standalone/app/CLAUDE.md" "app rules"
  cfg_set '.tiers += [{"tier": "client", "path": "~/Developer/standalone", "scope": "standalone"}]'; run_cmd audit; run_cmd dashboard --no-open; view
  jqt "a group that happens to be called standalone keeps its own repos" "$WORLD/view.json" \
    '([.tree[] | select(.node == "group:standalone") | .children[].node] == ["repo:standalone/app"]) and ([.tree[] | select(.node == "standalone") | .children[].node] == ["standalone:side"])'

  audited_world; regenerate
  jqt "the headline is the view model's: what leaks, what is misfiled and what needs nothing" "$WORLD/view.json" '.headline == {leaks: 2, misfiled: 0, generic: 1, settled: 3, changed: 0, gone: 0}'
  rm "$FAKE_HOME/store/skills/commit-style/SKILL.md"; printf 'one more rule\n' >> "$FAKE_HOME/store/CLAUDE.md"; regenerate
  jqt "a leaking file that has gone is not counted as leaking, and one that changed is said to have" "$WORLD/view.json" '.headline == {leaks: 1, misfiled: 0, generic: 1, settled: 3, changed: 1, gone: 1}'
  jqt "the tree and its total leave a gone file out, as the headline does, and still count one that changed" "$WORLD/view.json" '([.tree[] | select(.node == "global") | .fail] == [1]) and .everything.fail == 1'
  t "the page takes its headline from the view model and counts nothing itself" \
    'grep -q "data.headline" "$plugin/lib/page.js" && grep -q "data.everything" "$plugin/lib/page.js" && ! grep -q "item.needs ===" "$plugin/lib/page.js"'

  audited_world; regenerate
  jqt "the page is given a save command that needs no launcher" "$WORLD/view.json" '.ack_command == "\"$(cat \"$HOME/.custodian/plugin-root\")/bin/custodian\" ack"'
  local typed; typed="$(jq -r .ack_command "$WORLD/view.json") $(payload "$(jq -cn --arg k "$(key_of global/skills/commit-style 0)" '{v: 1, ack: [{key: $k, note: "from a terminal"}], restore: []}')")"
  ( cd "$WORLD/cwd" && env -i HOME="$FAKE_HOME" PATH="/usr/bin:/bin" TMPDIR="$TMPD" /bin/bash -c "$typed" >"$STDOUT" 2>"$ERR" ); rc=$?
  t "typed into a terminal with no launcher on its PATH, that command saves" \
    '[ "$rc" = 0 ] && grep -q "acknowledged 1" "$STDOUT" && jq -e "[.acknowledged[] | .note] == [\"from a terminal\"]" "$DATA/state.json" >/dev/null' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  t "the page copies the command it was given" 'grep -q "data.ack_command" "$plugin/lib/page.js" && ! grep -q "\"custodian ack \"" "$plugin/lib/page.js"'
  audited_world; mv "$DATA" "$FAKE_HOME/my data"; DATA="$FAKE_HOME/my data"; CFG="$DATA/config.json"; regenerate
  jqt "a data folder elsewhere is named in the command, quoted" "$WORLD/view.json" \
    '.ack_command == "CUSTODIAN_HOME=\($d | @sh) \"$(cat \($d + "/plugin-root" | @sh))/bin/custodian\" ack"' --arg d "$DATA"
  typed="$(jq -r .ack_command "$WORLD/view.json") $(payload "$(jq -cn --arg k "$(key_of global/skills/commit-style 0)" '{v: 1, ack: [{key: $k, note: ""}], restore: []}')")"
  ( cd "$WORLD/cwd" && env -i HOME="$FAKE_HOME" PATH="/usr/bin:/bin" TMPDIR="$TMPD" /bin/bash -c "$typed" >"$STDOUT" 2>"$ERR" ); rc=$?
  t "and that command saves there" '[ "$rc" = 0 ] && [ -f "$DATA/state.json" ] && [ ! -e "$FAKE_HOME/.custodian" ]' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"

  audited_world; edit_report '.schema_version = 2'; run_cmd dashboard --no-open
  t "the dashboard refuses a report of another schema version, in one sentence" \
    '[ "$rc" = 2 ] && [ "$(wc -l < "$ERR" | tr -d " ")" = 1 ] && grep -q "audit.json was written by a version of Custodian this one cannot read; run: custodian audit" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd status
  t "so does the status" '[ "$rc" = 2 ] && grep -q "this one cannot read" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd ack "$(payload '{"v":1,"ack":[],"restore":[]}')"
  t "and so does a save" '[ "$rc" = 2 ] && grep -q "this one cannot read" "$ERR" && [ ! -e "$DATA/state.json" ]' "rc=$rc stderr=$(cat "$ERR")"
  audited_world; regenerate; printf '{"schema_version": 2, "acknowledged": {}}' > "$DATA/state.json"
  save "$(one "$(key_of global/skills/commit-style 0)" "")" '[]'
  t "acknowledgements of another schema version are not read and not overwritten" \
    '[ "$rc" = 2 ] && grep -q "state.json was written by a version of Custodian this one cannot read" "$ERR" && [ "$(jq -c . "$DATA/state.json")" = "{\"schema_version\":2,\"acknowledged\":{}}" ]' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd dashboard --no-open
  t "nor does the dashboard read them" '[ "$rc" = 2 ] && grep -q "state.json was written by a version" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  audited_world
  t "a successful audit regenerates the page" '[ -f "$DATA/dashboard.html" ]'
  cp "$DATA/dashboard.html" "$WORLD/before.html"; EXTRA_ENV=(FAKE_MODE=exit1); run_cmd audit
  t "a failed audit leaves the old page" 'cmp -s "$WORLD/before.html" "$DATA/dashboard.html"'
}

payload() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
key_of() { jq -r --arg id "$1" --argjson n "$2" '.items[] | select(.id == $id) | .entries[$n].key' "$WORLD/view.json"; }
regenerate() { run_cmd dashboard --no-open; view; }
edit_report() { jq "$1" "$DATA/audit.json" > "$DATA/audit.tmp" && mv "$DATA/audit.tmp" "$DATA/audit.json"; }

keys() {
  audited_world; regenerate
  local leak_key; leak_key=$(key_of global/CLAUDE.md 0)
  edit_report '(.items[] | select(.id == "global/CLAUDE.md") | .findings[0].line) = 40'; regenerate
  t "the same flagged text on another line keeps its key" '[ "$(key_of global/CLAUDE.md 0)" = "$leak_key" ]'
  edit_report '(.items[] | select(.id == "global/CLAUDE.md") | .findings[0].text) = "*   Always run the staging smoke test   against acme-staging.internal before opening a PR."'; regenerate
  t "whitespace and a different list marker keep the key" '[ "$(key_of global/CLAUDE.md 0)" = "$leak_key" ]' "key=$(key_of global/CLAUDE.md 0) want=$leak_key"
  edit_report '(.items[] | select(.id == "global/CLAUDE.md") | .findings[0].text) = "- Always run the smoke test against globex-staging.internal."'; regenerate
  t "changed text changes the key" '[ "$(key_of global/CLAUDE.md 0)" != "$leak_key" ]'

  audited_world; regenerate
  local warn_key; warn_key=$(key_of acme/web/CLAUDE.md 0)
  edit_report '(.items[] | select(.id == "acme/web/CLAUDE.md")) |= (.verdict = "fail" | .suggested_tier = "project" | .findings[0].verdict = "fail" | .findings[0].suggested_tier = "project")'; regenerate
  t "a warning that becomes a leak gets a new key" '[ "$(key_of acme/web/CLAUDE.md 0)" != "$warn_key" ]'

  audited_world
  edit_report '(.items[] | select(.id == "acme/CLAUDE.md" or .id == "project/side/CLAUDE.md")) |= (.kind = "skill" | .verdict = "warn" | .suggested_tier = "global")'; regenerate
  local first second; first=$(key_of acme/CLAUDE.md 0); second=$(key_of project/side/CLAUDE.md 0)
  regenerate
  t "an entry with no text has a stable key of its own" '[ -n "$first" ] && [ "$first" != "$second" ] && [ "$(key_of acme/CLAUDE.md 0)" = "$first" ]' "first=$first second=$second"
}

save() { run_cmd ack "$(payload "$(jq -cn --argjson ack "$1" --argjson restore "$2" '{v: 1, ack: $ack, restore: $restore}')")"; }
one() { jq -cn --arg key "$1" --arg note "$2" '[{key: $key, note: $note}]'; }

acknowledge() {
  audited_world; regenerate
  local leak warn skill both
  leak=$(key_of global/CLAUDE.md 0); warn=$(key_of global/CLAUDE.md 1); skill=$(key_of global/skills/commit-style 0)
  both=$(jq -cn --arg w "$warn" --arg s "$skill" '[{key: $w, note: "About my own tooling, fine here."}, {key: $s, note: ""}]')
  save "$both" '[]'; view
  t "a valid payload is saved" '[ "$rc" = 0 ] && grep -q "acknowledged 2" "$STDOUT"' "rc=$rc stderr=$(cat "$ERR") stdout=$(cat "$STDOUT")"
  t "the state file is private" '[ "$(mode "$DATA/state.json")" = 600 ]'
  jqt "the state records what was accepted" "$DATA/state.json" '.schema_version == 1 and (.acknowledged | length) == 2'
  t "the note and the item are recorded against the key" 'jq -e --arg k "$warn" ".acknowledged[\$k] | .id == \"global/CLAUDE.md\" and .verdict == \"warn\" and .note == \"About my own tooling, fine here.\" and (.acknowledged_at | test(\"Z$\"))" "$DATA/state.json" >/dev/null'
  jqt "the page is regenerated with those entries acknowledged" "$WORLD/view.json" \
    '([.items[] | select(.id == "global/CLAUDE.md") | .entries[] | .acknowledged != null] == [false, true]) and (.items[] | select(.id == "global/skills/commit-style") | .entries[0].acknowledged.note == "")'
  jqt "a fully acknowledged item leaves the leak band and the tree's counts" "$WORLD/view.json" \
    '([.items[].id][0:3] == ["global/CLAUDE.md", "acme/web/CLAUDE.md", "global/skills/commit-style"]) and (.tree[0] | .fail == 1 and .warn == 0) and .summary.acknowledged == 1 and .summary.fail == 2'

  audited_world; regenerate
  save "$(one "$(key_of global/CLAUDE.md 0)" "only an example")" '[]'; view
  jqt "with its leak accepted, a file's advice follows the entry still open" "$WORLD/view.json" \
    '.items[] | select(.id == "global/CLAUDE.md") | .needs == "warn" and .belongs == "project" and .suggested_tier == "client"'
  audited_world; regenerate
  save "$both" '[]'
  leak=$(key_of global/CLAUDE.md 0)
  save "$(one "$leak" "second save")" '[]'
  jqt "a second save keeps the first" "$DATA/state.json" '(.acknowledged | length) == 3'
  save '[]' "$(jq -cn --arg k "$leak" '[$k]')"; view
  jqt "a restore removes an acknowledgement" "$DATA/state.json" '(.acknowledged | length) == 2'
  jqt "a restored entry needs attention again" "$WORLD/view.json" '.items[0].id == "global/CLAUDE.md" and .items[0].entries[0].acknowledged == null'

  cp "$DATA/state.json" "$WORLD/state.before"
  save "$(jq -cn --arg k "$leak" '[{key: $k, note: "ok"}, {key: "0123456789ab", note: "stale"}]')" '[]'
  t "an unknown key rejects the whole payload and changes nothing" '[ "$rc" = 2 ] && grep -q "0123456789ab" "$ERR" && cmp -s "$WORLD/state.before" "$DATA/state.json"' "rc=$rc stderr=$(cat "$ERR")"
  save "$(jq -cn --arg k "$leak" '[{key: $k, note: "ok", text: "client words"}]')" '[]'
  t "a payload carrying anything beyond keys and notes is rejected" '[ "$rc" = 2 ] && cmp -s "$WORLD/state.before" "$DATA/state.json"' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd ack "$(payload "$(jq -cn --arg k "$leak" '{v: 1, ack: [{key: $k, note: {"smuggled": "object"}}], restore: []}') {\"v\":1,\"ack\":[],\"restore\":[]}")"
  t "two documents in one payload are rejected" '[ "$rc" = 2 ] && cmp -s "$WORLD/state.before" "$DATA/state.json"' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd ack "not-a-payload!!"
  t "a malformed payload is rejected with a clear message" '[ "$rc" = 2 ] && grep -qi "payload" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd ack "$(payload '{"v":2,"ack":[],"restore":[]}')"
  t "an unknown payload version is rejected" '[ "$rc" = 2 ]' "rc=$rc"
  run_cmd ack
  t "ack with no payload explains itself" '[ "$rc" = 2 ] && grep -qi "dashboard" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  cp "$DATA/audit.json" "$WORLD/with.json"
  edit_report '(.items[] | select(.id == "global/skills/commit-style")) |= (.verdict = "pass" | .suggested_tier = null | .evidence = null)'; regenerate
  jqt "an acknowledgement whose entry vanished is listed as orphaned" "$WORLD/view.json" '[.orphaned_acknowledgements[].id] == ["global/skills/commit-style"]'
  cp "$DATA/audit.json" "$WORLD/without.json"; cp "$WORLD/with.json" "$DATA/audit.json"; regenerate
  jqt "an orphaned acknowledgement is honoured again when its entry returns" "$WORLD/view.json" '.orphaned_acknowledgements == [] and (.items[] | select(.id == "global/skills/commit-style") | .entries[0].acknowledged != null)'
  cp "$WORLD/without.json" "$DATA/audit.json"; regenerate
  save '[]' "$(jq -cn --arg k "$skill" '[$k]')"; view
  jqt "an orphan can be restored, which deletes it" "$WORLD/view.json" '.orphaned_acknowledgements == []'
  mkdir "$DATA/.state.lock"; touch -t 202001010000 "$DATA/.state.lock"
  save "$(one "$leak" "after a killed save")" '[]'
  t "a lock left by a killed save is taken over" '[ "$rc" = 0 ] && [ ! -e "$DATA/.state.lock" ]' "rc=$rc stderr=$(cat "$ERR")"
  t "a save leaves nothing in the temp directory" '[ -z "$(ls -A "$TMPD")" ]' "left=$(ls -A "$TMPD")"
  mkdir -p "$DATA/.custodian.lock" && echo $$ > "$DATA/.custodian.lock/pid"
  save "$(one "$leak" "during an audit")" '[]'
  t "a save never waits for an audit's lock" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
}

ruled_world() {
  data_world
  mk "$FAKE_HOME/store/rules/hosts.md" "# Hosts

- Always run the staging smoke test against acme-staging.internal before opening a PR.
- The side project keeps its fixtures under spec/fixtures.
"
  mk "$FAKE_HOME/Developer/acme/.claude/rules/api.md" "acme api rules"
  EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "global/rules/hosts" then .findings = [
    {line: 3, text: "- Always run the staging smoke test against acme-staging.internal before opening a PR.", verdict: "fail", suggested_tier: "client", rationale: "Names the acme staging host."},
    {line: 4, text: "- The side project keeps its fixtures under spec/fixtures.", verdict: "warn", suggested_tier: "project", rationale: "About one codebase."}] else . end)')
  run_cmd audit
  EXTRA_ENV=()
}

rule_files() {
  ruled_world
  t "the fixture audit with a rule file succeeds" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd dashboard --no-open; view
  jqt "a rule says it is a rule and has one entry per flagged line" "$WORLD/view.json" \
    '[.items[] | select(.id == "global/rules/hosts") | {kind, entries: [.entries[] | [.line, .verdict, .suggested_tier]]}] == [{kind: "rule", entries: [[3, "fail", "client"], [4, "warn", "project"]]}]'
  jqt "the view says which items carry a reason for each flagged line" "$WORLD/view.json" \
    '[.items[] | select(.id == "global/rules/hosts" or .id == "global/CLAUDE.md" or .id == "global/skills/commit-style") | {(.id): .by_line}] | add
     == {"global/rules/hosts": true, "global/CLAUDE.md": true, "global/skills/commit-style": false}'
  save "$(one "$(key_of global/rules/hosts 0)" "only an example")" '[]'; view
  jqt "with its leak accepted, a rule's advice follows the line still open" "$WORLD/view.json" \
    '.items[] | select(.id == "global/rules/hosts") | .needs == "warn" and .belongs == "project" and ([.entries[] | .acknowledged != null] == [true, false])'

  ruled_world; status_json
  jqt "untouched rule files are not drift" "$WORLD/status.json" '.drift == {changed: [], new: [], gone: [], relinked: []} and .reasons == []'
  printf -- '- One more host rule.\n' >> "$FAKE_HOME/store/rules/hosts.md"
  mk "$FAKE_HOME/store/rules/team/new.md" "a new rule in a folder of its own"
  status_json
  jqt "an edited rule file is changed and a new one is new, at any depth" "$WORLD/status.json" \
    '.drift.changed == ["global/rules/hosts"] and .drift.new == ["global/rules/team/new"] and (.unjudged | map(.kind)) == ["rule"]'
  ruled_world
  rm "$FAKE_HOME/store/rules/hosts.md"
  lnk "$FAKE_HOME/Developer/acme/.claude/rules/api.md" "$FAKE_HOME/store/rules/acme-api.md"
  status_json
  jqt "a removed rule file is gone and one linked into the global folder is relinked" "$WORLD/status.json" \
    '.drift == {changed: [], new: [], gone: ["global/rules/hosts"], relinked: ["acme/.claude/rules/api"]}'

  data_world; mk "$FAKE_HOME/store/rules/hosts.md" "a host rule"; mk "$FAKE_HOME/Developer/acme/.claude/rules/deep/api.md" "an api rule"
  run_cmd audit; run_hook
  t "an estate with rule files and nothing changed is silent" 'silent' "$(heard)"
  data_world; mk "$FAKE_HOME/store/rules/hosts.md" "a host rule"; mk "$FAKE_HOME/Developer/acme/.claude/rules/deep/api.md" "an api rule"
  run_cmd audit
  printf 'one more rule\n' >> "$FAKE_HOME/Developer/acme/.claude/rules/deep/api.md"; mk "$FAKE_HOME/store/rules/more/new.md" "a new rule"; run_hook
  t "an edited rule file and a new one count in the reminder" \
    'said "Custodian: 2 context files have changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"

  local n size cost_small cost_large
  for size in 3 30; do
    data_world; account_folder "$FAKE_HOME/.claude-acme"
    cfg_set '.tiers += [{"tier": "client", "path": "~/.claude-acme", "scope": "acme"}] | .slots = {"acme": "~/.claude-acme"}'
    n=0; while [ "$n" -lt "$size" ]; do
      mk "$FAKE_HOME/store/rules/set$((n % 3))/r$n.md" "rule $n"; mk "$FAKE_HOME/.claude-acme/rules/r$n.md" "acme rule $n"
      mk "$FAKE_HOME/Developer/Personal/repo$n/CLAUDE.md" "repo $n"; mk "$FAKE_HOME/Developer/Personal/repo$n/.claude/rules/r.md" "repo rule $n"; n=$((n+1))
    done
    run_cmd audit; one_edit; find "$FAKE_HOME/store" "$FAKE_HOME/Developer" "$FAKE_HOME/.claude-acme" -type f -exec touch -t 203001010000 {} +
    log_calls jq stat shasum realpath awk find; run_hook
    [ "$size" = 3 ] && cost_small="$(calls jq) $(calls stat) $(calls shasum) $(calls realpath) $(calls awk) $(calls find)" || cost_large="$(calls jq) $(calls stat) $(calls shasum) $(calls realpath) $(calls awk) $(calls find)"
  done
  t "rule files cost the quick check no more processes, in few roots or many" '[ "$cost_small" = "$cost_large" ] && [ "$cost_large" = "3 1 1 0 2 0" ]' "small=$cost_small large=$cost_large $(heard)"
}

above_world() {
  data_world
  mk "$FAKE_HOME/Developer/CLAUDE.md" "# Above

- Deploys for acme go through acme-staging.internal.
"
  EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "external/~/Developer/CLAUDE.md" then .findings = [
    {line: 3, text: "- Deploys for acme go through acme-staging.internal.", verdict: "fail", suggested_tier: "client", rationale: "Names an acme host where every group loads it."}] else . end)')
  run_cmd audit
  EXTRA_ENV=()
}

above_roots() {
  local over="external/~/Developer/CLAUDE.md"
  above_world
  t "the fixture audit with a file above its roots succeeds" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd dashboard --no-open; view
  jqt "the view files it outside every root, loaded by every session, with the roots it sits above" "$WORLD/view.json" \
    '[.items[] | select(.id == "external/~/Developer/CLAUDE.md") | [.node, .loaded_by.tier, .above, .kind, (.entries | length)]]
     == [["external", "global", ["~/Developer/Personal/side", "~/Developer/acme", "~/Developer/acme/web"], "claude_md", 1]]'
  jqt "every other item sits above nothing" "$WORLD/view.json" 'all(.items[] | select(.id != "external/~/Developer/CLAUDE.md"); .above == [])'
  save "$(one "$(key_of "$over" 0)" "meant for every group")" '[]'; view
  jqt "a flagged line of a file above the roots can be accepted" "$WORLD/view.json" '[.items[] | select(.id == "external/~/Developer/CLAUDE.md") | .needs] == ["pass"]'

  above_world; status_json
  jqt "untouched, a file above the roots is not drift" "$WORLD/status.json" '.drift == {changed: [], new: [], gone: [], relinked: []} and .reasons == []'
  printf -- '- One more line.\n' >> "$FAKE_HOME/Developer/CLAUDE.md"; mk "$FAKE_HOME/Developer/.claude/rules/new.md" "a rule above the roots"
  status_json
  jqt "an edit above the roots is changed, and a new rule file there is new, with what it sits above" "$WORLD/status.json" \
    '.drift.changed == ["external/~/Developer/CLAUDE.md"] and .drift.new == ["external/~/Developer/.claude/rules/new"] and ([.unjudged[] | [.kind, (.above | length)]] == [["rule", 3]])'
  run_cmd dashboard --no-open; view
  jqt "the view shows a file found above the roots since the audit, with what it sits above" "$WORLD/view.json" '[.unjudged[] | (.above | length)] == [3]'
  above_world; rm "$FAKE_HOME/Developer/CLAUDE.md"; status_json
  jqt "a file removed from above the roots is gone" "$WORLD/status.json" '.drift.gone == ["external/~/Developer/CLAUDE.md"] and .stale == true'

  data_world; mk "$WORLD/elsewhere/CLAUDE.md" "above a root that is not there"
  cfg_set ".tiers += [{\"tier\": \"client\", \"path\": \"$WORLD/elsewhere/gone/group\", \"scope\": \"gone\"}]"
  run_cmd audit; status_json
  t "a file above a root that is not there is not judged, and the full check turns its path down" \
    '[ "$rc" = 0 ] && jq -e --arg at "$WORLD/elsewhere/CLAUDE.md" "(.rejected | index(\$at)) != null and .drift == {changed: [], new: [], gone: [], relinked: []}" "$WORLD/status.json" >/dev/null && ! jq -e "any(.items[]; .path | test(\"/elsewhere/\"))" "$DATA/audit.json" >/dev/null' "status=$(jq -c "[.drift, .rejected]" "$WORLD/status.json")"
  run_hook
  t "and the hook says nothing of it" 'silent' "$(heard)"
  data_world; mk "$WORLD/vol/we\\ird/CLAUDE.md" "above a root reached through a link"; mk "$WORLD/vol/we\\ird/repo/CLAUDE.md" "repo rules"
  lnk "$WORLD/vol/we\\ird/repo" "$FAKE_HOME/code/repo"
  cfg_set ".tiers += [{\"tier\": \"project\", \"path\": \"$FAKE_HOME/code/repo\"}]"
  run_cmd audit; status_json
  t "a file above a root that is a link into a folder with a backslash in its path is not judged, and the full check finds nothing changed" \
    '[ "$rc" = 0 ] && jq -e ".stale == false and .drift == {changed: [], new: [], gone: [], relinked: []}" "$WORLD/status.json" >/dev/null && ! jq -e "any(.items[]; .path | test(\"/vol/\"))" "$DATA/audit.json" >/dev/null' "status=$(jq -c '{stale, drift, rejected}' "$WORLD/status.json" 2>&1 | cut -c1-300)"
  run_hook
  t "and the hook agrees with it, and says nothing" 'silent' "$(heard)"

  above_world; run_hook
  t "with nothing changed above the roots the hook speaks only of the leak" 'said "Custodian: 1 file still leaks. /custodian:dashboard shows where."' "$(heard)"
  above_world; printf -- '- One more line.\n' >> "$FAKE_HOME/Developer/CLAUDE.md"; mk "$FAKE_HOME/CLAUDE.md" "appeared above everything"; run_hook
  t "an edit above the roots and a file that appears higher still both count in the reminder" \
    'said "Custodian: 2 context files have changed, appeared or gone since your audit less than a day ago. 1 file still leaks. $ACT"' "$(heard)"

  local n size cost_small cost_large
  for size in 3 30; do
    data_world; mk "$FAKE_HOME/Developer/CLAUDE.md" "above"; mk "$FAKE_HOME/Developer/.claude/rules/r.md" "a rule above"
    n=0; while [ "$n" -lt "$size" ]; do
      mk "$FAKE_HOME/Developer/Personal/repo$n/CLAUDE.md" "repo $n"; mk "$FAKE_HOME/Developer/set$((n % 3))/CLAUDE.md" "above set $((n % 3))"
      mk "$FAKE_HOME/Developer/set$((n % 3))/repo$n/CLAUDE.md" "repo $n in a set"; n=$((n+1))
    done
    run_cmd audit; one_edit; find "$FAKE_HOME/store" "$FAKE_HOME/Developer" -type f -exec touch -t 203001010000 {} +
    log_calls jq stat shasum realpath awk find; run_hook
    [ "$size" = 3 ] && cost_small="$(calls jq) $(calls stat) $(calls shasum) $(calls realpath) $(calls awk) $(calls find)" || cost_large="$(calls jq) $(calls stat) $(calls shasum) $(calls realpath) $(calls awk) $(calls find)"
  done
  t "the walk upward costs the quick check no more processes, in few roots or many" '[ "$cost_small" = "$cost_large" ] && [ "$cost_large" = "3 1 1 0 2 0" ]' "small=$cost_small large=$cost_large $(heard)"
}

commanded_world() {
  data_world
  mk "$FAKE_HOME/store/commands/deploy.md" "---
description: Ship the current branch
---
Deploy through the acme change board.
"
  mk "$FAKE_HOME/Developer/acme/.claude/commands/review.md" "an acme command"
  EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "global/commands/deploy" then .verdict = "fail" | .suggested_tier = "client" | .rationale = "Names the acme change board."
    | .evidence = {line: 4, text: "Deploy through the acme change board."} else . end)')
  run_cmd audit
  EXTRA_ENV=()
}

command_files() {
  commanded_world
  t "the fixture audit with a command file succeeds" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd dashboard --no-open; view
  jqt "a command says it is a command, is judged as a whole and has one entry, its evidence" "$WORLD/view.json" \
    '[.items[] | select(.id == "global/commands/deploy") | [.kind, .by_line, [.entries[] | [.line, .verdict, .suggested_tier]]]] == [["command", false, [[4, "fail", "client"]]]]'
  save "$(one "$(key_of global/commands/deploy 0)" "only an example")" '[]'; view
  jqt "a command's verdict can be accepted" "$WORLD/view.json" '[.items[] | select(.id == "global/commands/deploy") | [.needs, .band]] == [["pass", "accepted"]]'

  commanded_world; status_json
  jqt "untouched command files are not drift" "$WORLD/status.json" '.drift == {changed: [], new: [], gone: [], relinked: []} and .reasons == []'
  printf 'One more step.\n' >> "$FAKE_HOME/store/commands/deploy.md"; mk "$FAKE_HOME/store/commands/team/new.md" "a new command in a folder of its own"
  status_json
  jqt "an edited command file is changed and a new one is new, at any depth" "$WORLD/status.json" \
    '.drift.changed == ["global/commands/deploy"] and .drift.new == ["global/commands/team/new"] and (.unjudged | map(.kind)) == ["command"]'
  commanded_world
  rm "$FAKE_HOME/store/commands/deploy.md"
  lnk "$FAKE_HOME/Developer/acme/.claude/commands/review.md" "$FAKE_HOME/store/commands/acme-review.md"
  status_json
  jqt "a removed command file is gone and one linked into the global folder is relinked" "$WORLD/status.json" \
    '.drift == {changed: [], new: [], gone: ["global/commands/deploy"], relinked: ["acme/.claude/commands/review"]}'

  commanded_world; printf 'One more step.\n' >> "$FAKE_HOME/Developer/acme/.claude/commands/review.md"; mk "$FAKE_HOME/store/commands/more/new.md" "a new command"; run_hook
  t "an edited command file and a new one count in the reminder" \
    'said "Custodian: 2 context files have changed, appeared or gone since your audit less than a day ago. 1 file still leaks. $ACT"' "$(heard)"
}

imported_world() {
  data_world
  mk "$FAKE_HOME/Developer/acme/notes/team.md" "# The team

- Deploys wait for the acme change board.
"
  printf 'The team: @~/Developer/acme/notes/team.md\n' >> "$FAKE_HOME/store/CLAUDE.md"
  EXTRA_ENV=('FAKE_FILTER=.items |= map(if .id == "acme/notes/team.md" then .findings = [
    {line: 3, text: "- Deploys wait for the acme change board.", verdict: "fail", suggested_tier: "client", rationale: "Names the acme change board where every session loads it."}] else . end)')
  run_cmd audit
  EXTRA_ENV=()
}

imports() {
  imported_world
  t "the fixture audit with an import succeeds" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd dashboard --no-open; view
  jqt "an imported file says what it is, is filed with its home, is loaded by every session and names what imports it" "$WORLD/view.json" \
    '[.items[] | select(.id == "acme/notes/team.md") | [.kind, .by_line, .node, .loaded_by.tier, .imported_by, [.entries[] | [.line, .verdict, .suggested_tier]]]]
     == [["import", true, "group:acme", "global", ["~/store/CLAUDE.md"], [[3, "fail", "client"]]]]'
  jqt "every other item is imported by nothing" "$WORLD/view.json" 'all(.items[] | select(.id != "acme/notes/team.md"); .imported_by == [])'
  save "$(one "$(key_of acme/notes/team.md 0)" "meant for every session")" '[]'; view
  jqt "a flagged line of an imported file can be accepted" "$WORLD/view.json" '[.items[] | select(.id == "acme/notes/team.md") | [.needs, .band]] == [["pass", "accepted"]]'

  imported_world; status_json
  jqt "untouched imports are not drift" "$WORLD/status.json" '.drift == {changed: [], new: [], gone: [], relinked: []} and .reasons == []'
  printf -- '- One more line.\n' >> "$FAKE_HOME/Developer/acme/notes/team.md"; status_json
  jqt "an edited imported file is changed" "$WORLD/status.json" '.drift == {changed: ["acme/notes/team.md"], new: [], gone: [], relinked: []}'
  imported_world; printf '\n@../notes/team.md\n' >> "$FAKE_HOME/Developer/acme/web/CLAUDE.md"; status_json
  jqt "an imported file that gains an importer is relinked, and the file that now imports it is changed" "$WORLD/status.json" \
    '.drift == {changed: ["acme/web/CLAUDE.md"], new: [], gone: [], relinked: ["acme/notes/team.md"]}'
  imported_world; mk "$FAKE_HOME/store/notes/extra.md" "extra notes"; printf 'More: @notes/extra.md\n' >> "$FAKE_HOME/store/CLAUDE.md"; status_json
  jqt "a new import is new and unjudged, and says what imports it" "$WORLD/status.json" \
    '.drift.changed == ["global/CLAUDE.md"] and .drift.new == ["global/notes/extra.md"] and ([.unjudged[] | [.kind, .imported_by]] == [["import", ["~/store/CLAUDE.md"]]])'
  run_cmd dashboard --no-open; view
  jqt "the view shows it as not yet judged, with what imports it" "$WORLD/view.json" '[.unjudged[] | [.kind, .imported_by]] == [["import", ["~/store/CLAUDE.md"]]]'
  imported_world; sed -i '' '/The team:/d' "$FAKE_HOME/store/CLAUDE.md"; status_json
  jqt "a file that is no longer imported is gone" "$WORLD/status.json" '.drift.changed == ["global/CLAUDE.md"] and .drift.gone == ["acme/notes/team.md"]'

  imported_world; run_hook
  t "with its imports untouched the hook speaks only of the leak" 'said "Custodian: 1 file still leaks. /custodian:dashboard shows where."' "$(heard)"
  imported_world; printf -- '- One more line.\n' >> "$FAKE_HOME/Developer/acme/notes/team.md"; run_hook
  t "an edited imported file counts in the reminder" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. 1 file still leaks. $ACT"' "$(heard)"
  imported_world; rm "$FAKE_HOME/Developer/acme/notes/team.md"; run_hook
  t "an imported file that is gone counts" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. 1 file still leaks. $ACT"' "$(heard)"

  data_world; printf 'Later: @notes/later.md\n' >> "$FAKE_HOME/store/CLAUDE.md"; run_cmd audit; run_hook
  t "an import that names nothing is nothing to speak of" 'silent' "$(heard)"
  data_world; printf 'Later: @notes/later.md\n' >> "$FAKE_HOME/store/CLAUDE.md"; run_cmd audit; mk "$FAKE_HOME/store/notes/later.md" "here at last"; run_hook
  t "a recorded path that named nothing and now names a file counts, with the file that imports it untouched" \
    'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"
  status_json
  jqt "and the full check agrees: it is new" "$WORLD/status.json" '.drift == {changed: [], new: ["global/notes/later.md"], gone: [], relinked: []}'
  data_world; printf 'Later: @notes/later.md\n' >> "$FAKE_HOME/store/CLAUDE.md"; run_cmd audit; mkdir -p "$FAKE_HOME/store/notes/later.md"; status_json; run_hook
  t "a recorded path that has become a folder is rejected by the full check, and the hook then leaves it alone" \
    'silent && jq -e ".drift.new == [] and (.rejected | map(select(endswith(\"/notes/later.md\"))) | length == 1)" "$WORLD/status.json" >/dev/null' "$(heard) status=$(jq -c "[.drift, .rejected]" "$WORLD/status.json")"

  data_world; mkdir -p "$FAKE_HOME/store/notes"; printf 'The notes: @notes\n' >> "$FAKE_HOME/store/CLAUDE.md"; run_cmd audit
  mk "$FAKE_HOME/store/notes/inside.md" "a file in the folder"; run_hook
  t "a folder that an import names is nothing to speak of, whatever is put in it" 'silent' "$(heard)"
  rmdir "$FAKE_HOME/store/notes" 2>/dev/null || { rm "$FAKE_HOME/store/notes/inside.md"; rmdir "$FAKE_HOME/store/notes"; }
  mk "$FAKE_HOME/store/notes" "now a file"; clock_forward 7200; run_hook
  t "a folder that an import named and that has become a file counts" \
    'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"
  data_world; printf 'bytes\000here\n' > "$FAKE_HOME/store/blob.txt"; printf 'A blob: @blob.txt\n' >> "$FAKE_HOME/store/CLAUDE.md"; run_cmd audit
  printf 'text at last\n' > "$FAKE_HOME/store/blob.txt"; run_hook
  t "an imported file that was not text at the audit and now is counts" \
    'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"

  local n size cost_small cost_large
  for size in 3 30; do
    data_world; mk "$FAKE_HOME/store/notes/shared.md" "shared notes"; printf 'Shared: @notes/shared.md and later @notes/later.md\n' >> "$FAKE_HOME/store/CLAUDE.md"
    n=0; while [ "$n" -lt "$size" ]; do
      mk "$FAKE_HOME/Developer/Personal/repo$n/CLAUDE.md" "repo $n, with @README.md and @docs/missing.md"; mk "$FAKE_HOME/Developer/Personal/repo$n/README.md" "readme $n"; n=$((n+1))
    done
    run_cmd audit; one_edit; find "$FAKE_HOME/store" "$FAKE_HOME/Developer" -type f -exec touch -t 203001010000 {} +
    log_calls jq stat shasum realpath awk find; run_hook
    [ "$size" = 3 ] && cost_small="$(calls jq) $(calls stat) $(calls shasum) $(calls realpath) $(calls awk) $(calls find)" || cost_large="$(calls jq) $(calls stat) $(calls shasum) $(calls realpath) $(calls awk) $(calls find)"
  done
  t "imports cost the quick check no more processes, in few files or many" '[ "$cost_small" = "$cost_large" ] && [ "$cost_large" = "3 1 1 0 2 0" ]' "small=$cost_small large=$cost_large $(heard)"
}

init_and_import() {
  new_world; DATA="$FAKE_HOME/.custodian"; run_cmd init
  t "init creates a private data folder" '[ "$rc" = 0 ] && [ "$(mode "$DATA")" = 700 ] && [ "$(mode "$DATA/config.json")" = 600 ] && [ "$(mode "$DATA/examples.md")" = 600 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "the starter config audits the global tier and nothing else" "$DATA/config.json" '. == {tiers: [{tier: "global", path: "~/.claude"}]}'
  t "the examples file starts as the stub" 'grep -q "^## Correctly global" "$DATA/examples.md" && grep -q "^## Leakage" "$DATA/examples.md" && ! grep -q "^- " "$DATA/examples.md"'
  printf '{"mine": true}' > "$DATA/config.json"; printf 'my examples' > "$DATA/examples.md"; run_cmd init
  t "init never overwrites what is already there" '[ "$rc" = 0 ] && [ "$(cat "$DATA/config.json")" = "{\"mine\": true}" ] && [ "$(cat "$DATA/examples.md")" = "my examples" ]' "rc=$rc"

  new_world; DATA="$FAKE_HOME/.custodian"
  mk "$FAKE_HOME/old/custodian.config.json" '{ "canonical_store": "~/old", "output": "~/old-out/audit.json", "tiers": [ { "tier": "client", "path": "~/Developer/acme", "scope": "acme" } ], "slots": { "acme": "~/.claude-acme" }, "exclude": ["~/Developer/acme/vendored"] }'
  mk "$FAKE_HOME/old/custodian.examples.md" "my own examples"
  mk "$FAKE_HOME/old-out/audit.json" '{"old": "report"}'
  cp -R "$FAKE_HOME/old" "$WORLD/old.before"; cp -R "$FAKE_HOME/old-out" "$WORLD/old-out.before"
  run_cmd init --import "$FAKE_HOME/old/custodian.config.json"
  t "import succeeds" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "the imported config keeps its roots and drops the keys the data folder replaces" "$DATA/config.json" \
    '. == {tiers: [{tier: "client", path: "~/Developer/acme", scope: "acme"}], slots: {acme: "~/.claude-acme"}, exclude: ["~/Developer/acme/vendored"]}'
  t "the examples and the report come across" '[ "$(cat "$DATA/examples.md")" = "my own examples" ] && [ "$(cat "$DATA/audit.json")" = "{\"old\": \"report\"}" ] && [ "$(mode "$DATA/audit.json")" = 600 ]'
  t "import changes nothing at the old locations" 'diff -r "$FAKE_HOME/old" "$WORLD/old.before" >/dev/null && diff -r "$FAKE_HOME/old-out" "$WORLD/old-out.before" >/dev/null'
  run_cmd init --import "$FAKE_HOME/old/custodian.config.json"
  t "importing twice is harmless" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  rm -rf "$DATA"; run_cmd init; run_cmd init --import "$FAKE_HOME/old/custodian.config.json"
  t "an import replaces the untouched starter files that init wrote" '[ "$rc" = 0 ] && jq -e ".slots.acme" "$DATA/config.json" >/dev/null && [ "$(cat "$DATA/examples.md")" = "my own examples" ]' "rc=$rc stderr=$(cat "$ERR")"
  rm -rf "$DATA"; run_cmd init; printf '{"tiers": [{"tier": "global", "path": "~/mine"}]}' > "$DATA/config.json"; cp "$DATA/config.json" "$WORLD/mine.json"
  run_cmd init --import "$FAKE_HOME/old/custodian.config.json"
  t "an import refuses to replace a config I have edited, and changes nothing" '[ "$rc" = 2 ] && cmp -s "$WORLD/mine.json" "$DATA/config.json" && ! grep -q "my own examples" "$DATA/examples.md" && [ ! -e "$DATA/audit.json" ]' "rc=$rc stderr=$(cat "$ERR")"
  new_world; DATA="$FAKE_HOME/.custodian"; mkdir -p "$DATA"; printf 'kept' > "$DATA/examples.md"; chmod 500 "$DATA"; run_cmd init
  t "init fails loudly when it cannot write the config" '[ "$rc" != 0 ] && [ ! -e "$DATA/config.json" ]' "rc=$rc stderr=$(cat "$ERR")"
  chmod 700 "$DATA"

  new_world; DATA="$FAKE_HOME/.custodian"; run_cmd init --import "$FAKE_HOME/nowhere.json"
  t "importing a config that is not there is exit 2" '[ "$rc" = 2 ] && [ ! -e "$DATA/config.json" ]' "rc=$rc"
}

launch() { ( cd "$WORLD/cwd" && env -i HOME="$FAKE_HOME" CUSTODIAN_HOME="$DATA" PATH="$BIN:/usr/bin:/bin" "$1" version >"$STDOUT" 2>"$ERR" ); rc=$?; }

other_systems() {
  local sub
  for sub in audit dry-run status dashboard "ack x" init frobnicate ""; do
    new_world; DATA="$FAKE_HOME/.custodian"; as_system "echo Linux"; run_cmd $sub
    t "outside macOS ${sub:-a bare call} refuses with exit 2 and creates nothing" \
      '[ "$rc" = 2 ] && grep -q "only macOS is supported, and this is Linux" "$ERR" && [ ! -e "$DATA" ] && [ ! -s "$STDOUT" ] && [ -z "$(ls -A "$LOG")" ]' "rc=$rc stderr=$(cat "$ERR")"
  done
  new_world; DATA="$FAKE_HOME/.custodian"; as_system "echo Linux"; run_cmd version
  t "version still answers outside macOS" '[ "$rc" = 0 ] && grep -q "^custodian [0-9]" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  new_world; DATA="$FAKE_HOME/.custodian"; as_system "exit 1"; run_cmd status
  t "a uname that answers nothing reads as not macOS" '[ "$rc" = 2 ] && grep -q "this is an unknown system" "$ERR" && [ ! -e "$DATA" ]' "rc=$rc stderr=$(cat "$ERR")"
}

launcher() {
  data_world; mkdir -p "$FAKE_HOME/bin"; run_cmd init --launcher "$FAKE_HOME/bin"
  t "init installs an executable launcher where I asked" '[ "$rc" = 0 ] && [ -x "$FAKE_HOME/bin/custodian" ]' "rc=$rc stderr=$(cat "$ERR")"
  launch "$FAKE_HOME/bin/custodian"
  t "the launcher runs the command the pointer names" '[ "$rc" = 0 ] && grep -q "^custodian [0-9]" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  printf '/nonexistent/plugin' > "$DATA/plugin-root"; launch "$FAKE_HOME/bin/custodian"
  t "a pointer to a plugin that has gone says how to recover" '[ "$rc" = 2 ] && grep -q "/custodian:" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd init --launcher "$FAKE_HOME/bin"
  t "installing the launcher again is fine" '[ "$rc" = 0 ]' "rc=$rc"
  mkdir -p "$FAKE_HOME/bin2"; printf '#!/bin/sh\necho mine\n' > "$FAKE_HOME/bin2/custodian"; run_cmd init --launcher "$FAKE_HOME/bin2"
  t "init refuses to replace a file that is not its launcher" '[ "$rc" = 2 ] && grep -q "echo mine" "$FAKE_HOME/bin2/custodian"' "rc=$rc"
  run_cmd init --launcher "$FAKE_HOME/no-such-dir"
  t "a launcher folder that does not exist is exit 2" '[ "$rc" = 2 ]' "rc=$rc"
}

doctor() {
  data_world; run_cmd doctor
  t "doctor passes on a healthy machine" '[ "$rc" = 0 ] && grep -q "check-jsonschema" "$STDOUT" && grep -qi "private" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  t "doctor invokes no audit" '[ -z "$(ls -A "$LOG")" ]'
  t "doctor says the personal account is logged in with a subscription, and repeats nothing else about it" \
    'grep -q "^ok   the personal account is logged in with a Claude subscription$" "$STDOUT" && ! grep -q SECRET "$STDOUT" "$ERR"' "stdout=$(cat "$STDOUT")"
  data_world; auth_as "$FAKE_HOME/.claude" out; run_cmd doctor
  t "an account that is logged out is reported with how to log in" \
    '[ "$rc" = 1 ] && grep -q "^FIX  the personal account is not logged in to Claude Code: run claude and log in with a Claude subscription$" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; account_folder "$FAKE_HOME/.claude-acme"; cfg_set '.slots = {"acme": "~/.claude-acme"}'; auth_as "$FAKE_HOME/.claude-acme" key; run_cmd doctor
  t "a group's account set up with a key is reported by its folder, beside the personal one" \
    '[ "$rc" = 1 ] && grep -q "^FIX  the account at ~/.claude-acme, which reads acme, is set up with an API key (ANTHROPIC_API_KEY), and Custodian audits on a Claude subscription only: run CLAUDE_CONFIG_DIR=~/.claude-acme claude and log in with a Claude subscription$" "$STDOUT" && grep -q "^ok   the personal account is logged in" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; account_folder "$FAKE_HOME/.claude-me"; cfg_set '.default_slot = "~/.claude-me"'; run_cmd doctor
  t "the default slot is the personal account doctor asks about" \
    '[ "$rc" = 0 ] && grep -q "^ok   the personal account at ~/.claude-me is logged in with a Claude subscription$" "$STDOUT" && [ "$(cut -f1 "$LOG.auth")" = "$FAKE_HOME/.claude-me" ]' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; EXTRA_ENV=(ANTHROPIC_API_KEY=sk-made-up CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CONFIG_DIR=/parent/slot CLAUDE_CODE_MANAGED_SETTINGS_PATH=/made/up CLAUDE_CODE_NOT_YET_INVENTED=1 CLAUDE_CODE_CLIENT_CERT=/made/up.pem HTTPS_PROXY=http://127.0.0.1:9); run_cmd doctor
  t "doctor names everything of Anthropic's and Claude Code's that is set here and left out of the audit, and nothing that is passed on" \
    '[ "$rc" = 0 ] && [ "$(sed -n "s/^ok   set here and not passed on to the audit: //p" "$STDOUT" | tr " " "\n" | LC_ALL=C sort | tr "\n" " ")" = "ANTHROPIC_API_KEY CLAUDE_CODE_MANAGED_SETTINGS_PATH CLAUDE_CODE_NOT_YET_INVENTED CLAUDE_CODE_USE_BEDROCK CLAUDE_CONFIG_DIR " ] && grep -q "^ok   the personal account is logged in" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; auth_as "$FAKE_HOME/.claude" out; EXTRA_ENV=(CLAUDE_CONFIG_DIR=/parent/slot); run_cmd doctor
  t "where the shell names another config folder, the way to log the default one in says to leave that name out" \
    'grep -q "^FIX  the personal account is not logged in to Claude Code: run env -u CLAUDE_CONFIG_DIR claude and log in with a Claude subscription$" "$STDOUT"' "stdout=$(grep "^FIX" "$STDOUT")"
  data_world; run_cmd doctor
  t "with nothing of the kind set, doctor does not mention it" '! grep -q "not passed on" "$STDOUT"' "stdout=$(cat "$STDOUT")"
  data_world; rm "$CFG"; auth_as "$FAKE_HOME/.claude" out; run_cmd doctor
  t "before there is a config, doctor still asks about the personal account" '[ "$rc" = 1 ] && grep -q "^FIX  the personal account is not logged in" "$STDOUT" && grep -q "no config yet" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; rm "$BIN/check-jsonschema"; run_cmd doctor
  t "a missing dependency is named with its install command" '[ "$rc" = 1 ] && grep -q "brew install check-jsonschema" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; run_cmd doctor
  t "doctor says the Claude Code version is new enough" 'grep -q "^ok   Claude Code 9.9.9-fake is new enough for the audit$" "$STDOUT"' "stdout=$(cat "$STDOUT")"
  data_world; EXTRA_ENV=(FAKE_VERSION=2.1.287); run_cmd doctor
  t "a Claude Code older than the seal needs is reported with the version it needs" \
    '[ "$rc" = 1 ] && grep -q "^FIX  Claude Code 2.1.287 is older than 2.1.295, which the audit needs: claude update$" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; EXTRA_ENV=(FAKE_HELP=old); run_cmd doctor
  t "a Claude Code without the runner's flags is reported as too old" '[ "$rc" = 1 ] && grep -q -- "--restricted" "$STDOUT" && grep -qi "update claude code" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; chmod 755 "$DATA"; run_cmd doctor
  t "a data folder others can read is reported" '[ "$rc" = 1 ] && grep -qi "chmod 700" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; as_system "echo Linux"; run_cmd doctor
  t "anything but macOS is reported as unsupported, and nothing else is checked" \
    '[ "$rc" = 1 ] && [ "$(cat "$STDOUT")" = "FIX  only macOS is supported, and this is Linux" ]' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; cfg_set '.slot = {}'; run_cmd doctor
  t "an invalid config is reported with the runner's own words" '[ "$rc" = 1 ] && grep -q "unknown config key: slot" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; examples_stub; mv "$FAKE_HOME/store/custodian.examples.md" "$DATA/examples.md"; run_cmd doctor
  t "an unfilled examples file is reported" '[ "$rc" = 1 ] && grep -q "Correctly global" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; mkdir -p "$FAKE_HOME/synced"; mv "$DATA/examples.md" "$FAKE_HOME/synced/examples.md"; ln -s "$FAKE_HOME/synced/examples.md" "$DATA/examples.md"; run_cmd doctor
  t "an examples file that is a link to a synced copy is fine" '[ "$rc" = 0 ]' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; rm "$BIN/jq"; mkdir -p "$WORLD/nojq"; for tool in /usr/bin/*; do [ "${tool##*/}" = jq ] || ln -s "$tool" "$WORLD/nojq/"; done
  EXTRA_ENV=("PATH=$BIN:$WORLD/nojq:/bin"); run_cmd doctor
  t "without jq, doctor names jq and blames nothing it could not check" \
    '[ "$rc" = 1 ] && grep -q "^FIX  jq is missing" "$STDOUT" && [ "$(grep -c "^FIX" "$STDOUT")" = 1 ] && ! grep -qi "hook\|reminder" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  data_world; rm "$BIN/claude"; run_cmd doctor
  t "a missing Claude Code is reported" '[ "$rc" = 1 ] && grep -qi "install claude code" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; mkdir -p "$DATA/failed"; chmod 755 "$DATA/failed"; run_cmd doctor
  t "a failed folder others can read is reported" '[ "$rc" = 1 ] && grep -q "failed" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; run_cmd doctor
  t "doctor says the hook is in place, that reminders are on and that none has been shown" '[ "$rc" = 0 ] && grep -q "reminder hook is in place" "$STDOUT" && grep -q "reminders are on; none has been shown yet" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  cfg_set '.remind = false'; run_cmd doctor
  t "doctor says when reminders are off, which is not a fault" '[ "$rc" = 0 ] && grep -q "reminders are off" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  drift_world; one_edit; run_hook; run_cmd doctor
  t "doctor says when the last reminder was shown" '[ "$rc" = 0 ] && grep -q "the last one was shown on $(date +%Y-%m-%d)" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  drift_world; one_edit; printf 'garbage' > "$DATA/baseline.json"; run_hook; run_cmd doctor
  t "doctor reports an error the hook recorded" '[ "$rc" = 1 ] && grep -q "FIX .*reminder.*cannot be read" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  drift_world; mkdir -p "$DATA/hook"; chmod 700 "$DATA/hook"; printf '%s 3\n' "$(date +%s)" > "$DATA/hook/last-check"; chmod 600 "$DATA/hook/last-check"; run_cmd doctor
  t "doctor reports a slow last check" '[ "$rc" = 1 ] && grep -q "FIX .*took 3s" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  drift_world; mkdir -p "$DATA/hook"; chmod 700 "$DATA/hook"; printf '%s\n' "$(( $(date +%s) - 120 ))" > "$DATA/hook/checked-$(( ($(date +%s) - 120) / 3600 ))"; chmod 600 "$DATA/hook"/*; run_cmd doctor
  t "doctor reports a check that started and never finished" '[ "$rc" = 1 ] && grep -q "FIX .*never finished" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  drift_world; one_edit; run_hook; run_cmd doctor
  t "a check that did finish is not reported" '[ "$rc" = 0 ] && ! grep -q "never finished" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  drift_world; chmod 644 "$DATA/status.json" "$DATA/baseline.json"; run_cmd doctor
  t "doctor checks that the baseline and the status are private too" '[ "$rc" = 1 ] && grep -q "chmod 600 .*status.json" "$STDOUT" && grep -q "chmod 600 .*baseline.json" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  data_world; mkdir -p "$WORLD/copy"; ( cd "$plugin" && tar -cf - --exclude .git . ) | ( cd "$WORLD/copy" && tar -xf - ); rm "$WORLD/copy/hooks/remind.sh"
  ( cd "$WORLD/cwd" && env -i HOME="$FAKE_HOME" CUSTODIAN_HOME="$DATA" PATH="$BIN:/usr/bin:/bin" TMPDIR="$TMPD" "$WORLD/copy/bin/custodian" doctor >"$STDOUT" 2>"$ERR" ); rc=$?
  t "doctor reports a hooks file that names a missing script" '[ "$rc" = 1 ] && grep -q "FIX .*reminder hook" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"

  local passed listed
  passed=$(sed -n '/claude -p/,/stderr.txt/p' "$plugin/lib/run.sh" | grep -oE -- '--[a-zA-Z-]+' | LC_ALL=C sort -u | tr "\n" " ")
  listed=$(. "$plugin/lib/claude-flags.sh"; printf '%s\n' "${CLAUDE_FLAGS[@]}" | LC_ALL=C sort -u | tr "\n" " ")
  t "doctor's flag list and the runner's invocation agree in both directions" '[ -n "$passed" ] && [ "$passed" = "$listed" ]' "passed=$passed listed=$listed"
  local missing=""; for flag in $(. "$plugin/lib/claude-flags.sh"; printf '%s ' "${CLAUDE_FLAGS[@]}"); do grep -q -- "$flag" "$plugin/lib/run.sh" || missing="$missing $flag"; done
  t "doctor checks exactly the flags the runner passes" '[ -z "$missing" ] && [ "$(. "$plugin/lib/claude-flags.sh"; echo "${#CLAUDE_FLAGS[@]}")" -ge 12 ]' "not in the runner:$missing"
}

doc_links() {
  local file dir target path anchor
  for file in "$plugin/README.md" "$plugin"/docs/*.md; do
    dir=$(dirname "$file")
    grep -o '](.[^)]*)' "$file" | sed 's/^](//; s/)$//' | while IFS= read -r target; do
      case "$target" in http*) continue;; esac
      path=${target%%#*}; anchor=""
      case "$target" in *"#"*) anchor=${target#*#};; esac
      [ -n "$path" ] || path=$(basename "$file")
      if [ ! -e "$dir/$path" ]; then echo "${file#"$plugin"/}: $target"; continue; fi
      [ -n "$anchor" ] || continue
      grep '^#' "$dir/$path" | sed 's/^#* *//' | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9 -]//g; s/ /-/g' | grep -qx -- "$anchor" || echo "${file#"$plugin"/}: $target"
    done
  done
}

kinds_named() {
  local kind
  for kind in $(jq -r '."$defs".item.properties.kind.enum[]' "$plugin/lib/schema.json"); do
    grep -q "\`$kind\`" "$plugin/lib/prompt.md" || return 1
  done
}

packaging() {
  local manifest="$plugin/.claude-plugin/plugin.json" market="$plugin/.claude-plugin/marketplace.json" skill
  jqt "the plugin is named custodian with a semantic version" "$manifest" '.name == "custodian" and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))'
  t "the repository's own marketplace is the development one, with the plugin at its root, and the version is in the plugin manifest alone" \
    '[ "$(jq -r "[.name, (.plugins[0] | .name, .source, (has(\"version\") | tostring))] | @tsv" "$market")" = "$(printf "custodian-dev\tcustodian\t./\tfalse")" ] && jq -e ".owner.name" "$market" >/dev/null' "market=$(jq -c . "$market" 2>&1 | cut -c1-200)"
  t "the README and the install doc give the two commands that install the plugin from its author's marketplace" \
    '( for doc in "$plugin/README.md" "$plugin/docs/install.md"; do grep -qx "claude plugin marketplace add azamkhanuk/claude-plugins" "$doc" && grep -qx "claude plugin install custodian@azamkhanuk" "$doc" || exit 1; done )'
  t "removing the plugin is never given as removing the marketplace other plugins install from" '! grep -q "^claude plugin marketplace remove" "$plugin/docs/install.md"'
  local version log="$plugin/CHANGELOG.md" notes="$plugin/scripts/release-notes.sh" checks="$plugin/.github/workflows/checks.yml" release="$plugin/.github/workflows/release.yml"
  version=$(jq -r .version "$manifest")
  t "the changelog's newest section is the manifest's version, with its date" 'grep -m1 "^## " "$log" | grep -Eq "^## $version - [0-9]{4}-[0-9]{2}-[0-9]{2}$"' "newest=$(grep -m1 "^## " "$log" 2>&1)"
  t "every section of the changelog is a version and a date, newest first" \
    '[ -z "$(grep "^## " "$log" | grep -Ev "^## [0-9]+\.[0-9]+\.[0-9]+ - [0-9]{4}-[0-9]{2}-[0-9]{2}$")" ] && [ "$(grep "^## " "$log" | cut -d" " -f2 | sort -t. -k1,1nr -k2,2nr -k3,3nr | tr "\n" " ")" = "$(grep "^## " "$log" | cut -d" " -f2 | tr "\n" " ")" ]' \
    "sections=$(grep "^## " "$log" 2>&1 | tr "\n" "|")"
  t "the notes script names the tag Claude Code's own command would, and a title" \
    '[ "$("$notes" --tag)" = "custodian--v$version" ] && [ "$("$notes" --title)" = "custodian $version" ]' "tag=$("$notes" --tag 2>&1) title=$("$notes" --title 2>&1)"
  "$notes" > "$SANDBOX/notes.md" 2> "$SANDBOX/notes.err"
  t "it prints that version's section, with no heading and nothing of the release before" \
    '[ -s "$SANDBOX/notes.md" ] && ! grep -q "^## " "$SANDBOX/notes.md" && [ -n "$(sed -n 1p "$SANDBOX/notes.md")" ] && [ -n "$(tail -n 1 "$SANDBOX/notes.md")" ] && [ "$(wc -l < "$SANDBOX/notes.md")" -lt "$(wc -l < "$log")" ]' "err=$(cat "$SANDBOX/notes.err")"
  mkdir -p "$SANDBOX/tree/scripts" "$SANDBOX/tree/.claude-plugin"; cp "$notes" "$SANDBOX/tree/scripts/"; cp "$log" "$SANDBOX/tree/"
  jq '.version = "9.9.9"' "$manifest" > "$SANDBOX/tree/.claude-plugin/plugin.json"
  t "a version the changelog has no section for is refused" '! "$SANDBOX/tree/scripts/release-notes.sh" > "$SANDBOX/none" 2>&1 && grep -q "no section for 9.9.9" "$SANDBOX/none" && [ "$("$SANDBOX/tree/scripts/release-notes.sh" --tag)" = "custodian--v9.9.9" ]' "out=$(cat "$SANDBOX/none" 2>&1)"
  t "the checks run both suites and strict validation of both manifests on macOS, behind one gate" \
    'grep -q "runs-on: macos" "$checks" && grep -q "test/run.smoke.sh" "$checks" && grep -q "test/custodian.smoke.sh" "$checks" && grep -q "claude plugin validate --strict \." "$checks" && grep -q "claude plugin validate --strict .claude-plugin/plugin.json" "$checks" && grep -q "^  gate:" "$checks" && grep -q "brew install check-jsonschema" "$checks"'
  t "a release is tagged and published by the notes script's own words, once the checks pass on main" \
    'grep -q "workflows: \[checks\]" "$release" && grep -q "branches: \[main\]" "$release" && grep -q "scripts/release-notes.sh --tag" "$release" && grep -q "gh release create" "$release" && grep -q "contents: write" "$release"'
  t "neither workflow runs while the repository is private, unless someone starts it" \
    '[ "$(grep -c "github.event.repository.private" "$checks")" -ge 3 ] && grep -q "workflow_dispatch" "$checks" && grep -q "github.event.repository.private" "$release"'
  t "the README names the oldest Claude Code, the one the code refuses below" 'grep -q "Claude Code $(. "$plugin/lib/claude-flags.sh"; printf %s "$CLAUDE_CODE_FLOOR") or later" "$plugin/README.md"'
  sed -n '/^```json$/,/^```$/p' "$plugin/docs/config.md" | sed '1d;$d' > "$SANDBOX/readme-config.json"
  t "the config the docs show and the template both show the two glob shapes, and every key they use is one the audit takes" \
    '( for shown in "$SANDBOX/readme-config.json" "$plugin/templates/config.example.json"; do jq -e "[.tiers[] | select(.tier == \"project\") | .glob | split(\"/\") | last] == [\"CLAUDE.md\", \".claude\"]" "$shown" >/dev/null || exit 1; for key in $(jq -r "keys[]" "$shown"); do grep -q "\"$key\"" "$plugin/lib/run.sh" || exit 1; done; done )'
  local listed unnamed=""
  for listed in $("$CUSTODIAN" 2>&1 | sed -n 's/^  \([a-z][a-z-]*\).*/\1/p'); do grep -q "\`custodian $listed" "$plugin/docs/commands.md" || unnamed="$unnamed $listed"; done
  for listed in $("$CUSTODIAN" 2>&1 | grep -o -- '--[a-z-]*' | LC_ALL=C sort -u) --launcher --import; do grep -q -- "$listed" "$plugin/docs/commands.md" || unnamed="$unnamed $listed"; done
  t "the commands doc names every subcommand and every flag" '[ -z "$unnamed" ] && [ -n "$listed" ]' "not named:$unnamed"
  t "every key of the config is in the config doc's table" \
    '( for key in $(grep -o "(keys - \[[^]]*\])\[\] | \"unknown config key" "$plugin/lib/run.sh" | grep -o "\"[a-z_]*\"" | tr -d "\"" | grep -vx "canonical_store\|output\|unknown"); do grep -q "^| \`$key\` |" "$plugin/docs/config.md" || exit 1; done )'
  t "every variable the judge's session is given is named in the privacy doc" \
    '( for name in $(. "$plugin/lib/common.sh"; . "$plugin/lib/seal.sh"; printf "%s" "$SEALED_KEEP"); do grep -q "\`$name\`" "$plugin/docs/privacy.md" || exit 1; done ); grep -q "LC_\*" "$plugin/docs/privacy.md" && grep -q "XDG_\*" "$plugin/docs/privacy.md"'
  local broken
  broken=$(doc_links)
  t "every link in the README and the docs leads to a file that is there, and to a heading that is there" '[ -z "$broken" ]' "broken: $broken"
  t "the README opens on a picture, each picture has its words, and each is drawn at the page's own width" \
    '[ "$(grep -c "^!\[.\{80,\}\](docs/[a-z-]*\.png)$" "$plugin/README.md")" = 2 ] && sed -n 5p "$plugin/README.md" | grep -q "^!\[" && [ "$(for picture in "$plugin"/docs/*.png; do sips -g pixelWidth "$picture" | sed -n "s/.*pixelWidth: //p"; done | LC_ALL=C sort -u)" = 1760 ]'
  t "the README keeps the nine parts Context Central's has, in that order" \
    '[ "$(grep "^## " "$plugin/README.md" | tr "\n" "|")" = "## What it does|## How it helps|## The core idea|## How it works for you|## Install|## An audit, step by step|## Where the detail lives|## What it does not do|## Licence|" ]' "got=$(grep "^## " "$plugin/README.md" | tr "\n" "|")"
  t "every doc under docs/ is in the README's table of where the detail lives" '( for doc in "$plugin"/docs/*.md; do grep -q "^| \[.*\](docs/$(basename "$doc")) |" "$plugin/README.md" || exit 1; done )'
  t "the pre-push hook runs the quick release check on its own repository" '[ -x "$plugin/scripts/pre-push" ] && grep -q "release-check.sh\" --quick" "$plugin/scripts/pre-push"'
  for skill in setup audit dashboard ack; do
    t "the $skill skill is user-invoked and pre-approves only the plugin's own command" \
      '[ "$(sed -n "s/^name: //p" "$plugin/skills/$skill/SKILL.md")" = "$skill" ] && grep -q "^description: ." "$plugin/skills/$skill/SKILL.md" && grep -q "^disable-model-invocation: true$" "$plugin/skills/$skill/SKILL.md" && grep -Fq "allowed-tools: Bash(\${CLAUDE_PLUGIN_ROOT}/bin/custodian:*)" "$plugin/skills/$skill/SKILL.md"'
  done
  t "the setup skill detects before it asks, records what is turned down, and no longer asks about a config from before the plugin" \
    'grep -Fq "bin/custodian\" detect --json" "$plugin/skills/setup/SKILL.md" && grep -Fq "detect --decline" "$plugin/skills/setup/SKILL.md" && ! grep -q "before the plugin\|--import" "$plugin/skills/setup/SKILL.md"'
  local named missing=""
  for named in $(grep -oh 'bin/custodian" [a-z-]*' "$plugin"/skills/*/SKILL.md | sed 's/.*" //' | LC_ALL=C sort -u); do
    "$CUSTODIAN" 2>&1 | grep -q "^  $named\( \|$\)" || missing="$missing $named"
  done
  t "every subcommand a skill runs is one the entry point lists" '[ -z "$missing" ] && [ -n "$named" ]' "not listed:$missing"
  for skill in setup audit dashboard ack; do
    t "the $skill skill says to keep ids and paths out of what the model saves" 'grep -q "out of anything you save" "$plugin/skills/$skill/SKILL.md"'
  done
  t "there are exactly four skills" '[ "$(ls "$plugin/skills" | tr "\n" " ")" = "ack audit dashboard setup " ]' "skills=$(ls "$plugin/skills" | tr "\n" " ")"
  jqt "the plugin ships exactly one hook: a session-start command inside the plugin, with a short timeout" "$plugin/hooks/hooks.json" \
    '(.hooks | keys) == ["SessionStart"] and (.hooks.SessionStart | length) == 1 and .hooks.SessionStart[0].matcher == "startup|resume" and (.hooks.SessionStart[0].hooks | length) == 1
     and (.hooks.SessionStart[0].hooks[0] | .type == "command" and (.command | startswith("\"${CLAUDE_PLUGIN_ROOT}/")) and .timeout <= 5)'
  t "the hook's command exists, is executable and is the only thing in the hooks folder" '[ -x "$(hook_command | tr -d "\"")" ] && [ "$(ls "$plugin/hooks" | tr "\n" " ")" = "hooks.json remind.sh " ]' "command=$(hook_command 2>&1) hooks=$(ls "$plugin/hooks" 2>&1 | tr "\n" " ")"
  t "the plugin still ships no servers, agents, monitors or settings" '[ ! -e "$plugin/.mcp.json" ] && [ ! -e "$plugin/agents" ] && [ ! -e "$plugin/monitors" ] && [ ! -e "$plugin/settings.json" ]'
  t "the repository carries no config, examples, report or state of mine" '[ -z "$(git -C "$plugin" ls-files | grep -E "(^|/)(config\.json|audit\.json|state\.json|dashboard\.html|custodian\.config\.json)$")" ] && ! grep -q "^- " "$plugin/templates/examples.md"'
  t "the repository ignores the file Finder leaves in a folder" 'git -C "$plugin" check-ignore -q .DS_Store'
  t "the prompt names every kind a report may hold" 'kinds_named'
  t "a suite given a group name that matches nothing fails and says so" \
    '! "$here/run.smoke.sh" no-such-group > "$SANDBOX/none" 2>&1 && grep -q "no group matches no-such-group" "$SANDBOX/none" && ! "$here/custodian.smoke.sh" no-such-group > "$SANDBOX/none" 2>&1 && grep -q "no group matches no-such-group" "$SANDBOX/none"'
}

drift_world() {
  data_world
  mk "$FAKE_HOME/Developer/acme/.claude/skills/deploy/SKILL.md" "acme deploy skill"
  mk "$FAKE_HOME/Developer/acme/vendored/CLAUDE.md" "someone else's rules"
  cfg_set '.exclude = ["~/Developer/acme/vendored"]'
  run_cmd audit
}
status_json() { run_cmd status --json; cp "$STDOUT" "$WORLD/status.json"; }

freshness() {
  drift_world
  t "the fixture audit succeeds" '[ "$rc" = 0 ]' "rc=$rc stderr=$(cat "$ERR")"
  jqt "a successful audit leaves a status that says nothing has drifted" "$DATA/status.json" \
    '.drift == {changed: [], new: [], gone: [], relinked: []} and .stale == false and .open_leaks == 0'
  t "that status is about the new report" '[ "$(jq -r .report_generated_at "$DATA/status.json")" = "$(jq -r .generated_at "$DATA/audit.json")" ] && [ "$(mode "$DATA/status.json")" = 600 ]'
  run_cmd status
  t "an untouched estate reads as fresh" '[ "$rc" = 0 ] && grep -q "fresh" "$STDOUT" && ! grep -q "stale" "$STDOUT" && grep -q "6 items" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  status_json
  jqt "fresh means no drift, no reasons and nothing to say" "$WORLD/status.json" \
    '.stale == false and .reasons == [] and .drift == {changed: [], new: [], gone: [], relinked: []} and .examples_changed == false and .open_leaks == 0 and .reminder == null and .stale_after_days == 7'

  printf 'one more rule\n' >> "$FAKE_HOME/store/CLAUDE.md"
  mk "$FAKE_HOME/store/skills/new-skill/SKILL.md" "a new skill"
  mk "$FAKE_HOME/Developer/acme/api/CLAUDE.md" "api rules"
  mk "$FAKE_HOME/store/agents/helper.md" "a new agent"
  rm "$FAKE_HOME/Developer/Personal/side/CLAUDE.md"
  lnk "$FAKE_HOME/Developer/acme/.claude/skills/deploy" "$FAKE_HOME/store/skills/deploy"
  status_json
  jqt "each kind of drift lists exactly the items it concerns" "$WORLD/status.json" \
    '.drift == {changed: ["global/CLAUDE.md"], new: ["acme/api/CLAUDE.md", "global/agents/helper", "global/skills/new-skill"], gone: ["project/side/CLAUDE.md"], relinked: ["acme/.claude/skills/deploy"]} and .stale == true and .reasons == ["drift"]'
  jqt "a new file carries what the dashboard needs to list it" "$WORLD/status.json" \
    '[.unjudged[] | select(.id == "acme/api/CLAUDE.md") | {kind, tier, scope, project: .home.project, linked_from}] == [{kind: "claude_md", tier: "project", scope: "acme", project: "api", linked_from: []}]'
  run_cmd status
  t "the text names each drifted item with its kind" \
    'grep -Eq "^  changed +global/CLAUDE.md$" "$STDOUT" && grep -Eq "^  new +acme/api/CLAUDE.md$" "$STDOUT" && grep -Eq "^  gone +project/side/CLAUDE.md$" "$STDOUT" && grep -Eq "^  relinked +acme/.claude/skills/deploy$" "$STDOUT"' "stdout=$(cat "$STDOUT")"
  t "the text and the JSON agree on the counts" 'grep -q "since then 1 changed, 3 new, 1 gone, 1 relinked" "$STDOUT" && grep -q "stale" "$STDOUT"' "stdout=$(cat "$STDOUT")"
  t "status exits 0 when the report is stale, because the exit code is not the finding" '[ "$rc" = 0 ]' "rc=$rc"
  t "status writes nothing outside the data folder or into its working directory" '[ -z "$(ls -A "$TMPD")" ]' "tmp=$(ls -A "$TMPD")"

  drift_world; cp "$FAKE_HOME/store/CLAUDE.md" "$WORLD/copy"; cat "$WORLD/copy" > "$FAKE_HOME/store/CLAUDE.md"; touch -t 203001010000 "$FAKE_HOME/store/CLAUDE.md"; status_json
  jqt "a file rewritten with the same bytes has not changed" "$WORLD/status.json" '.drift.changed == [] and .stale == false'
  mk "$FAKE_HOME/Developer/acme/vendored/.claude/skills/theirs/SKILL.md" "not mine"; status_json
  jqt "a new file under an excluded folder is not new, and is remembered as rejected" "$WORLD/status.json" \
    '.drift.new == [] and .stale == false and any(.rejected[]; endswith("/vendored/.claude/skills/theirs/SKILL.md"))'

  drift_world; printf '\n- One more global rule.\n' >> "$DATA/examples.md"; status_json
  jqt "edited examples are a reason of their own" "$WORLD/status.json" '.examples_changed == true and .reasons == ["examples"] and .stale == true'

  drift_world; clock_forward $((8 * 86400)); status_json
  jqt "a report older than the backstop is stale by age" "$WORLD/status.json" '.reasons == ["age"] and .stale == true and .age_days == 8'
  cfg_set '.stale_after_days = 30'; status_json
  jqt "stale_after_days moves the backstop" "$WORLD/status.json" '.reasons == [] and .stale == false and .stale_after_days == 30'

  drift_world; edit_report 'del(.started_at, .examples_sha256) | .items |= map(del(.sha256))'; rm "$DATA/baseline.json"
  touch -t "$(date -v+1H +%Y%m%d%H%M.%S)" "$FAKE_HOME/Developer/acme/CLAUDE.md"; status_json
  jqt "a report without fingerprints falls back to modification times" "$WORLD/status.json" '.drift.changed == ["acme/CLAUDE.md"] and .examples_changed == false'

  data_world; run_cmd status
  t "with no report the machine reads as unaudited" '[ "$rc" = 0 ] && grep -qi "unaudited" "$STDOUT" && grep -q "custodian audit" "$STDOUT" && [ ! -e "$DATA/status.json" ]' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  status_json
  jqt "unaudited is machine-readable too" "$WORLD/status.json" '.unaudited == true and .reminder == null'

  drift_world; cp "$DATA/status.json" "$WORLD/status.before"; cfg_set '.surprise = true'; run_cmd status
  t "a broken config is exit 2 and leaves the status file alone" '[ "$rc" = 2 ] && grep -q "surprise" "$ERR" && cmp -s "$DATA/status.json" "$WORLD/status.before"' "rc=$rc stderr=$(cat "$ERR")"

  audited_world; status_json
  jqt "leaks nobody has accepted are counted as open" "$WORLD/status.json" '.open_leaks == 2'
  regenerate; save "$(one "$(key_of global/skills/commit-style 0)" "intended")" '[]'
  jqt "accepting a leak lowers the count without another check" "$DATA/status.json" '.open_leaks == 1'
  status_json
  jqt "an acknowledged leak stays out of the count" "$WORLD/status.json" '.open_leaks == 1'

  drift_world; printf 'x\n' >> "$FAKE_HOME/store/CLAUDE.md"; run_cmd status
  t "status shows the line the reminder would say" \
    'grep -Fq "the reminder would say: Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. /custodian:audit re-judges everything, /custodian:dashboard shows the detail." "$STDOUT"' "stdout=$(cat "$STDOUT")"
  cfg_set '.remind = false'; run_cmd status
  t "status says why the reminder would stay silent" 'grep -q "the reminder would stay silent: reminders are off" "$STDOUT"' "stdout=$(cat "$STDOUT")"

  drift_world; mkdir -p "$DATA/failed"; printf 'batch acme: timed out after 900s\n' > "$DATA/failed/reason.txt"; run_cmd status
  t "status mentions an attempt that failed since" 'grep -q "the last attempt failed" "$STDOUT" && grep -q "~/.custodian/failed" "$STDOUT"' "stdout=$(cat "$STDOUT")"
  one_edit; run_cmd status; run_cmd status --after-audit
  t "the modes other commands use internally are not part of the status command" '[ "$rc" = 2 ] && [ "$(jq -r ".drift.changed | length" "$DATA/status.json")" = 1 ]' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd dashboard --drift-unknown
  t "nor of the dashboard command" '[ "$rc" = 2 ]' "rc=$rc stderr=$(cat "$ERR")"

  drift_world; edit_report '.generated_at = "2020-01-01T00:00:00Z"'; run_cmd status
  t "the full check removes a baseline that belongs to another report" '[ "$rc" = 0 ] && [ ! -e "$DATA/baseline.json" ]' "rc=$rc stderr=$(cat "$ERR")"

  drift_world; mkdir -p "$WORLD/old"; jq '.output = "~/old-report.json"' "$CFG" > "$WORLD/old/custodian.config.json"; cp "$DATA/audit.json" "$FAKE_HOME/old-report.json"
  rm "$DATA/config.json" "$DATA/audit.json"; run_cmd init --import "$WORLD/old/custodian.config.json"
  t "an import removes the baseline and the status of the report it replaces" '[ "$rc" = 0 ] && [ -f "$DATA/audit.json" ] && [ ! -e "$DATA/baseline.json" ] && [ ! -e "$DATA/status.json" ]' "rc=$rc stderr=$(cat "$ERR") dir=$(ls -A "$DATA" | tr "\n" " ")"
}

ran_in() { mkdir -p "$1/projects/$(printf '%s' "$2" | sed 's/[^A-Za-z0-9]/-/g')"; }
checkout() {
  mkdir -p "$1/.git"
  [ -z "${2:-}" ] || printf '[core]\n\tbare = false\n[remote "origin"]\n\turl = git@github.com:%s/%s.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n' "$2" "${1##*/}" > "$1/.git/config"
}
detect_world() {
  new_world; DATA="$FAKE_HOME/.custodian"; CFG="$DATA/config.json"
  local dev="$FAKE_HOME/Developer"
  mk "$FAKE_HOME/.claude/settings.json" "{}"; mk "$FAKE_HOME/.claude/CLAUDE.md" "global rules"
  mk "$FAKE_HOME/.claude-acme/settings.json" "{}"; account_folder "$FAKE_HOME/.claude-acme"; mkdir -p "$FAKE_HOME/.claude-notes"
  checkout "$dev/acme/web" acme-corp; checkout "$dev/acme/api" acme-corp
  mk "$dev/acme/CLAUDE.md" "acme rules"; mk "$dev/acme/web/CLAUDE.md" "web rules"
  checkout "$dev/globex/site" globex-inc; checkout "$dev/globex/app" globex-inc
  mk "$dev/globex/estate.json" '{"contextCentral": 1, "name": "Globex Shop", "repos": [{"path": "site"}, {"path": "app"}]}'
  mk "$dev/globex/site/.claude/rules/hub.md" "the map"
  checkout "$dev/Personal/side" me; checkout "$dev/Personal/tool" me; checkout "$dev/Personal/notes" me
  mk "$dev/Personal/side/CLAUDE.md" "side rules"
  mk "$dev/Personal/tool/.context-central/estate.json" '{"contextCentral": 1, "name": "tool"}'
  checkout "$dev/Personal/borrowed" stranger; mk "$dev/Personal/borrowed/CLAUDE.md" "their rules"
  checkout "$dev/Personal/plain" stranger
  ran_in "$FAKE_HOME/.claude" "$FAKE_HOME"; ran_in "$FAKE_HOME/.claude" "$dev/Personal/side"; ran_in "$FAKE_HOME/.claude" "$dev/Personal/tool/src"
  ran_in "$FAKE_HOME/.claude" "$dev/globex/site"; ran_in "$FAKE_HOME/.claude" "$dev/gone-since"; ran_in "$FAKE_HOME/.claude" "/somewhere/else"
  ran_in "$FAKE_HOME/.claude-acme" "$dev/acme/web"; ran_in "$FAKE_HOME/.claude-acme" "$dev/acme/api"; ran_in "$FAKE_HOME/.claude-acme" "$dev/acme"
  mkdir -p "$dev/Personal/tool/src" "$FAKE_HOME/Applications/Zed.app"
}

detect() {
  detect_world; run_cmd detect --json
  t "detect reads the disk and prints one document" '[ "$rc" = 0 ] && jq -e "type == \"object\"" "$STDOUT" >/dev/null' "rc=$rc stderr=$(cat "$ERR") stdout=$(cut -c1-300 "$STDOUT")"
  t "it writes nothing but the data folder's pointer" '[ "$(ls -A "$DATA" | tr "\n" " ")" = "plugin-root " ] && [ -z "$(ls -A "$LOG")" ]' "data=$(ls -A "$DATA" | tr "\n" " ")"
  jqt "the config folders in the home folder are found, with who is logged in and how many folders sessions ran in" "$STDOUT" \
    '.accounts == [{path: "~/.claude", default: true, login: "subscription", sessions: 6, works_in: []}, {path: "~/.claude-acme", default: false, login: "subscription", sessions: 3, works_in: ["~/Developer/acme"]}]'
  jqt "a folder that only looks like one by its name is not a config folder" "$STDOUT" 'all(.accounts[]; .path != "~/.claude-notes")'
  jqt "where repos live is worked out from where sessions ran" "$STDOUT" '.bases == ["~/Developer"]'
  jqt "a folder of repos with a CLAUDE.md and an account of its own is offered as a group, with that account" "$STDOUT" \
    '[.groups[] | select(.path == "~/Developer/acme")] == [{key: "group:~/Developer/acme", path: "~/Developer/acme", scope: "acme", repos: 2, why: ["a CLAUDE.md of its own", "sessions started in it", "every session under ~/.claude-acme that ran below your home folder ran in it"], slot: "~/.claude-acme"}]'
  jqt "a context-central estate that holds several repos is offered as a group named after it" "$STDOUT" \
    '[.groups[] | select(.path == "~/Developer/globex")] == [{key: "group:~/Developer/globex", path: "~/Developer/globex", scope: "globex-shop", repos: 2, why: ["a context-central estate named Globex Shop"], slot: null}]'
  jqt "a folder of unrelated repos is not, and an estate inside one repo is not" "$STDOUT" '[.groups[].path] == ["~/Developer/acme", "~/Developer/globex"]'
  jqt "the globs are the two shapes, at the depth the repos sit, each an offer with a key" "$STDOUT" \
    '.globs == [{key: "glob:~/Developer/*/*/CLAUDE.md", glob: "~/Developer/*/*/CLAUDE.md"}, {key: "glob:~/Developer/*/*/.claude", glob: "~/Developer/*/*/.claude"}]'
  jqt "a checkout whose remote is not like its neighbours, with context of its own, is offered to leave out" "$STDOUT" \
    '.foreign == [{key: "exclude:~/Developer/Personal/borrowed", path: "~/Developer/Personal/borrowed"}]'
  t "no remote's owner is printed" '! grep -q "stranger\|acme-corp\|globex-inc" "$STDOUT"'
  jqt "an editor installed in the home folder is offered with its address" "$STDOUT" '[.editors[] | select(.name == "Zed")] == [{name: "Zed", editor_url: "zed://file/{path}:{line}"}]'
  jqt "with no launcher on PATH it says so" "$STDOUT" '.launcher == null'
  jqt "with no config yet it says so" "$STDOUT" '.config == {exists: false, valid: null, starter: false, problems: []}'
  jqt "the config it proposes holds what it found and nothing it only suspects" "$STDOUT" \
    '.proposed == {tiers: [{tier: "global", path: "~/.claude"}, {tier: "client", path: "~/Developer/acme", scope: "acme"}, {tier: "client", path: "~/.claude-acme", scope: "acme"},
                           {tier: "client", path: "~/Developer/globex", scope: "globex-shop"},
                           {tier: "project", glob: "~/Developer/*/*/CLAUDE.md"}, {tier: "project", glob: "~/Developer/*/*/.claude"}],
                   slots: {acme: "~/.claude-acme"}}'
  jq .proposed "$STDOUT" > "$WORLD/proposed.json"; mkdir -p "$DATA"; cp "$WORLD/proposed.json" "$CFG"; chmod 600 "$CFG"; run_cmd dry-run --json
  jqt "that config is one the audit accepts, and it reads each group under the account found for it" "$STDOUT" \
    '[.batches[] | [.batch, .own_account]] == [["global", false], ["acme", true], ["globex-shop", false], ["unscoped", false]]'
  jqt "the hub a context-central estate keeps as a rule file is found by it" "$STDOUT" 'any(.batches[].judge[]; .sits_at == "~/Developer/globex/site/.claude/rules/hub.md")'

  run_cmd detect --json
  jqt "beside a config that holds all of it, nothing is offered again" "$STDOUT" '.config == {exists: true, valid: true, starter: false, problems: []} and .groups == [] and .globs == [] and .slots == [] and .nothing_to_add == false and (.foreign | length) == 1'
  cfg_set '.exclude = ["~/Developer/Personal/borrowed", "~/Developer/long-gone"]'; run_cmd detect --json
  jqt "with that left out too, there is nothing to add, and an exclusion that matches nothing is named" "$STDOUT" '.nothing_to_add == true and .foreign == [] and .dead_excludes == ["~/Developer/long-gone"]'
  jqt "the proposal is then the config as it stands" "$STDOUT" '.proposed == $c[0]' --slurpfile c "$CFG"
  cfg_set '.tiers |= map(select(.scope != "globex-shop"))'; run_cmd detect --json
  jqt "a group the config lacks is offered, and the proposal adds it to what is there" "$STDOUT" \
    '[.groups[].scope] == ["globex-shop"] and .proposed.exclude == $c[0].exclude and (.proposed.tiers | length) == (($c[0].tiers | length) + 1) and (.proposed.tiers[-1] == {tier: "client", path: "~/Developer/globex", scope: "globex-shop"})' --slurpfile c "$CFG"
  cfg_set '.slot = 1'; run_cmd detect --json
  jqt "a config that is not valid is said to be, with what is wrong, and nothing is proposed over it" "$STDOUT" '.config == {exists: true, valid: false, starter: false, problems: ["unknown config key: slot"]} and .proposed == null'

  detect_world; run_cmd detect --decline "group:~/Developer/globex"
  t "an offer can be turned down, which is recorded in the data folder" '[ "$rc" = 0 ] && jq -e ".schema_version == 1 and .declined == [\"group:~/Developer/globex\"]" "$DATA/setup.json" >/dev/null && [ "$(mode "$DATA/setup.json")" = 600 ]' "rc=$rc stderr=$(cat "$ERR")"
  run_cmd detect --decline "exclude:~/Developer/Personal/borrowed"; run_cmd detect --json
  jqt "what was turned down is not offered again, only counted" "$STDOUT" '[.groups[].scope] == ["acme"] and .foreign == [] and .declined == 2 and ([.proposed.tiers[] | select(.scope == "globex-shop")] == [])'
  run_cmd detect --json --all
  jqt "unless everything is asked for" "$STDOUT" '[.groups[].scope] == ["acme", "globex-shop"] and (.foreign | length) == 1'
  run_cmd detect --decline "glob:~/Developer/*/*/CLAUDE.md"; run_cmd detect --decline "glob:~/Developer/*/*/.claude"; run_cmd detect --decline "group:~/Developer/acme"; run_cmd detect --json
  jqt "a glob can be turned down like any offer, and with every offer turned down there is nothing to add" "$STDOUT" \
    '.globs == [] and .groups == [] and .foreign == [] and .nothing_to_add == true and .declined == 5 and .proposed == {tiers: [{tier: "global", path: "~/.claude"}]}'
  run_cmd detect --decline "nonsense"
  t "a key of no known kind is refused" '[ "$rc" = 2 ] && grep -q "not the key of an offer" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"

  detect_world; checkout "$FAKE_HOME/Developer/solo" solo-inc; mk "$FAKE_HOME/Developer/solo/CLAUDE.md" "solo rules"; mkdir -p "$FAKE_HOME/Developer/solo/src"
  account_folder "$FAKE_HOME/.claude-solo"; ran_in "$FAKE_HOME/.claude-solo" "$FAKE_HOME/Developer/solo"; ran_in "$FAKE_HOME/.claude-solo" "$FAKE_HOME/Developer/solo/src"
  ran_in "$FAKE_HOME/.claude-solo" "/private/tmp/scratch"; run_cmd detect --json
  jqt "a single repo that one account alone works in is offered as a group of one, read under that account" "$STDOUT" \
    '[.groups[] | select(.scope == "solo")] == [{key: "group:~/Developer/solo", path: "~/Developer/solo", scope: "solo", repos: 1, why: ["a CLAUDE.md of its own", "sessions started in it", "every session under ~/.claude-solo that ran below your home folder ran in it"], slot: "~/.claude-solo"}]
     and ([.accounts[] | select(.path == "~/.claude-solo") | [.sessions, .works_in]] == [[3, ["~/Developer/solo"]]])'
  jq .proposed "$STDOUT" > "$WORLD/proposed.json"; mkdir -p "$DATA"; cp "$WORLD/proposed.json" "$CFG"; chmod 600 "$CFG"; run_cmd dry-run --json
  jqt "and the audit then reads that repo under it" "$STDOUT" '[.batches[] | select(.batch == "solo") | [.own_account, [.judge[].sits_at]]] == [[true, ["~/Developer/solo/CLAUDE.md"]]]'

  detect_world; mkdir -p "$DATA"; CFG="$DATA/config.json"; checkout "$FAKE_HOME/Developer/other/one"; mk "$FAKE_HOME/Developer/other/one/CLAUDE.md" "one"
  config <<'EOF'
{ "tiers": [ { "tier": "global", "path": "~/.claude" }, { "tier": "client", "path": "~/Developer/other", "scope": "acme" } ] }
EOF
  chmod 600 "$CFG"; run_cmd detect --json
  jqt "a group whose name the config already uses for another folder is offered under a name of its own" "$STDOUT" \
    '[.groups[] | select(.path == "~/Developer/acme") | .scope] == ["acme-2"] and ([.proposed.tiers[] | select(.scope == "acme-2") | .path] == ["~/Developer/acme", "~/.claude-acme"]) and .proposed.slots == {"acme-2": "~/.claude-acme"}'
  detect_world; checkout "$FAKE_HOME/lonely"; mkdir -p "$FAKE_HOME/lonely/src"; ran_in "$FAKE_HOME/.claude" "$FAKE_HOME/lonely/src"; run_cmd detect --json
  jqt "a repo that sits straight in the home folder is not taken for a place where repos live" "$STDOUT" '.bases == ["~/Developer"]'
  detect_world; checkout "$FAKE_HOME/Developer/$(printf 'odd\tname')/repo"; mk "$FAKE_HOME/Developer/$(printf 'odd\tname')/CLAUDE.md" "odd"; checkout "$FAKE_HOME/Developer/$(printf 'odd\tname')/second"; run_cmd detect --json
  jqt "a folder with a tab in its name is passed over, and the rest is still found" "$STDOUT" '[.groups[].path] == ["~/Developer/acme", "~/Developer/globex"] and all(.. | strings; contains("odd") | not)'
  detect_world; checkout "$FAKE_HOME/Developer/$(printf 'bro\nken')/repo"; mk "$FAKE_HOME/Developer/$(printf 'bro\nken')/CLAUDE.md" "broken"; checkout "$FAKE_HOME/Developer/$(printf 'bro\nken')/second"
  checkout "$FAKE_HOME/Developer/Personal/$(printf 'sp\nlit')"; run_cmd detect --json
  jqt "so is a folder with a line break in its name, whether it holds repos or is one" "$STDOUT" '[.groups[].path] == ["~/Developer/acme", "~/Developer/globex"] and all(.. | strings; (contains("bro") or contains("ken") or contains("lit")) | not)'

  detect_world; auth_as "$FAKE_HOME/.claude-acme" out; run_cmd detect --json
  jqt "an account that is logged out is found and said to be" "$STDOUT" '[.accounts[] | select(.path == "~/.claude-acme") | .login] == ["is not logged in to Claude Code"]'
  detect_world; rm "$FAKE_HOME/.claude-acme/.claude.json"; run_cmd detect --json
  jqt "a folder Claude Code has never used as a config folder is found, and said to hold no login" "$STDOUT" \
    '[.accounts[] | select(.path == "~/.claude-acme") | .login] == ["has never been set up as a Claude Code config folder, so nobody is logged in there"]'
  t "it is not shown to Claude Code, which would set it up and migrate what settings it found there" \
    '[ "$(cut -f1 "$LOG.auth" | tr "\n" "|")" = "__UNSET__|" ] && [ ! -e "$FAKE_HOME/.claude-acme/.claude.json" ]' "asked=$(cut -f1 "$LOG.auth" | tr "\n" "|")"
  detect_world; rm "$BIN/claude"; run_cmd detect --json
  jqt "without Claude Code it still reads the disk, and says the logins are unknown" "$STDOUT" '[.accounts[].login] == [null, null] and (.groups | length) == 2'

  detect_world; rm -rf "$FAKE_HOME/.claude/projects"; account_folder "$FAKE_HOME/.claude-me"; auth_as "$FAKE_HOME/.claude" out
  ran_in "$FAKE_HOME/.claude-me" "$FAKE_HOME/Developer/Personal/side"; ran_in "$FAKE_HOME/.claude-me" "$FAKE_HOME/Developer/globex/site"; run_cmd detect --json
  jqt "a login kept in another folder, where the default one has none, is offered as the default slot" "$STDOUT" \
    '.default_slot == {key: "default_slot:~/.claude-me", path: "~/.claude-me"} and .proposed.default_slot == "~/.claude-me" and .proposed.tiers[0] == {tier: "global", path: "~/.claude-me"}'

  mk "$FAKE_HOME/.claude-me/CLAUDE.md" "my own rules"; run_cmd init; run_cmd detect --json
  jqt "after init has written its starter config the proposal is the same, since a starter is nobody's choice" "$STDOUT" \
    '.config.exists == true and .proposed.default_slot == "~/.claude-me" and .proposed.tiers[0] == {tier: "global", path: "~/.claude-me"} and ([.proposed.tiers[] | select(.path == "~/.claude")] == [])'
  jq .proposed "$STDOUT" > "$WORLD/proposed.json"; cat "$WORLD/proposed.json" > "$DATA/config.json"; run_cmd dry-run --json
  jqt "and the audit then reads the folder the login is kept in" "$STDOUT" 'any(.batches[].judge[]; .sits_at == "~/.claude-me/CLAUDE.md" and .tier == "global")'
  cfg_set 'del(.default_slot) | .tiers[0].path = "~/.claude" | .exclude = []'; run_cmd detect --json
  jqt "beside a config of the owner's own, the folder the login is kept in is added as a global root with the default slot" "$STDOUT" \
    '.proposed.default_slot == "~/.claude-me" and ([.proposed.tiers[] | select(.tier == "global") | .path] == ["~/.claude", "~/.claude-me"])'

  detect_world; checkout "$FAKE_HOME/Developer/acme_/shop"; checkout "$FAKE_HOME/Developer/acme_/stock"; mk "$FAKE_HOME/Developer/acme_/CLAUDE.md" "another client"; run_cmd detect --json
  jqt "two folders whose names come to the same scope are two groups, and only the first is read under its account" "$STDOUT" \
    '[.groups[] | select(.path | startswith("~/Developer/acme")) | [.path, .scope, .slot]] == [["~/Developer/acme", "acme", "~/.claude-acme"], ["~/Developer/acme_", "acme-2", null]] and .proposed.slots == {acme: "~/.claude-acme"}'

  new_world; DATA="$FAKE_HOME/.custodian"; mk "$FAKE_HOME/.claude/settings.json" "{}"; mk "$FAKE_HOME/.claude/CLAUDE.md" "global rules"
  checkout "$FAKE_HOME/work [old]/acme/web"; mk "$FAKE_HOME/work [old]/acme/web/CLAUDE.md" "web rules"; checkout "$FAKE_HOME/work [old]/acme/api"
  ran_in "$FAKE_HOME/.claude" "$FAKE_HOME/work [old]/acme/web"; run_cmd detect --json
  jqt "a place where repos live with a glob character in its name is offered so that it matches itself" "$STDOUT" \
    '[.globs[].glob] == ["~/work \\[old\\]/*/*/CLAUDE.md", "~/work \\[old\\]/*/*/.claude"]'
  jq .proposed "$STDOUT" > "$WORLD/proposed.json"; mkdir -p "$DATA"; cat "$WORLD/proposed.json" > "$DATA/config.json"; chmod 600 "$DATA/config.json"; CFG="$DATA/config.json"; run_cmd dry-run --json
  jqt "and the audit finds the repo through it" "$STDOUT" 'any(.batches[].judge[]; .sits_at == "~/work [old]/acme/web/CLAUDE.md")'

  new_world; DATA="$FAKE_HOME/.custodian"; mk "$FAKE_HOME/.claude/settings.json" "{}"
  checkout "$FAKE_HOME/code/one"; mk "$FAKE_HOME/code/one/CLAUDE.md" "one"; checkout "$FAKE_HOME/code/two"; run_cmd detect --json
  jq -c .proposed "$STDOUT" > "$WORLD/before-init.json"; run_cmd init; run_cmd detect --json
  jqt "where the default folder holds no context yet, the starter config init writes finds nothing, and the proposal is still made whole over it" "$STDOUT" \
    '.config == {exists: true, valid: true, starter: true, problems: []} and .proposed == $before[0] and (.proposed.tiers | length) == 3' --slurpfile before "$WORLD/before-init.json"
  run_cmd detect
  t "and the short list says the config is still the starter, not that it needs fixing" 'grep -q "^the config is still the starter that init wrote$" "$STDOUT" && ! grep -q "needs fixing" "$STDOUT"' "stdout=$(cat "$STDOUT")"
  CFG="$DATA/config.json"; cfg_set '.exclude = []'; run_cmd detect --json
  jqt "a config of the owner's own that finds nothing yet is well formed, and the proposal adds to it" "$STDOUT" \
    '.config == {exists: true, valid: true, starter: false, problems: []} and .proposed.exclude == [] and ([.proposed.tiers[] | select(.tier == "project") | .glob] == ["~/code/*/CLAUDE.md", "~/code/*/.claude"])'
  new_world; DATA="$FAKE_HOME/.custodian"; mk "$FAKE_HOME/.claude/settings.json" "{}"
  checkout "$FAKE_HOME/code/one"; mk "$FAKE_HOME/code/one/CLAUDE.md" "one"; checkout "$FAKE_HOME/code/two"; run_cmd detect --json
  jqt "with no session to go by, the usual places are looked in, and repos straight under one get the shallow globs" "$STDOUT" \
    '.bases == ["~/code"] and [.globs[].glob] == ["~/code/*/CLAUDE.md", "~/code/*/.claude"] and .groups == [] and .proposed.tiers == [{tier: "global", path: "~/.claude"}, {tier: "project", glob: "~/code/*/CLAUDE.md"}, {tier: "project", glob: "~/code/*/.claude"}]'

  detect_world; mkdir -p "$FAKE_HOME/bin"; EXTRA_ENV=("PATH=$BIN:$FAKE_HOME/bin:/usr/bin:/bin"); run_cmd init --launcher "$FAKE_HOME/bin"; run_cmd detect --json
  jqt "a launcher on PATH is found" "$STDOUT" '.launcher == "~/bin/custodian"'

  detect_world; run_cmd detect
  t "without --json it prints a short list, on stdout" \
    '[ "$rc" = 0 ] && grep -q "^accounts: ~/.claude (a Claude subscription, the default), ~/.claude-acme (a Claude subscription, works in ~/Developer/acme)$" "$STDOUT" && grep -q "^groups to add: acme at ~/Developer/acme (2 repos, read under ~/.claude-acme), globex-shop at ~/Developer/globex (2 repos)$" "$STDOUT" && grep -q "^repos are found by: ~/Developer/\*/\*/CLAUDE.md, ~/Developer/\*/\*/.claude$" "$STDOUT" && grep -q "^checkouts that look like someone else.s: ~/Developer/Personal/borrowed$" "$STDOUT"' \
    "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  as_system "echo Linux"; run_cmd detect
  t "anywhere but macOS it refuses, as every command does" '[ "$rc" = 2 ] && grep -q "only macOS" "$ERR"' "rc=$rc"
}

how_it_was_judged() {
  drift_world
  jqt "an audit records the model and the accounts it judged with" "$DATA/baseline.json" '(.judge | fromjson) == ["sonnet", {}, null]'
  t "and a fingerprint of the prompt and the schema it judged by" \
    '[ "$(jq -r .judge_sha256 "$DATA/baseline.json")" = "$(cat "$plugin/lib/prompt.md" "$plugin/lib/schema.json" | shasum -a 256 | cut -d" " -f1)" ]' "got=$(jq -r .judge_sha256 "$DATA/baseline.json")"
  run_cmd status --json
  jqt "a fresh report was judged as it would be now" "$STDOUT" '.stale == false and .judge_changed == false and .prompt_changed == false'
  cfg_set '.model = "opus"'; run_cmd status --json
  jqt "a changed model is a reason of its own" "$STDOUT" '.stale == true and .reasons == ["judge"] and .judge_changed == true and .roots_changed == false and .prompt_changed == false'
  run_cmd status
  t "the status says so in words" 'grep -q "stale: the model or the accounts in the config changed" "$STDOUT"' "stdout=$(cat "$STDOUT")"
  rm -rf "$LOG"/*; run_cmd audit --if-stale
  t "and an audit that runs only when stale runs" '[ "$rc" = 0 ] && [ -n "$(ls -A "$LOG")" ]' "rc=$rc stdout=$(cat "$STDOUT")"
  run_cmd status --json
  jqt "after which the report is fresh again" "$STDOUT" '.stale == false and .judge_changed == false'
  drift_world; account_folder "$FAKE_HOME/.claude-acme"; cfg_set '.slots = {"acme": "~/.claude-acme"}'; run_cmd status --json
  jqt "a group given its own account is the same reason" "$STDOUT" '.reasons == ["judge"] and .judge_changed == true'
  drift_world; account_folder "$FAKE_HOME/.claude-me"; cfg_set '.default_slot = "~/.claude-me"'; run_cmd status --json
  jqt "and so is a default slot" "$STDOUT" '.reasons == ["judge"]'
  drift_world; cfg_set '.editor_url = "zed://file/{path}:{line}" | .timeout_seconds = 60 | .remind = true'; run_cmd status --json
  jqt "a setting that does not change how files are judged is no reason" "$STDOUT" '.stale == false and .reasons == []'
  drift_world; jq '.judge_sha256 = ("0" * 64)' "$DATA/baseline.json" > "$WORLD/b.json"; cat "$WORLD/b.json" > "$DATA/baseline.json"; run_cmd status --json
  jqt "a report judged by another prompt is stale for that reason" "$STDOUT" '.stale == true and .reasons == ["prompt"] and .prompt_changed == true and .judge_changed == false'
  run_cmd status
  t "and the status says that in words" 'grep -q "stale: the prompt Custodian judges by changed" "$STDOUT"' "stdout=$(cat "$STDOUT")"
  run_cmd dashboard --no-open; view
  jqt "the page is told both" "$WORLD/view.json" '.freshness | .prompt_changed == true and .judge_changed == false'
  drift_world; jq '.schema_version = 2' "$DATA/baseline.json" > "$WORLD/b.json"; cat "$WORLD/b.json" > "$DATA/baseline.json"; run_cmd status
  t "a baseline another version wrote is not read; the status sets it aside whole and says so in one sentence" \
    '[ "$rc" = 0 ] && [ "$(grep -c "baseline.json was written by a version of Custodian this one cannot read, so it was set aside as baseline.unread.json" "$ERR")" = 1 ] && [ "$(wc -l < "$ERR" | tr -d " ")" = 1 ] && [ ! -e "$DATA/baseline.json" ] && [ "$(jq -r .schema_version "$DATA/baseline.unread.json")" = 2 ] && [ "$(mode "$DATA/baseline.unread.json")" = 600 ]' \
    "rc=$rc stderr=$(cat "$ERR") data=$(ls "$DATA" | tr "\n" " ")"
  drift_world; one_edit; jq '.schema_version = 2' "$DATA/baseline.json" > "$WORLD/b.json"; cat "$WORLD/b.json" > "$DATA/baseline.json"; run_hook
  t "before that, the hook gives up and leaves a note" 'silent && [ -s "$DATA/hook/error" ]' "$(heard)"
  run_cmd status; clock_forward 3700; run_hook
  t "and after it the hook is well again: no note, and no count it cannot check" 'silent && [ ! -e "$DATA/hook/error" ]' "$(heard)"
  run_cmd doctor
  t "doctor then has nothing to say of the hook" '[ "$rc" = 0 ]' "rc=$rc stdout=$(grep "^FIX" "$STDOUT")"
  drift_world; jq 'del(.judge, .judge_sha256)' "$DATA/baseline.json" > "$WORLD/b.json"; cat "$WORLD/b.json" > "$DATA/baseline.json"; cfg_set '.model = "opus"'; run_cmd status --json
  jqt "a baseline from before this says nothing of how it was judged" "$STDOUT" '.stale == false and .judge_changed == false and .prompt_changed == false'
  run_hook
  t "and the hook says nothing of it either" 'silent' "$(heard)"

  drift_world; cfg_set '.model = "opus"'; run_hook
  t "the hook sees a changed model, which is in the config it already reads" 'said "Custodian: The model or the accounts in your config have changed since your audit less than a day ago. $ACT"' "$(heard)"
  drift_world; one_edit; cfg_set '.model = "opus"'; run_hook
  t "beside drift it says so too" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. The model or the accounts in your config have changed too. $ACT"' "$(heard)"
  drift_world; jq '.judge_sha256 = ("0" * 64)' "$DATA/baseline.json" > "$WORLD/b.json"; cat "$WORLD/b.json" > "$DATA/baseline.json"; run_hook
  t "the hook does not look at the prompt, which would cost it a hash" 'silent' "$(heard)"
}

if_stale() {
  drift_world; rm -rf "$LOG"/*; cp "$DATA/audit.json" "$WORLD/report.before"; run_cmd audit --if-stale
  t "a fresh report is left alone, no model is called and the command says so" \
    '[ "$rc" = 0 ] && [ -z "$(ls -A "$LOG")" ] && cmp -s "$DATA/audit.json" "$WORLD/report.before" && grep -q "nothing was run" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  printf 'one more rule\n' >> "$FAKE_HOME/store/CLAUDE.md"; run_cmd audit --if-stale
  t "a stale report is judged again" '[ "$rc" = 0 ] && [ -n "$(ls -A "$LOG")" ] && grep -q "6 items" "$STDOUT" && [ "$(jq -r ".drift.changed | length" "$DATA/status.json")" = 0 ]' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  drift_world; rm -rf "$LOG"/*; edit_report '.schema_version = 2'; run_cmd audit --if-stale
  t "a report this version cannot read is no reason to refuse the audit that would replace it" \
    '[ "$rc" = 0 ] && [ -n "$(ls -A "$LOG")" ] && [ "$(jq -r .schema_version "$DATA/audit.json")" = 1 ]' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  data_world; run_cmd audit --if-stale
  t "with no report the audit runs" '[ "$rc" = 0 ] && [ -f "$DATA/audit.json" ]' "rc=$rc stderr=$(cat "$ERR")"
  drift_world; rm -rf "$LOG"/*; run_cmd audit
  t "a plain audit always runs" '[ "$rc" = 0 ] && [ -n "$(ls -A "$LOG")" ]' "rc=$rc"
  drift_world; rm -rf "$LOG"/*; cfg_set '.surprise = true'; run_cmd audit --if-stale
  t "a setup that cannot be checked is exit 2 and calls nothing" '[ "$rc" = 2 ] && [ -z "$(ls -A "$LOG")" ]' "rc=$rc stderr=$(cat "$ERR")"
}

leaks_that_went() {
  audited_world; run_cmd status --json
  jqt "the status counts the files that leak" "$STDOUT" '.open_leaks == 2'
  rm "$FAKE_HOME/store/skills/commit-style/SKILL.md"; run_cmd status --json
  jqt "a leaking file that has gone no longer counts as leaking" "$STDOUT" '.open_leaks == 1 and .drift.gone == ["global/skills/commit-style"]'
  regenerate; save "$(one "$(key_of global/CLAUDE.md 0)" "")" '[]'
  jqt "a save recounts without it too" "$DATA/status.json" '.open_leaks == 0'
  clock_forward 3700; run_hook
  t "and the reminder does not say a file still leaks" '! grep -q "leak" "$STDOUT"' "$(heard)"
}

misfiled_kinds() {
  data_world
  mk "$FAKE_HOME/Developer/acme/api/CLAUDE.md" "api rules
shared rule
"
  EXTRA_ENV=('FAKE_FILTER=.items |= map(
    if .id == "acme/CLAUDE.md" then .findings = [{line: 1, text: "acme rules", verdict: "warn", suggested_tier: "project", rationale: "About one codebase."}]
    elif .id == "acme/web/CLAUDE.md" then .findings = [{line: 1, text: "web rules", verdict: "warn", suggested_tier: "global", rationale: "Generic."}]
    elif .id == "acme/api/CLAUDE.md" then .findings = [{line: 1, text: "api rules", verdict: "warn", suggested_tier: "project", rationale: "About a sibling."}, {line: 2, text: "shared rule", verdict: "warn", suggested_tier: "global", rationale: "Generic."}]
    else . end)')
  run_cmd audit; EXTRA_ENV=(); regenerate
  jqt "a misfiled finding that suggests a broader tier makes its file too generic, any other keeps it too specific, and a file with both is too specific" "$WORLD/view.json" \
    '([.items[] | select(.id | startswith("acme/")) | {(.id): .band}] | add) == {"acme/CLAUDE.md": "warn", "acme/api/CLAUDE.md": "warn", "acme/web/CLAUDE.md": "generic"}'
  jqt "the headline counts too specific and too generic files apart" "$WORLD/view.json" '.headline | .misfiled == 2 and .generic == 1 and .leaks == 0'
  jqt "the tree's misfiled count is the too specific files alone" "$WORLD/view.json" \
    '([.tree[] | select(.node == "group:acme") | {warn, children: ([.children[] | {(.node): .warn}] | add)}] == [{warn: 2, children: {"repo:acme/api": 1, "repo:acme/web": 0}}]) and .everything.warn == 2'
  jqt "too specific files come before too generic ones" "$WORLD/view.json" '[.items[].band | select(. == "warn" or . == "generic")] == ["warn", "warn", "generic"]'
  save "$(one "$(key_of acme/api/CLAUDE.md 0)" "")" '[]'; view
  jqt "a file whose open findings are all too generic is too generic, though a too specific one in it was accepted" "$WORLD/view.json" '[.items[] | select(.id == "acme/api/CLAUDE.md") | .band] == ["generic"]'
}

freshness_view() {
  drift_world; run_cmd dashboard --no-open; view
  jqt "a fresh page says when drift was checked and that there is none" "$WORLD/view.json" \
    '.freshness | .stale == false and .reasons == [] and [.changed, .new, .gone, .relinked] == [0, 0, 0, 0] and .examples_changed == false and .stale_after_days == 7 and (.checked_at | test("^[0-9-]{10}T"))'
  jqt "on a fresh page no item is marked and nothing is unjudged" "$WORLD/view.json" '.unjudged == [] and all(.items[]; .drift == null)'
  jq -c .tree "$WORLD/view.json" > "$WORLD/tree.before"

  printf 'one more rule\n' >> "$FAKE_HOME/store/CLAUDE.md"
  mk "$FAKE_HOME/Developer/acme/api/CLAUDE.md" "api rules"
  rm "$FAKE_HOME/Developer/Personal/side/CLAUDE.md"
  lnk "$FAKE_HOME/Developer/acme/.claude/skills/deploy" "$FAKE_HOME/store/skills/deploy"
  run_cmd dashboard --no-open; view
  t "the dashboard command says what has drifted, in counts" '[ "$rc" = 0 ] && grep -q "1 changed, 1 new, 1 gone, 1 relinked" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  jqt "opening the dashboard checks drift first" "$WORLD/view.json" '.freshness | .stale == true and .reasons == ["drift"] and [.changed, .new, .gone, .relinked] == [1, 1, 1, 1]'
  jqt "a changed, a relinked and a gone item each carry their drift" "$WORLD/view.json" \
    '([.items[] | select(.drift != null) | [.id, .drift]] | sort) == [["acme/.claude/skills/deploy", "relinked"], ["global/CLAUDE.md", "changed"], ["project/side/CLAUDE.md", "gone"]]'
  jqt "a new file is listed as not yet judged, with where it lives and who loads it" "$WORLD/view.json" \
    '[.unjudged[] | {id, kind, node, top, lives_in, loaded_by, linked_from}] == [{id: "acme/api/CLAUDE.md", kind: "claude_md", node: "repo:acme/api", top: "group:acme", lives_in: "~/Developer/acme/api/CLAUDE.md", loaded_by: {tier: "project", scope: "acme"}, linked_from: []}]'
  jqt "the view model, not the page, decides how an unjudged file is shown" "$WORLD/view.json" \
    '[.unjudged[] | {band, needs, drift, entries, belongs, reason: (.rationale | type)}] == [{band: "unjudged", needs: "pass", drift: "new", entries: [], belongs: null, reason: "string"}]'
  t "drift annotates and never recounts the tree" '[ "$(jq -c .tree "$WORLD/view.json")" = "$(cat "$WORLD/tree.before")" ]'

  drift_world; printf '\n- One more global rule.\n' >> "$DATA/examples.md"; run_cmd dashboard --no-open; view
  jqt "changed examples reach the page" "$WORLD/view.json" '.freshness | .examples_changed == true and .stale == true and .reasons == ["examples"]'

  drift_world; cfg_set '.stale_after_days = 3'; run_cmd dashboard --no-open; view
  jqt "the page is told the backstop, so an open tab can age past it by itself" "$WORLD/view.json" '.freshness.stale_after_days == 3'

  drift_world; cfg_set '.surprise = true'; run_cmd dashboard --no-open; view
  t "the page still generates when drift cannot be checked" '[ "$rc" = 0 ] && grep -qi "could not be checked" "$ERR"' "rc=$rc stderr=$(cat "$ERR")"
  jqt "and it says that drift is unknown" "$WORLD/view.json" '.freshness | .stale == null and .checked_at == null and .changed == null and .stale_after_days == 7' 

  audited_world; regenerate
  jq '.report_generated_at = "2020-01-01T00:00:00Z"' "$DATA/status.json" > "$WORLD/other.json"; cat "$WORLD/other.json" > "$DATA/status.json"
  log_calls realpath
  save "$(one "$(key_of global/skills/commit-style 0)" "intended")" '[]'; view
  t "a save regenerates the page without another discovery" '[ "$rc" = 0 ] && [ "$(calls realpath)" = 0 ]' "rc=$rc realpath_calls=$(calls realpath)"
  jqt "a status about another report leaves drift unknown" "$WORLD/view.json" '.freshness | .stale == null and .checked_at == null and .stale_after_days == 7'
}

hook_command() { jq -r '.hooks.SessionStart[0].hooks[0].command' "$plugin/hooks/hooks.json" | sed "s|\${CLAUDE_PLUGIN_ROOT}|$plugin|g"; }
hook_stdin() { printf '{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"%s","hook_event_name":"SessionStart","source":"%s"}' "$WORLD/cwd" "$1"; }
as_claude_code() {
  env -i HOME="$FAKE_HOME" CUSTODIAN_HOME="$DATA" PATH="$BIN:/usr/bin:/bin" TMPDIR="$TMPD" CLAUDE_PLUGIN_ROOT="$plugin" CLAUDE_CODE_SESSION_ATTENDED=1 \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} /bin/bash -c "$1"
}
run_hook() {
  local input; input=$(hook_stdin "${1:-startup}"); [ "${1:-}" = malformed ] && input='this is {not json'
  ( cd "$WORLD/cwd" && printf '%s' "$input" | as_claude_code "$(hook_command)" >"$STDOUT" 2>"$ERR" )
  rc=$?
  [ -z "$(ls -A "$WORLD/cwd")" ] || dirtied="$dirtied $WORLD"
}
said() { [ "$rc" = 0 ] && [ ! -s "$ERR" ] && [ "$(jq -s -c . "$STDOUT" 2>/dev/null)" = "$(jq -cn --arg line "$1" '[{systemMessage: $line}]')" ]; }
silent() { [ "$rc" = 0 ] && [ ! -s "$STDOUT" ] && [ ! -s "$ERR" ]; }
heard() { echo "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR") error=$(cat "$DATA/hook/error" 2>/dev/null)"; }
ACT='/custodian:audit re-judges everything, /custodian:dashboard shows the detail.'
one_edit() { printf 'one more rule\n' >> "$FAKE_HOME/store/CLAUDE.md"; }

reminder() {
  new_world; DATA="$FAKE_HOME/.custodian"; run_hook
  t "with no data folder the hook says nothing and creates nothing" 'silent && [ ! -e "$DATA" ]' "$(heard)"
  data_world; run_hook
  t "with a config but no report it stays silent" 'silent && [ -z "$(ls "$DATA/hook" | grep "^reminded-")" ]' "$(heard)"
  log_calls jq stat shasum realpath awk; run_hook
  t "and while unaudited it looks at the config once an hour, not at every start" 'silent && [ "$(calls jq)" = 0 ]' "$(heard) jq=$(calls jq)"
  drift_world; run_hook
  t "a fresh estate with nothing leaking is silent" 'silent' "$(heard)"

  drift_world; one_edit; run_hook
  t "one edited file is one JSON document with one key and the literal sentence" \
    'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"
  t "the day's stamp and its folder are private" '[ "$(mode "$DATA/hook")" = 700 ] && [ "$(mode "$DATA"/hook/reminded-*)" = 600 ]' "modes=$(stat -f %Lp "$DATA/hook" "$DATA"/hook/* 2>&1 | tr "\n" " ")"
  run_hook
  t "a second start later the same day is silent" 'silent' "$(heard)"
  log_calls jq stat shasum realpath; run_hook
  t "having spoken, it runs none of the costly programs" 'silent && [ "$(calls jq) $(calls stat) $(calls shasum) $(calls realpath)" = "0 0 0 0" ]' "calls=$(calls jq) $(calls stat) $(calls shasum) $(calls realpath)"
  clock_forward 86400; run_hook
  t "the next day, with the drift still there, it speaks again" \
    'said "Custodian: 1 context file has changed, appeared or gone since your audit 1 day ago. $ACT"' "$(heard)"

  drift_world; one_edit; mk "$FAKE_HOME/store/skills/new-skill/SKILL.md" "a new skill"; rm "$FAKE_HOME/Developer/Personal/side/CLAUDE.md"
  lnk "$FAKE_HOME/Developer/acme/.claude/skills/deploy" "$FAKE_HOME/store/skills/deploy"; run_hook
  t "changed, new, gone and newly linked files add up to one count" \
    'said "Custodian: 4 context files have changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"
  t "the line never names a group, a folder or a file of the estate" '! grep -Eqi "acme|store|side|deploy|developer|claude\.md|skill|new-" "$STDOUT"' "$(heard)"

  data_world
  mk "$FAKE_HOME/Developer/Personal/tool/.claude/CLAUDE.md" "tool rules"
  mk "$FAKE_HOME/Developer/Personal/tool/CLAUDE.local.md" "tool local"
  cfg_set '.tiers += [{"tier": "project", "glob": "~/Developer/*/*/.claude/CLAUDE.md"}]'
  run_cmd audit; printf 'one more rule\n' >> "$FAKE_HOME/Developer/Personal/tool/CLAUDE.local.md"; run_hook
  t "an edit at the root of a repo found through its .claude folder is drift" \
    'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"

  drift_world; cp "$FAKE_HOME/store/CLAUDE.md" "$WORLD/copy"; cat "$WORLD/copy" > "$FAKE_HOME/store/CLAUDE.md"; touch -t 203001010000 "$FAKE_HOME/store/CLAUDE.md"; run_hook
  t "a file touched but byte for byte the same is silent" 'silent' "$(heard)"
  drift_world; local was; was=$(stat -f %m "$FAKE_HOME/store/CLAUDE.md"); one_edit; touch -t "$(date -r "$was" +%Y%m%d%H%M.%S)" "$FAKE_HOME/store/CLAUDE.md"; run_hook
  t "a preserved modification time with a new size is still caught" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"
  drift_world; printf '\n- One more global rule.\n' >> "$DATA/examples.md"; run_hook
  t "edited examples have a sentence of their own" 'said "Custodian: Your examples have changed since your audit less than a day ago. $ACT"' "$(heard)"
  drift_world; one_edit; printf '\n- One more global rule.\n' >> "$DATA/examples.md"; run_hook
  t "a second reason after the first says too, and gives the age once" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. Your examples have changed too. $ACT"' "$(heard)"
  drift_world; one_edit; cfg_set 'del(.exclude)'; run_hook
  t "so do changed roots" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. Your config'"'"'s roots have changed too. $ACT"' "$(heard)"
  drift_world; clock_forward $((9 * 86400)); run_hook
  t "an old report gets the backstop sentence" 'said "Custodian: Your audit is 9 days old. $ACT"' "$(heard)"
  drift_world; cfg_set '.stale_after_days = 30'; clock_forward $((9 * 86400)); run_hook
  t "stale_after_days moves the backstop for the reminder too" 'silent' "$(heard)"

  audited_world; run_hook
  t "leaks nobody has accepted are a reason to speak" 'said "Custodian: 2 files still leak. /custodian:dashboard shows where."' "$(heard)"
  audited_world; regenerate; save "$(one "$(key_of global/skills/commit-style 0)" "intended")" '[]'; run_hook
  t "an accepted leak stops counting" 'said "Custodian: 1 file still leaks. /custodian:dashboard shows where."' "$(heard)"
  audited_world; one_edit; run_hook
  t "drift and leaks share one line" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. 2 files still leak. $ACT"' "$(heard)"

  drift_world; run_hook; one_edit; clock_forward 600; log_calls jq stat shasum realpath; run_hook
  t "ten minutes after a silent check no check is run" 'silent && [ "$(calls jq) $(calls stat) $(calls shasum) $(calls realpath)" = "0 0 0 0" ]' "$(heard) calls=$(calls jq) $(calls stat) $(calls shasum) $(calls realpath)"
  clock_forward 3700; run_hook
  t "an hour after it a check is run" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"

  local n size cost_small cost_large
  for size in 3 30; do
    data_world; n=0; while [ "$n" -lt "$size" ]; do mk "$FAKE_HOME/store/skills/s$n/SKILL.md" "skill $n"; n=$((n+1)); done
    run_cmd audit; one_edit; find "$FAKE_HOME/store" "$FAKE_HOME/Developer" -type f -exec touch -t 203001010000 {} +
    log_calls jq stat shasum realpath awk; run_hook
    [ "$size" = 3 ] && cost_small="$(calls jq) $(calls stat) $(calls shasum) $(calls realpath) $(calls awk)" || cost_large="$(calls jq) $(calls stat) $(calls shasum) $(calls realpath) $(calls awk)"
  done
  t "a checkout that touches every file costs the same for a few files as for many" '[ "$cost_small" = "$cost_large" ] && [ "$cost_large" = "3 1 1 0 2" ]' "small=$cost_small large=$cost_large $(heard)"
  t "and only the file whose bytes changed is counted" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"

  drift_world; one_edit
  local i spoke=0 codes=""
  for i in 1 2 3 4 5; do
    ( cd "$WORLD/cwd" && hook_stdin startup | as_claude_code "$(hook_command)" >"$WORLD/out.$i" 2>"$WORLD/err.$i"; echo $? > "$WORLD/rc.$i" ) &
  done
  wait
  for i in 1 2 3 4 5; do codes="$codes$(cat "$WORLD/rc.$i")"; [ -s "$WORLD/out.$i" ] && spoke=$((spoke+1)); done
  t "several sessions restored together: all exit 0 and exactly one speaks" '[ "$codes" = 00000 ] && [ "$spoke" = 1 ] && [ -z "$(cat "$WORLD"/err.*)" ] && [ "$(ls "$DATA/hook" | grep -c "^reminded-")" = 1 ]' "codes=$codes spoke=$spoke err=$(cat "$WORLD"/err.*) hook=$(ls "$DATA/hook" | tr "\n" " ")"

  drift_world; one_edit; rm -f "$BIN/stat"; printf '#!/bin/bash\nexec sleep 5\n' > "$BIN/stat"; chmod +x "$BIN/stat"
  ( cd "$WORLD/cwd" && hook_stdin startup | as_claude_code "echo \$\$ > '$WORLD/hook.pid'; exec $(hook_command)" >/dev/null 2>&1 ) &
  n=0; until ls "$DATA"/hook/checked-* >/dev/null 2>&1 || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n+1)); done
  kill -KILL "$(cat "$WORLD/hook.pid")" 2>/dev/null; gone "$(cat "$WORLD/hook.pid")"
  # A child the dead hook had forked but not yet exec'ed still runs whatever is first on its PATH, so the counting happens in a folder it never sees.
  cp -R "$BIN" "$WORLD/bin-after"; BIN="$WORLD/bin-after"; log_calls jq stat shasum realpath; run_hook
  t "a check that was killed part way is not retried within the hour" 'silent && [ "$(calls jq) $(calls stat)" = "0 0" ] && ls "$DATA"/hook/checked-* >/dev/null 2>&1' "$(heard) calls=$(calls jq) $(calls stat)"

  drift_world; one_edit; mkdir -p "$DATA/hook"; : > "$DATA/hook/checked-$(( $(date +%s) / 3600 ))"; log_calls jq stat shasum realpath; run_hook
  t "a claim whose time was never written still counts for its hour" 'silent && [ "$(calls jq) $(calls stat)" = "0 0" ]' "$(heard) calls=$(calls jq) $(calls stat)"

  drift_world; one_edit; as_system "echo Linux"; run_hook
  t "outside macOS the hook is silent, speaks of nothing and records no error" 'silent && [ ! -e "$DATA/hook/error" ] && [ -z "$(ls "$DATA/hook" | grep "^reminded-")" ]' "$(heard)"
  drift_world; one_edit; run_hook; log_calls uname; run_hook
  t "the system is asked once the hour is claimed, and not again within it" 'silent && [ "$(calls uname)" = 0 ]' "$(heard) uname=$(calls uname)"
  drift_world; one_edit; log_calls uname; run_hook
  t "a check that claims its hour asks the system once" '[ "$(calls uname)" = 1 ]' "$(heard) uname=$(calls uname)"

  drift_world; one_edit; log_calls jq stat shasum realpath awk date; EXTRA_ENV=(CLAUDE_CODE_SESSION_ATTENDED=0); run_hook
  t "an unattended session is silent, runs nothing at all and does not use up the day" 'silent && [ ! -e "$DATA/hook" ] && [ "$(calls jq)$(calls stat)$(calls awk)$(calls date)" = 0000 ]' "$(heard)"
  EXTRA_ENV=(CUSTODIAN_AUDIT=1); run_hook
  t "so do the audit's own sessions" 'silent && [ ! -e "$DATA/hook" ] && [ "$(calls jq)$(calls stat)$(calls awk)$(calls date)" = 0000 ]' "$(heard)"
  EXTRA_ENV=(); run_hook compact
  t "and a session event that is not a start" 'silent && [ ! -e "$DATA/hook" ] && [ "$(calls jq)$(calls stat)$(calls awk)$(calls date)" = 0000 ]' "$(heard)"
  drift_world; one_edit; run_hook
  t "so the next attended session still hears it" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"
  drift_world; one_edit
  for n in clear compact fork; do
    run_hook "$n"
    t "a session event of $n is silent" 'silent && [ ! -e "$DATA/hook" ]' "$(heard)"
  done
  run_hook malformed
  t "input it cannot read is silent" 'silent && [ ! -e "$DATA/hook" ]' "$(heard)"
  cfg_set '.remind = false'; run_hook
  t "remind false switches it off" 'silent && [ -z "$(ls "$DATA/hook" 2>/dev/null | grep "^reminded-")" ]' "$(heard)"

  drift_world; one_edit; printf 'garbage' > "$DATA/baseline.json"; run_hook
  t "a baseline it cannot read is silence, exit 0 and a recorded error" 'silent && [ -s "$DATA/hook/error" ]' "$(heard)"
  drift_world; one_edit; printf 'garbage' > "$DATA/status.json"; run_hook
  t "a status it cannot read is silence, exit 0 and a recorded error" 'silent && [ -s "$DATA/hook/error" ]' "$(heard)"
  drift_world; printf 'garbage' > "$DATA/status.json"; run_hook; run_cmd status; clock_forward 3700; run_hook
  t "the next clean check clears the recorded error" 'silent && [ ! -e "$DATA/hook/error" ]' "$(heard)"

  drift_world; one_edit; run_cmd status; rm "$DATA/baseline.json"; run_hook
  t "without a baseline it repeats no count from an older check, since it cannot check one" 'silent' "$(heard)"
  drift_world; one_edit; run_cmd status; rm "$DATA/baseline.json"; clock_forward $((9 * 86400)); run_hook
  t "without a baseline it still knows the age of the audit" 'said "Custodian: Your audit is 9 days old. $ACT"' "$(heard)"
  audited_world; run_cmd status; rm "$DATA/baseline.json"; run_hook
  t "without a baseline it still knows what leaks, which the report and the saves decide" 'said "Custodian: 2 files still leak. /custodian:dashboard shows where."' "$(heard)"
  drift_world; one_edit; jq '.schema_version = 2' "$DATA/baseline.json" > "$WORLD/b.json"; cat "$WORLD/b.json" > "$DATA/baseline.json"; run_hook
  t "a baseline of another schema version is silence, exit 0 and a recorded error" 'silent && [ -s "$DATA/hook/error" ]' "$(heard)"
  drift_world; one_edit; run_cmd status; jq '.schema_version = 2' "$DATA/status.json" > "$WORLD/s.json"; cat "$WORLD/s.json" > "$DATA/status.json"; run_hook
  t "a status of another schema version is silence, exit 0 and a recorded error" 'silent && [ -s "$DATA/hook/error" ]' "$(heard)"
  drift_world; rm "$DATA/baseline.json" "$DATA/status.json"; clock_forward $((9 * 86400)); run_hook
  t "with neither it knows only the age of the report file" 'said "Custodian: Your audit is 9 days old. $ACT"' "$(heard)"

  drift_world; mk "$FAKE_HOME/Developer/acme/vendored/.claude/skills/theirs/SKILL.md" "not mine"; run_hook
  t "the quick check may over-report a path that discovery would reject" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"
  run_cmd status; clock_forward 86400; run_hook
  t "once a full check has rejected it, the quick check stops counting it" 'silent' "$(heard)"

  data_world; mk "$FAKE_HOME/Developer/acme/.claude/skills/deploy/SKILL.md" "acme deploy skill"; mk "$FAKE_HOME/Developer/globex/.claude/skills/ship/SKILL.md" "globex ship skill"
  cfg_set '.tiers += [{"tier": "client", "path": "~/Developer/globex", "scope": "globex"}]'
  lnk "$FAKE_HOME/Developer/acme/.claude/skills/deploy" "$FAKE_HOME/store/skills/shared"; run_cmd audit
  rm "$FAKE_HOME/store/skills/shared"; lnk "$FAKE_HOME/Developer/globex/.claude/skills/ship" "$FAKE_HOME/store/skills/shared"; run_hook
  t "a link pointed at another group's skill is drift, though no path came or went" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"

  data_world; lnk "$FAKE_HOME/notes/later.md" "$FAKE_HOME/store/agents/later.md"; run_cmd audit; mk "$FAKE_HOME/notes/later.md" "an agent that arrived later"; run_hook
  t "a dangling link that gains its target is drift" 'said "Custodian: 1 context file has changed, appeared or gone since your audit less than a day ago. $ACT"' "$(heard)"

  drift_world; printf 'their change\n' >> "$FAKE_HOME/Developer/acme/vendored/CLAUDE.md"; run_hook
  t "an edit to a file the audit leaves out is not drift" 'silent' "$(heard)"

  drift_world; rm "$DATA/examples.md"; run_hook
  t "a deleted examples file counts as changed examples" 'said "Custodian: Your examples have changed since your audit less than a day ago. $ACT"' "$(heard)"

  drift_world; cfg_set 'del(.exclude)'; run_hook
  t "roots or exclusions that differ from the audit's are a reason of their own" 'said "Custodian: Your config'"'"'s roots have changed since your audit less than a day ago. $ACT"' "$(heard)"
  status_json
  jqt "the full check gives the same reason, and sees what the change let in" "$WORLD/status.json" '.reasons == ["drift", "roots"] and .roots_changed == true and .drift.new == ["acme/vendored/CLAUDE.md"]'

  data_world; cfg_set '.tiers[0].path = "~/store/"'; run_cmd audit; mk "$FAKE_HOME/store/agents/helper.md" "a new agent"; run_hook; status_json
  jqt "with a trailing slash on a root the full check still sees a new file as new, not as rejected" "$WORLD/status.json"     '.drift.new == ["global/agents/helper"] and ([.rejected[] | select(endswith("/agents/helper.md"))] == [])'
  clock_forward 86400; run_hook
  t "so the quick check keeps counting it the next day" 'said "Custodian: 1 context file has changed, appeared or gone since your audit 1 day ago. $ACT"' "$(heard)"

  audited_world; jq '.report_generated_at = "2020-01-01T00:00:00Z" | .open_leaks = 7' "$DATA/status.json" > "$WORLD/other.json"; cat "$WORLD/other.json" > "$DATA/status.json"; run_hook
  t "a status that belongs to another report is not believed" 'silent' "$(heard)"

  drift_world; cfg_set '.stale_after_days = 1'; clock_forward 129600; run_hook
  t "one day is singular" 'said "Custodian: Your audit is 1 day old. $ACT"' "$(heard)"

  drift_world; jq '.stale_after_days = "weekly"' "$CFG" > "$WORLD/hand-edited.json"; cat "$WORLD/hand-edited.json" > "$CFG"; one_edit; run_hook
  t "a backstop that is not a number is silence, exit 0 and a recorded error" 'silent && grep -q "stale_after_days" "$DATA/hook/error"' "$(heard)"

  drift_world; one_edit; jq '.found = []' "$DATA/baseline.json" > "$WORLD/empty.json"; cat "$WORLD/empty.json" > "$DATA/baseline.json"; run_hook
  t "a baseline that lists nothing still yields one valid line" '[ "$rc" = 0 ] && [ ! -s "$ERR" ] && jq -e "keys == [\"systemMessage\"]" "$STDOUT" >/dev/null' "$(heard)"

  drift_world; printf '/somewhere/old\n' > "$DATA/plugin-root"; run_hook
  t "the hook keeps the install pointer current" '[ "$(cat "$DATA/plugin-root")" = "$plugin" ]' "pointer=$(cat "$DATA/plugin-root")"
  touch -t 202001010000 "$DATA/plugin-root"; was=$(stat -f '%i %m' "$DATA/plugin-root"); clock_forward 86400; run_hook
  t "a pointer that is already right is not rewritten" '[ "$(stat -f "%i %m" "$DATA/plugin-root")" = "$was" ]' "was=$was now=$(stat -f '%i %m' "$DATA/plugin-root")"
  t "the hook leaves nothing in the temp directory" '[ -z "$(ls -A "$TMPD")" ]' "tmp=$(ls -A "$TMPD")"
}

run_script() {
  local script=$1; shift
  ( cd "$WORLD/cwd" && env -i HOME="$FAKE_HOME" CUSTODIAN_HOME="$DATA" PATH="$BIN:/usr/bin:/bin" TMPDIR="$TMPD" \
      GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com \
      ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$plugin/scripts/$script" "$@" >"$STDOUT" 2>"$ERR" )
  rc=$?
}

commit_all() { git -C "$REPO" add -A >/dev/null && git -C "$REPO" -c user.name=Tester -c user.email=tester@example.com commit -q -m "$1"; }

release_world() {
  new_world; DATA="$FAKE_HOME/.custodian"; REPO="$WORLD/repo"
  mkdir -p "$DATA" "$REPO"; chmod 700 "$DATA"
  CFG="$DATA/config.json"
  config <<'EOF'
{ "tiers": [ { "tier": "global", "path": "~/.claude" },
             { "tier": "client", "path": "~/Developer/Initech", "scope": "initech" } ],
  "slots": { "initech": "~/.claude-initech" } }
EOF
  cp -R "$plugin/.claude-plugin" "$REPO/"
  cp "$plugin/CHANGELOG.md" "$REPO/"
  mk "$REPO/README.md" "A tool. Examples use acme and globex."
  git -C "$REPO" init -q -b main
  commit_all "feat: first commit"
}

release_check() {
  release_world; run_script release-check.sh --repo "$REPO" --quick
  t "a clean repository passes" '[ "$rc" = 0 ]' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"

  release_world; mk "$REPO/docs/notes.md" "line one
We first built this for initech and their billing team."; commit_all "docs: notes"
  run_script release-check.sh --repo "$REPO" --quick
  t "a tracked file naming a scope fails with its file and line" '[ "$rc" = 1 ] && grep -q "docs/notes.md:2" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  t "the finding never prints the text around the name" '! grep -q "billing team" "$STDOUT" "$ERR"'

  release_world; mk "$REPO/a.md" "harmless"; commit_all "docs: copied from the Initech folder"
  run_script release-check.sh --repo "$REPO" --quick
  t "a commit message naming a root folder fails with the commit" '[ "$rc" = 1 ] && grep -q "commit $(git -C "$REPO" rev-parse --short HEAD)" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"

  release_world; mk "$REPO/b.md" "see $FAKE_HOME/Developer/thing"; commit_all "docs: b"
  run_script release-check.sh --repo "$REPO" --quick
  t "a file containing my home path fails" '[ "$rc" = 1 ] && grep -q "b.md:1" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"

  # The address is split so that the release check's own e-mail rule does not flag this file.
  release_world; mk "$REPO/c.md" "mail me at someone@""initech-mail.test"; commit_all "docs: c"
  run_script release-check.sh --repo "$REPO" --quick
  t "an e-mail address that is not the author's fails" '[ "$rc" = 1 ] && grep -q "c.md:1" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"

  release_world; mk "$REPO/d.md" "slot folder .claude-initech"; commit_all "docs: d"; git -C "$REPO" rm -q d.md; commit_all "docs: remove d"
  run_script release-check.sh --repo "$REPO" --quick
  t "a name that survives only in history still fails, and says to export" '[ "$rc" = 1 ] && grep -q "history" "$STDOUT" && grep -q "release-export" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"

  release_world; jq '.plugins[0].version = "9.9.9"' "$REPO/.claude-plugin/marketplace.json" > "$WORLD/m.json" && mv "$WORLD/m.json" "$REPO/.claude-plugin/marketplace.json"; commit_all "chore: bump one manifest"
  run_script release-check.sh --repo "$REPO" --quick
  t "a version repeated in the marketplace entry fails, since the plugin manifest holds the only one" '[ "$rc" = 1 ] && grep -q "marketplace entry repeats the version" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  release_world; git -C "$REPO" rm -q CHANGELOG.md; commit_all "chore: drop the changelog"; run_script release-check.sh --repo "$REPO" --quick
  t "a release with no changelog fails" '[ "$rc" = 1 ] && grep -q "CHANGELOG.md has no section for" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  release_world; jq '.version = "9.9.9"' "$REPO/.claude-plugin/plugin.json" > "$WORLD/p.json" && mv "$WORLD/p.json" "$REPO/.claude-plugin/plugin.json"; commit_all "chore: bump"
  run_script release-check.sh --repo "$REPO" --quick
  t "a version the changelog's newest section does not name fails" '[ "$rc" = 1 ] && grep -q "newest section" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  release_world; cfg_set '.default_slot = "~/.claude-hooli"'; mk "$REPO/f.md" "my own folder is .claude-hooli"; commit_all "docs: f"
  run_script release-check.sh --repo "$REPO" --quick
  t "the folder of a default slot is a name to look for too" '[ "$rc" = 1 ] && grep -q "f.md:1" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"

  release_world; mk "$REPO/e.md" "an initech word"; commit_all "docs: e"; printf 'initech\n' > "$DATA/release-ignore"
  run_script release-check.sh --repo "$REPO" --quick
  t "an ignored name is skipped, and the check says how many without naming them" '[ "$rc" = 0 ] && grep -q "1 ignored" "$ERR" && ! grep -qi "initech" "$ERR"' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"

  for variant in "Initech rules" "INITECH_TOKEN=1" "initech_core schema" "initechcorp" "see ~/Developer/Initech/app"; do
    release_world; mk "$REPO/v.md" "$variant"; commit_all "docs: v"; run_script release-check.sh --repo "$REPO" --quick
    t "the scan catches the variant: ${variant%% *}" '[ "$rc" = 1 ] && grep -q "v.md:1" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  done
  release_world; cfg_set '.tiers += [{"tier": "client", "path": "~/Developer/qx", "scope": "qx"}]'; mk "$REPO/w.md" "the QX portal and a box of wax"; commit_all "docs: w"; run_script release-check.sh --repo "$REPO" --quick
  t "a two-letter scope is caught as a word of its own" '[ "$rc" = 1 ] && grep -q "w.md:1" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  release_world; cfg_set '.tiers += [{"tier": "client", "path": "~/Developer/qx", "scope": "qx"}]'; mk "$REPO/x.md" "the sqxl driver and a fox"; commit_all "docs: x"; run_script release-check.sh --repo "$REPO" --quick
  t "a short scope inside a longer word is left alone" '[ "$rc" = 0 ]' "rc=$rc stdout=$(cat "$STDOUT")"
  release_world; mk "$REPO/y.md" "fine"; commit_all "docs: thanks to someone@""initech-mail.test for the idea"; run_script release-check.sh --repo "$REPO" --quick
  t "an address in a commit message fails" '[ "$rc" = 1 ] && grep -q "commit $(git -C "$REPO" rev-parse --short HEAD)" "$STDOUT"' "rc=$rc stdout=$(cat "$STDOUT")"
  release_world; mk "$REPO/z.md" "under ~/Developer/Initech/app it lives"; commit_all "docs: z"; printf 'initech\n' > "$DATA/release-ignore"; run_script release-check.sh --repo "$REPO" --quick
  t "an ignored name is still caught as part of a root's path, and is never echoed" '[ "$rc" = 1 ] && grep -q "z.md:1" "$STDOUT" && ! grep -qi "initech" "$STDOUT" "$ERR"' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  release_world; printf '{}' > "$CFG"; run_script release-check.sh --repo "$REPO" --quick
  t "a config it cannot read names from stops the check" '[ "$rc" = 2 ]' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  release_world; rm -rf "$REPO/.git"; git -C "$REPO" init -q -b main; run_script release-check.sh --repo "$REPO" --quick
  t "a repository with no commits stops the check" '[ "$rc" = 2 ]' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"

  release_world; rm "$CFG"; run_script release-check.sh --repo "$REPO" --quick
  t "without a local config the check refuses to guess" '[ "$rc" = 2 ]' "rc=$rc"

  release_world; mk "$REPO/private.config.json" "{}"; printf 'private.config.json\n' > "$REPO/.gitignore"; commit_all "chore: ignore"; mk "$REPO/f.md" "initech once"; commit_all "docs: f"; git -C "$REPO" rm -q f.md; commit_all "docs: drop f"
  run_script release-export.sh "$WORLD/public" --from "$REPO" --quick
  t "an export is one commit of tracked files that passes the check" \
    '[ "$rc" = 0 ] && [ "$(git -C "$WORLD/public" rev-list --count HEAD)" = 1 ] && [ -f "$WORLD/public/README.md" ] && [ ! -e "$WORLD/public/private.config.json" ] && [ ! -e "$WORLD/public/f.md" ]' "rc=$rc stdout=$(cat "$STDOUT") stderr=$(cat "$ERR")"
  t "an export is never pushed anywhere" '[ -z "$(git -C "$WORLD/public" remote)" ]'
  run_script release-export.sh "$WORLD/public" --from "$REPO" --quick
  t "an export refuses a folder that is not empty" '[ "$rc" = 2 ]' "rc=$rc"
}

group data_folder
group init_and_import
group launcher
group doctor
group other_systems
group packaging
group audit_command
group dashboard_view
group misfiled_kinds
group keys
group acknowledge
group rule_files
group above_roots
group command_files
group imports
group freshness
group detect
group how_it_was_judged
group if_stale
group leaks_that_went
group freshness_view
group reminder
group release_check

t "no run wrote into its working directory" '[ -z "$dirtied" ]' "dirtied:$dirtied"
finish
