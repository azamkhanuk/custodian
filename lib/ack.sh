#!/bin/bash
set -u
set -o pipefail
ROOT=${CUSTODIAN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
. "$ROOT/lib/common.sh"
. "$ROOT/lib/jq-defs.sh"
. "$ROOT/lib/entries.sh"

[ $# -eq 1 ] || die 2 "usage: custodian ack <payload>. Tick entries in the dashboard and use its copy button to get the payload."

ensure_data_folder
REPORT=$(report_path)
STATE="$DATA/state.json"
LOCK="$DATA/.state.lock"
[ -r "$REPORT" ] || die 2 "no report yet at $(abbrev "$REPORT"); run: custodian audit"
require_schema "$REPORT" "run: custodian audit"
require_state_schema "$STATE"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/custodian-ack.XXXXXX") || die 1 "cannot create a work directory"
release() {
  rm -rf "$WORK"
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
}
trap release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

padded=$(printf '%s' "$1" | tr '_-' '/+')
case $(( ${#padded} % 4 )) in 2) padded="$padded==";; 3) padded="$padded=";; esac
# Slurped, because jq -e alone reports on the last document and a second one could ride in behind a bad first.
printf '%s' "$padded" | base64 --decode 2>/dev/null | jq -s '
  if length == 1 and (.[0] | type == "object" and (keys - ["ack", "restore", "v"] == []) and .v == 1
    and (.ack | type) == "array" and (.restore | type) == "array"
    and all(.ack[]; type == "object" and keys == ["key", "note"] and (.key | type == "string" and test("^[0-9a-f]{12}$")) and (.note | type == "string" and length <= 500))
    and all(.restore[]; type == "string" and test("^[0-9a-f]{12}$")))
  then .[0] else error("not a payload") end' > "$WORK/payload.json" 2>/dev/null \
  || die 2 "that is not a payload this version understands. Copy it again from the dashboard."

entry_keys "$REPORT" "$WORK/keys.json" "$WORK" || die 1 "could not read the report's entries"
if [ -r "$STATE" ]; then cp "$STATE" "$WORK/state.json"; else printf '{"schema_version": 1, "acknowledged": {}}' > "$WORK/state.json"; fi

problems=$(jq -r --slurpfile live "$WORK/keys.json" --slurpfile state "$WORK/state.json" '
  ([.ack[].key | select(IN($live[0][].key) | not) | "no entry in the current report has the key \(.)"]
   + [.restore[] | select(IN(($state[0].acknowledged // {}) | keys[]) | not) | "nothing is acknowledged under the key \(.)"])[]
' "$WORK/payload.json") || die 1 "could not check the payload"
if [ -n "$problems" ]; then
  while IFS= read -r problem; do say "$problem"; done <<< "$problems"
  die 2 "nothing was saved. Regenerate the dashboard and copy the payload again."
fi

tries=0
until mkdir "$LOCK" 2>/dev/null; do
  holder=$(cat "$LOCK/pid" 2>/dev/null)
  if { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } || [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rm -rf "$LOCK"
    continue
  fi
  tries=$((tries+1))
  [ "$tries" -lt 50 ] || die 2 "another save is in progress; try again"
  sleep 0.1
done
echo $$ > "$LOCK/pid"

[ -r "$STATE" ] && cp "$STATE" "$WORK/state.json"
jq --slurpfile live "$WORK/keys.json" --slurpfile payload "$WORK/payload.json" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  ($live[0] | map({key: .key, value: {id, verdict}}) | from_entries) as $entry
  | .schema_version = 1
  | .acknowledged = ((.acknowledged // {})
      | reduce $payload[0].ack[] as $a (.; .[$a.key] = ($entry[$a.key] + {note: $a.note, acknowledged_at: $now}))
      | reduce $payload[0].restore[] as $k (.; del(.[$k])))
' "$WORK/state.json" > "$WORK/state.next.json" || die 1 "could not merge the acknowledgements; nothing was saved"
write_private "$STATE" < "$WORK/state.next.json"

"$ROOT/lib/status.sh" --recount 2>/dev/null || say "saved, but the count of open leaks could not be refreshed"
"$ROOT/lib/dashboard.sh" --no-open 2>/dev/null || say "saved, but the dashboard page could not be regenerated"
printf 'custodian: acknowledged %s, restored %s. Refresh the dashboard to see it.\n' \
  "$(jq '.ack | length' "$WORK/payload.json")" "$(jq '.restore | length' "$WORK/payload.json")"
