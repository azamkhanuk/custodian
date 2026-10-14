#!/bin/bash
set -u
set -o pipefail
ROOT=${CUSTODIAN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
. "$ROOT/lib/common.sh"
. "$ROOT/lib/jq-defs.sh"
. "$ROOT/lib/entries.sh"
. "$ROOT/lib/expansion.sh"
. "$ROOT/lib/reminder.sh"

MODE=full
FORMAT=text
for arg in "$@"; do
  case "$arg" in
    --json) FORMAT=json;;
    --quiet) FORMAT=none;;
    --after-audit) MODE=after-audit; FORMAT=none;;
    --recount) MODE=recount; FORMAT=none;;
    *) die 2 "unknown argument: $arg";;
  esac
done

ensure_data_folder
require_config
REPORT=$(report_path)
STATUS="$DATA/status.json"
BASELINE="$DATA/baseline.json"

if [ ! -r "$REPORT" ]; then
  case "$FORMAT" in
    text) printf 'custodian: unaudited: there is no report yet. Run: custodian audit\n';;
    json) printf '{"unaudited": true, "reminder": null}\n';;
  esac
  exit 0
fi

require_schema "$REPORT" "run: custodian audit"
require_state_schema "$DATA/state.json"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/custodian-status.XXXXXX") || die 1 "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT

entry_keys "$REPORT" "$WORK/keys.json" "$WORK" || die 1 "could not read the report's entries"
if [ -r "$DATA/state.json" ]; then cp "$DATA/state.json" "$WORK/state.json"; else printf '{"acknowledged": {}}' > "$WORK/state.json"; fi
# A file that has gone cannot still leak, so the count leaves out what the last full check found gone.
JQ_OPEN_LEAKS='def open_leaks($gone): [$keys[0][] | select(.verdict == "fail" and (($state[0].acknowledged // {})[.key] == null)) | .id] | unique | map(select(IN($gone[]) | not)) | length;'

if [ "$MODE" = recount ]; then
  [ -r "$STATUS" ] && this_schema "$STATUS" && describes_report "$STATUS" "$REPORT" || exit 0
  jq --slurpfile keys "$WORK/keys.json" --slurpfile state "$WORK/state.json" "$JQ_OPEN_LEAKS"'.open_leaks = open_leaks(.drift.gone // [])' "$STATUS" > "$WORK/status.json" \
    || die 1 "could not recount the open leaks"
  write_private "$STATUS" < "$WORK/status.json"
  exit 0
fi

NOW=$(date +%s)
CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BACKSTOP=$(backstop_days)

if [ "$MODE" = after-audit ]; then
  jq -n --slurpfile report "$REPORT" --slurpfile keys "$WORK/keys.json" --slurpfile state "$WORK/state.json" \
    --argjson days "$BACKSTOP" --arg checked_at "$CHECKED_AT" "$JQ_OPEN_LEAKS"'
    { schema_version: 1, checked_at: $checked_at, report_generated_at: $report[0].generated_at,
      stale: false, reasons: [], stale_after_days: $days, age_days: 0,
      drift: {changed: [], new: [], gone: [], relinked: []}, examples_changed: false, roots_changed: false,
      judge_changed: false, prompt_changed: false,
      open_leaks: open_leaks([]), unjudged: [], rejected: [] }' > "$WORK/status.json" || die 1 "could not record the status"
  write_private "$STATUS" < "$WORK/status.json"
  exit 0
fi

if ! "$ROOT/lib/run.sh" --config "$DATA/config.json" --dry-run > "$WORK/manifest.json" 2> "$WORK/dry.err"; then
  cat "$WORK/dry.err" >&2
  die 2 "the setup needs fixing before drift can be checked"
fi

paths=()
while IFS= read -r path; do paths+=("$path"); done < <(jq -r '[.batches[].judge[].path] | unique[]' "$WORK/manifest.json")
shasum -a 256 "${paths[@]}" > "$WORK/prints.txt" 2>/dev/null
stat -f '%m %N' "${paths[@]}" > "$WORK/mtimes.txt" 2>/dev/null

