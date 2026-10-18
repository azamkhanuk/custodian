#!/bin/bash
set -u
set -o pipefail
ROOT=${CUSTODIAN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
. "$ROOT/lib/common.sh"
. "$ROOT/lib/jq-defs.sh"
. "$ROOT/lib/entries.sh"

OPEN=1
DRIFT=known
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0;;
    --drift-unknown) DRIFT=unknown;;
    *) die 2 "unknown argument: $arg";;
  esac
done

ensure_data_folder
REPORT=$(report_path)
PAGE="$DATA/dashboard.html"
[ -r "$REPORT" ] || die 2 "no report yet at $(abbrev "$REPORT"); run: custodian audit"
require_schema "$REPORT" "run: custodian audit"
require_state_schema "$DATA/state.json"
jq -e 'all(.items[]; has("home"))' "$REPORT" >/dev/null 2>&1 \
  || die 2 "this report was written before the dashboard existed; run: custodian audit"
for marker in "{{CSP}}" "{{STYLE}}" "{{SCRIPT}}" "{{DATA}}"; do
  [ "$(grep -oF "$marker" "$ROOT/lib/page.html" | wc -l | tr -d ' ')" = 1 ] || die 1 "page.html must contain $marker exactly once"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/custodian-page.XXXXXX") || die 1 "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT

entry_keys "$REPORT" "$WORK/keys.json" "$WORK" || die 1 "could not read the report's entries"

if [ -r "$DATA/state.json" ]; then cp "$DATA/state.json" "$WORK/state.json"; else printf '{"acknowledged": {}}' > "$WORK/state.json"; fi
reason=""
[ -r "$(dirname "$REPORT")/failed/reason.txt" ] && reason=$(cat "$(dirname "$REPORT")/failed/reason.txt")
editor_url=""
[ -r "$DATA/config.json" ] && editor_url=$(jq -r '.editor_url // empty' "$DATA/config.json" 2>/dev/null)
printf 'null' > "$WORK/status.json"
if [ "$DRIFT" = known ] && this_schema "$DATA/status.json" && describes_report "$DATA/status.json" "$REPORT"; then cp "$DATA/status.json" "$WORK/status.json"; fi

VIEW="$TIER_BREADTH$JQ_ENTRIES"'
def rank: {"fail": 0, "warn": 1, "generic": 2, "accepted": 3, "pass": 4}[.];
def abbrev: if startswith($home + "/") then "~/" + .[($home | length) + 1:] else . end;
def node:
  .home as $h
  | if $h.tier == "global" then "global"
    elif $h.tier == "client" then "group:" + $h.scope
    elif $h.tier == "project" and $h.scope != null then "repo:" + $h.scope + "/" + $h.project
    elif $h.tier == "project" then "standalone:" + $h.project
    else "external" end;
def top: if startswith("standalone:") then "standalone" elif startswith("repo:") then "group:" + (ltrimstr("repo:") | split("/")[0]) else . end;
def tally($items): {fail: ($items | map(select(.needs == "fail")) | length), warn: ($items | map(select(.band == "warn")) | length)};
def sh: "'"'"'" + gsub("'"'"'"; "'"'"'\\'"'"''"'"'") + "'"'"'";

