# What can be acknowledged, and its key. Shared so the dashboard and the ack command can never disagree.
JQ_ENTRIES="$JQ_KINDS"'
def entries:
  if .verdict == "pass" then []
  elif .kind | by_line then [.findings[] | {line, text, verdict, suggested_tier, rationale}]
  else [{line: (.evidence.line // null), text: (.evidence.text // null), verdict, suggested_tier, rationale}] end;
'

entry_keys() {
  local report=$1 out=$2 work=$3 position id verdict encoded key
  jq -r "$JQ_NORM$JQ_ENTRIES"'
    .items | to_entries[] | .key as $i | .value as $item
    | $item | entries | to_entries[]
    | ["\($i)/\(.key)", $item.id, .value.verdict, ([$item.id, .value.verdict, ((.value.text // "") | norm)] | join("\n") | @base64)] | @tsv
  ' "$report" > "$work/canonical.tsv" || return 1
  : > "$work/keys.tsv"
  while IFS=$'\t' read -r position id verdict encoded; do
    key=$(printf '%s' "$encoded" | base64 --decode | shasum -a 256 | cut -c1-12)
    printf '%s\t%s\t%s\t%s\n' "$position" "$key" "$id" "$verdict" >> "$work/keys.tsv"
  done < "$work/canonical.tsv"
  jq -R -n '[inputs | split("\t") | {position: .[0], key: .[1], id: .[2], verdict: .[3]}]' "$work/keys.tsv" > "$out"
}
