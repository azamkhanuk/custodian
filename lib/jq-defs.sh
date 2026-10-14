# jq definitions shared by the runner and the dashboard, so text is normalised the same way wherever it is compared.
JQ_ROOTS='def roots: [.tiers, (.exclude // [])] | tojson;
def judged_by: [(.model // "sonnet"), (.slots // {}), (.default_slot // null)] | tojson;'
JQ_ROWS='def rows($text): $text | split("\n") | map(select(length > 0));'
TIER_BREADTH='def breadth: {"project": 0, "client": 1, "global": 2}[.];'
JQ_ACCOUNT='def at($home): .slot | if . == null then null elif startswith($home + "/") then "~" + .[($home | length):] else . end;
def account($home): at($home) as $at | if .own_account then "account \($at)" elif $at != null then "personal account at \($at)" else "personal account" end;'
JQ_KINDS='def by_line: . == "claude_md" or . == "rule" or . == "import";'
JQ_NORM='def norm:
  gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
  | until((test("^(?:[-*+>]|#{1,6}|[0-9]+[.)]) ") | not); sub("^(?:[-*+>]|#{1,6}|[0-9]+[.)]) +"; ""));'