($live[0] | map({key: .position, value: .key}) | from_entries) as $keys
| ($state[0].acknowledged // {}) as $acknowledged
| $status[0] as $checked
| (if $checked == null then {} else
    [($checked.drift.relinked[] | {key: ., value: "relinked"}), ($checked.drift.changed[] | {key: ., value: "changed"}), ($checked.drift.gone[] | {key: ., value: "gone"})] | from_entries
  end) as $drift
| [ $report[0].items | to_entries[] | .key as $i | .value as $item
    | [ $item | entries | to_entries[] | .key as $j | .value
        | . + {key: $keys["\($i)/\($j)"]}
        | . + {acknowledged: ($acknowledged[.key] | if . == null then null else {note: (.note // ""), acknowledged_at} end)} ] as $entries
    | ([$entries[] | select(.acknowledged == null) | .verdict] | if length == 0 then "pass" elif any(.[]; . == "fail") then "fail" else "warn" end) as $needs
    | ($needs == "warn" and all($entries[] | select(.acknowledged == null and .verdict == "warn"); (.suggested_tier | breadth) > ($item.tier | breadth))) as $generic
    | ($item | node) as $node
    | { id: $item.id, kind: $item.kind, by_line: ($item.kind | by_line), verdict: $item.verdict, needs: $needs,
        band: (if $generic then "generic" elif $needs != "pass" then $needs elif $item.verdict != "pass" then "accepted" else "pass" end),
        node: $node, top: ($node | top), lives_in: ($item.path | abbrev), path: $item.path,
        loaded_by: {tier: $item.tier, scope: $item.scope}, linked_from: $item.linked_from, above: ($item.above // []), imported_by: ($item.imported_by // []),
        suggested_tier: $item.suggested_tier, rationale: $item.rationale, entries: $entries, drift: $drift[$item.id],
        belongs: (if $needs == "pass" then $item.suggested_tier
                  else [$entries[] | select(.acknowledged == null and .verdict == $needs)][0].suggested_tier end),
        order: $i } ] as $items
| ([$items[].entries[].key]) as $live
| [$items[] | select(.drift != "gone")] as $present
| { generated_at: $report[0].generated_at,
    model: $report[0].model,
    claude_code_version: $report[0].claude_code_version,
    summary: ($report[0].summary + {acknowledged: ($items | map(select(.band == "accepted")) | length)}),
    headline: (tally($present) as $open | ($present | map(select(.band == "generic")) | length) as $generic
      | {leaks: $open.fail, misfiled: $open.warn, generic: $generic, settled: (($present | length) - $open.fail - $open.warn - $generic),
         accepted: ($present | map(select(.band == "accepted")) | length),
         changed: ($present | map(select(.needs == "fail" and .drift != null)) | length), gone: (($items | length) - ($present | length))}),
    ack_command: (if $data == $home + "/.custodian" then "\"$(cat \"$HOME/.custodian/plugin-root\")/bin/custodian\" ack"
                  else "CUSTODIAN_HOME=\($data | sh) \"$(cat \($data + "/plugin-root" | sh))/bin/custodian\" ack" end),
    last_failure: (if $reason == "" then null else {reason: ($reason | rtrimstr("\n"))} end),
    freshness: (if $checked == null
      then {checked_at: null, stale: null, reasons: [], stale_after_days: $backstop, changed: null, new: null, gone: null, relinked: null,
            examples_changed: null, roots_changed: null, judge_changed: null, prompt_changed: null}
      else {checked_at: $checked.checked_at, stale: $checked.stale, reasons: $checked.reasons, stale_after_days: $checked.stale_after_days,
            changed: ($checked.drift.changed | length), new: ($checked.drift.new | length), gone: ($checked.drift.gone | length),
            relinked: ($checked.drift.relinked | length), examples_changed: $checked.examples_changed, roots_changed: ($checked.roots_changed // false),
            judge_changed: ($checked.judge_changed // false), prompt_changed: ($checked.prompt_changed // false)} end),
    unjudged: [ ($checked.unjudged // [])[] | . as $found | ({home: $found.home} | node) as $node
                | {id, kind, band: "unjudged", needs: "pass", drift: "new", node: $node, top: ($node | top), path: $found.path, lives_in: ($found.path | abbrev),
                   loaded_by: {tier, scope}, linked_from, above: (.above // []), imported_by: (.imported_by // []), belongs: null, entries: [],
                   rationale: "Found after this audit, so nothing has judged it yet."} ],
    editor_url: (if $editor_url == "" then null else $editor_url end),
    tree: (
      ([ $items[] | .node | top | select(startswith("group:")) ] | unique | map({node: ., label: ltrimstr("group:")})) as $groups
      | [ {node: "global", label: "Global"} ] + $groups
        + (if any($items[]; .top == "standalone") then [{node: "standalone", label: "Standalone repos"}] else [] end)
        + (if any($items[]; .node == "external") then [{node: "external", label: "Outside every root"}] else [] end)
      | map(. as $t
          | [$items[] | select(.top == $t.node)] as $under
          | $t + tally($under | map(select(.drift != "gone")))
            + {children: [ $under | map(.node) | unique[] | select(. != $t.node) as $child
                           | {node: $child, label: ($child | sub("^standalone:"; "") | split("/") | last)} + tally([$under[] | select(.node == $child and .drift != "gone")]) ]}) ),
    everything: tally($present),
    items: ($items | sort_by([(.band | rank), .order]) | map(del(.order))),
    orphaned_acknowledgements: [ $acknowledged | to_entries[] | select(.key | IN($live[]) | not)
                                 | {key, id: .value.id, verdict: .value.verdict, note: (.value.note // ""), acknowledged_at: .value.acknowledged_at} ] }
'

jq -n -c --slurpfile report "$REPORT" --slurpfile state "$WORK/state.json" --slurpfile live "$WORK/keys.json" \
  --slurpfile status "$WORK/status.json" --argjson backstop "$(backstop_days)" --arg home "$HOME" --arg data "$DATA" --arg reason "$reason" --arg editor_url "$editor_url" "$VIEW" > "$WORK/view.json" \
  || die 1 "could not build the dashboard's view of the report"

digest() { shasum -a 256 "$1" | cut -d' ' -f1 | xxd -r -p | base64; }
csp="default-src 'none'; script-src 'sha256-$(digest "$ROOT/lib/page.js")'; style-src 'sha256-$(digest "$ROOT/lib/page.css")'; connect-src 'none'; form-action 'none'; base-uri 'none'"

# The report's text goes in last and is escaped, so nothing inside it is rescanned or can close its block.
jq -n -r --rawfile template "$ROOT/lib/page.html" --rawfile style "$ROOT/lib/page.css" --rawfile script "$ROOT/lib/page.js" \
  --rawfile view "$WORK/view.json" --arg csp "$csp" '
  def fill($marker; $value): split($marker) | join($value);
  ($view | rtrimstr("\n") | gsub("<"; "\\u003c") | gsub(">"; "\\u003e") | gsub("&"; "\\u0026")) as $data
  | $template | fill("{{CSP}}"; $csp) | fill("{{STYLE}}"; $style) | fill("{{SCRIPT}}"; $script) | fill("{{DATA}}"; $data)
' > "$WORK/page.html" && [ -s "$WORK/page.html" ] || die 1 "could not render the page; the previous one is untouched"
write_private "$PAGE" < "$WORK/page.html"

if [ "$OPEN" = 1 ]; then open "$PAGE"; else say "dashboard written to $(abbrev "$PAGE")"; fi