EXAMPLES=$(examples_path "$DATA/config.json")
examples_print=$(shasum -a 256 "$EXAMPLES" 2>/dev/null | cut -d' ' -f1)
examples_mtime=$(stat -f %m "$EXAMPLES" 2>/dev/null || printf 0)

raw_expansion "$DATA/config.json" > "$WORK/found.txt" || die 1 "could not list the found paths"

printf 'null' > "$WORK/baseline.json"
if [ -r "$BASELINE" ]; then
  if ! this_schema "$BASELINE"; then
    # Left where it is, the hook would give up on it at every check, and only an audit would end that.
    mv -f "$BASELINE" "$DATA/baseline.unread.json" || die 1 "could not set $(abbrev "$BASELINE") aside"
    say "$(abbrev "$BASELINE") was written by a version of Custodian this one cannot read, so it was set aside as baseline.unread.json; custodian audit writes a new one"
  elif describes_report "$BASELINE" "$REPORT"; then cp "$BASELINE" "$WORK/baseline.json"; else rm -f "$BASELINE"; fi
fi

# A path an import named is no part of the expansion, so the hook counts one that now exists until this says discovery turned it down.
: > "$WORK/named.txt"
while IFS= read -r path; do
  [ -e "$path" ] && printf '%s\n' "$path" >> "$WORK/named.txt"
done < <(jq -r '(.found // [])[] | select(.import == true) | .path' "$WORK/baseline.json" 2>/dev/null)

jq -n --slurpfile report "$REPORT" --slurpfile manifest "$WORK/manifest.json" --slurpfile keys "$WORK/keys.json" \
  --slurpfile state "$WORK/state.json" --slurpfile baseline "$WORK/baseline.json" --slurpfile config "$DATA/config.json" \
  --rawfile prints "$WORK/prints.txt" --rawfile mtimes "$WORK/mtimes.txt" --rawfile found "$WORK/found.txt" --rawfile named "$WORK/named.txt" \
  --arg examples_print "$examples_print" --argjson examples_mtime "$examples_mtime" --arg judge_sha256 "$(judge_print "$ROOT")" \
  --argjson now "$NOW" --argjson days "$BACKSTOP" --arg checked_at "$CHECKED_AT" "$JQ_ROWS$JQ_ROOTS$JQ_OPEN_LEAKS"'
  (rows($prints) | map({key: .[66:], value: .[0:64]}) | from_entries) as $print
  | (rows($mtimes) | map(index(" ") as $cut | {key: .[$cut + 1:], value: (.[0:$cut] | tonumber)}) | from_entries) as $mtime
  | $report[0] as $r
  | ($r.generated_at | fromdateiso8601) as $generated
  | ([$manifest[0].batches[].judge[]] | unique_by(.path)) as $found_now
  | ($r.items | map({key: .path, value: .}) | from_entries) as $judged
  | ($found_now | map({key: .path, value: .}) | from_entries) as $present
  | [$r.items[] | select($present[.path] != null)
     | select(if .sha256 != null then $print[.path] != .sha256 else ($mtime[.path] // 0) > $generated end) | .id] as $changed
  | [$found_now[] | select($judged[.path] == null)] as $fresh
  | [$r.items[] | select($present[.path] == null) | .id] as $gone
  | [$r.items[] | . as $old | $present[.path] | select(. != null)
     | select(.tier != $old.tier or .scope != $old.scope or .linked_from != $old.linked_from or (.imported_by // []) != ($old.imported_by // [])) | $old.id] as $relinked
  | (if $r.examples_sha256 != null then $examples_print != $r.examples_sha256 else $examples_mtime > $generated end) as $examples_changed
  | ($baseline[0] != null and $baseline[0].roots != ($config[0] | roots)) as $roots_changed
  # A baseline from before these were recorded says nothing of how its report was judged.
  | ($baseline[0].judge? != null and $baseline[0].judge != ($config[0] | judged_by)) as $judge_changed
  | ($baseline[0].judge_sha256? != null and $baseline[0].judge_sha256 != $judge_sha256) as $prompt_changed
  | (($changed + $gone + $relinked | length) + ($fresh | length) > 0) as $drifted
  | (($now - $generated) > ($days * 86400)) as $too_old
  | [(if $drifted then "drift" else empty end), (if $examples_changed then "examples" else empty end),
     (if $roots_changed then "roots" else empty end), (if $judge_changed then "judge" else empty end),
     (if $prompt_changed then "prompt" else empty end), (if $too_old then "age" else empty end)] as $reasons
  | { schema_version: 1, checked_at: $checked_at, report_generated_at: $r.generated_at,
      stale: ($reasons | length > 0), reasons: $reasons, stale_after_days: $days,
      age_days: (($now - $generated) / 86400 | floor | if . < 0 then 0 else . end),
      drift: {changed: ($changed | sort), new: ([$fresh[].id] | sort), gone: ($gone | sort), relinked: ($relinked | sort)},
      examples_changed: $examples_changed, roots_changed: $roots_changed, judge_changed: $judge_changed, prompt_changed: $prompt_changed,
      open_leaks: open_leaks($gone),
      unjudged: ([$fresh[] | {id, kind, path, tier, scope, linked_from, above, imported_by, home}] | sort_by(.id)),
      rejected: ((rows($found) + rows($named) | unique) - [$found_now[].found_at[]]) }' > "$WORK/status.json" || die 1 "could not work out what has drifted"
write_private "$STATUS" < "$WORK/status.json"

[ "$FORMAT" = none ] && exit 0

read -r drifted examples_changed roots_changed too_old age_days open_leaks judge_changed < <(jq -r '
  [(.drift | map(length) | add), .examples_changed, .roots_changed, (.reasons | index("age") != null), .age_days, .open_leaks, .judge_changed] | @tsv' "$STATUS" | tr '\t' ' ')
line=$(reminder_line "$drifted" "$examples_changed" "$roots_changed" "$too_old" "$age_days" "$open_leaks" "$judge_changed")
silent=""
if ! reminders_on; then silent="reminders are off"
elif [ -z "$line" ]; then silent="there is nothing to say"
elif [ -e "$DATA/hook/reminded-$(date +%Y-%m-%d)" ]; then silent="it has already spoken today"; fi

if [ "$FORMAT" = json ]; then
  jq --arg line "$line" --arg silent "$silent" '. + {reminder: (if $silent == "" then $line else null end), reminder_silent_because: (if $silent == "" then null else $silent end)}' "$STATUS"
  exit 0
fi

jq -r --slurpfile report "$REPORT" --arg age "$(age_phrase "$age_days")" '
  $report[0].summary as $s | . as $status
  | "custodian: audited \($age): \($s.total) items, \($s.pass) pass, \($s.warn) warn, \($s.fail) fail",
    (if (.drift | map(length) | add) == 0 then "custodian: since then nothing it covers has changed"
     else "custodian: since then \(.drift.changed | length) changed, \(.drift.new | length) new, \(.drift.gone | length) gone, \(.drift.relinked | length) relinked" end),
    (.drift | to_entries[] | .key as $kind | .value[] | "  \($kind)\(" " * (9 - ($kind | length))) \(.)"),
    (if .stale then "custodian: stale: " + ([.reasons[] | {"drift": "files have drifted", "examples": "the examples changed", "roots": "the config'"'"'s roots changed",
                                                          "judge": "the model or the accounts in the config changed", "prompt": "the prompt Custodian judges by changed",
                                                          "age": "older than \($status.stale_after_days) days"}[.]] | join(", "))
     else "custodian: fresh" end)' "$STATUS"
[ -r "$(dirname "$REPORT")/failed/reason.txt" ] && printf 'custodian: the last attempt failed; its evidence is in %s\n' "$(abbrev "$(dirname "$REPORT")/failed")"
if [ -n "$silent" ]; then printf 'custodian: the reminder would stay silent: %s\n' "$silent"; else printf 'custodian: the reminder would say: %s\n' "$line"; fi
