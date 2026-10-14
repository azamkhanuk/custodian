#!/bin/bash
set -u
set -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
. "$here/jq-defs.sh"
. "$here/expansion.sh"
. "$here/imports.sh"
. "$here/claude-flags.sh"
. "$here/seal.sh"
TEMPLATE="$here/prompt.md"
SCHEMA="$here/schema.json"
EX_PREFLIGHT=2
EX_AGENT=3
EX_REJECTED=4
CONFIG="${CUSTODIAN_HOME:-$HOME/.custodian}/config.json"
DRY_RUN=0
WORK=""
TMP_OUT=""
LOCK=""
CHILD=""
WATCHDOG=""

cleanup() {
  # An orphaned watchdog would later signal a pid that may by then belong to something else.
  [ -n "$WATCHDOG" ] && kill "$WATCHDOG" 2>/dev/null
  if [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null; then sleep 1; kill -KILL "$CHILD" 2>/dev/null; fi
  [ -n "$TMP_OUT" ] && rm -f "$TMP_OUT"
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ -n "$LOCK" ] && rm -rf "$LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ $# -ge 2 ] || die "$EX_PREFLIGHT" "--config needs a path"; CONFIG=$2; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    *) die "$EX_PREFLIGHT" "unknown argument: $1";;
  esac
done

for tool in claude jq check-jsonschema realpath; do
  command -v "$tool" >/dev/null 2>&1 && continue
  case "$tool" in
    check-jsonschema) die "$EX_PREFLIGHT" "missing dependency: $tool (brew install check-jsonschema)";;
    *) die "$EX_PREFLIGHT" "missing dependency: $tool";;
  esac
done

HOME_REAL=$(realpath "$HOME")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/custodian.XXXXXX") || die 1 "cannot create a work directory"

CONFIG_RULES='
def scope_ok: type == "string" and test("\\A[a-z0-9][a-z0-9-]*\\z") and (IN("global", "project", "external", "unscoped") | not);
def path_ok: type == "string" and (startswith("/") or startswith("~/"));
if type != "object" then ["the config must be a JSON object"] else
  [(keys - ["canonical_store", "tiers", "slots", "default_slot", "exclude", "output", "model", "timeout_seconds", "editor_url", "remind", "stale_after_days"])[] | "unknown config key: \(.)"]
  + (if has("canonical_store") and (.canonical_store | path_ok | not) then ["canonical_store must be an absolute path or start with ~/"] else [] end)
  + (if has("output") and (.output | path_ok | not) then ["output must be an absolute path or start with ~/"] else [] end)
  + (if has("default_slot") and (.default_slot | path_ok | not) then ["default_slot must be an absolute path or start with ~/"] else [] end)
  + (if (has("editor_url") | not) then []
     elif (.editor_url | type) != "string" or (.editor_url | test("^[a-z][a-z0-9+.-]*:") | not) then ["editor_url must start with an editor scheme, such as zed://file/{path}:{line}"]
     elif (.editor_url | test("^(https?|javascript|data|vbscript|blob):"; "i")) then ["editor_url must open an editor, not a web address or a script"]
     elif (.editor_url | contains("{path}") | not) then ["editor_url must contain {path}"]
     else [] end)
  + (if has("model") and ((.model | type) != "string" or .model == "") then ["model must be a non-empty string"] else [] end)
  + (if has("timeout_seconds") and ((.timeout_seconds | type) != "number" or .timeout_seconds < 1 or (.timeout_seconds | floor) != .timeout_seconds)
     then ["timeout_seconds must be a positive whole number"] else [] end)
  + (if has("remind") and ((.remind | type) != "boolean") then ["remind must be true or false"] else [] end)
  + (if has("stale_after_days") and ((.stale_after_days | type) != "number" or .stale_after_days < 1 or (.stale_after_days | floor) != .stale_after_days)
     then ["stale_after_days must be a whole number of days, at least 1"] else [] end)
  + (if has("exclude") and ((.exclude | type) != "array" or any(.exclude[]; path_ok | not)) then ["exclude must be a list of absolute paths or paths starting with ~/"] else [] end)
  + (if (.tiers | type) != "array" or (.tiers | length) == 0 then ["tiers must be a non-empty list"] else
      [ .tiers | to_entries[] | .key as $i | .value as $e
        | if ($e | type) != "object" then "tiers[\($i)] must be an object" else
            ((($e | keys) - ["tier", "path", "glob", "scope"])[] | "unknown key in tiers[\($i)]: \(.)"),
            (($e | .path?, .glob?) | select(. != null and (path_ok | not)) | "tiers[\($i)]: \(. | tojson) must be an absolute path or start with ~/"),
            (if $e.tier == "global" then
               (if ($e.path | type) != "string" then "tiers[\($i)]: a global root needs a path" else empty end),
               (if ($e | has("scope")) or ($e | has("glob")) then "tiers[\($i)]: a global root takes only a path" else empty end)
             elif $e.tier == "client" then
               (if ($e.path | type) != "string" then "tiers[\($i)]: a client root needs a path" else empty end),
               (if ($e.scope | scope_ok | not) then "tiers[\($i)]: a client root needs a scope of lowercase letters, digits and hyphens that is not a reserved word" else empty end),
               (if $e | has("glob") then "tiers[\($i)]: a client root takes a path, not a glob" else empty end)
             elif $e.tier == "project" then
               (if (($e | has("glob")) and ($e | has("path"))) or ((($e | has("glob")) or ($e | has("path"))) | not)
                then "tiers[\($i)]: a project root takes exactly one of glob or path" else empty end),
               (if $e | has("scope") then "tiers[\($i)]: a project root takes its scope from the client root around it" else empty end)
             else "tiers[\($i)]: unknown tier \($e.tier | tojson)" end)
          end ]
    end)
  + (if (has("slots") | not) then [] elif (.slots | type) != "object" then ["slots must map a scope to a config directory"] else
      [.tiers[]? | select(type == "object" and .tier == "client") | .scope] as $scopes
      | [ .slots | to_entries[]
          | if (.key | IN($scopes[]) | not) then "slots names an unknown scope: \(.key)"
            elif (.value | path_ok | not) then "slots.\(.key) must be an absolute path or start with ~/" else empty end ]
    end)
end | .[]
'

[ -r "$CONFIG" ] || die "$EX_PREFLIGHT" "config not readable: $CONFIG"
jq -e . "$CONFIG" >/dev/null 2>&1 || die "$EX_PREFLIGHT" "config is not valid JSON: $CONFIG"
config_problems=$(jq -r "$CONFIG_RULES" "$CONFIG") || die 1 "could not check the config"
if [ -n "$config_problems" ]; then
  while IFS= read -r problem; do say "$problem"; done <<< "$config_problems"
  exit "$EX_PREFLIGHT"
fi

for marker in "{{EXAMPLES}}" "{{MANIFEST}}"; do
  [ "$(grep -oF "$marker" "$TEMPLATE" | wc -l | tr -d ' ')" = 1 ] \
    || die "$EX_PREFLIGHT" "prompt.md must contain $marker exactly once"
done

CONFIG_HOME=$(cd "$(dirname "$CONFIG")" && pwd)
OUTPUT=$(expand "$(jq -r --arg beside "$CONFIG_HOME/audit.json" '.output // $beside' "$CONFIG")")
OUTDIR=$(dirname "$OUTPUT")
EXAMPLES=$(examples_path "$CONFIG")
BASELINE="$CONFIG_HOME/baseline.json"
MODEL=$(jq -r '.model // "sonnet"' "$CONFIG")
TIMEOUT=$(jq -r '.timeout_seconds // 900' "$CONFIG")

examples_problem() {
  local counts global leakage client name=${EXAMPLES##*/}
  [ -r "$EXAMPLES" ] || { printf 'examples file not found: %s' "$(abbrev "$EXAMPLES")"; return; }
  counts=$(awk '
    incomment { if (index($0, "-->")) incomment = 0; next }
    index($0, "<!--") { if (!index($0, "-->")) incomment = 1; next }
    /^## / { heading = $0; sub(/^## +/, "", heading); sub(/ +$/, "", heading); next }
    /^([-*+]|[0-9]+[.)]) / { count[heading]++ }
    END { printf "%d %d %d", count["Correctly global"], count["Leakage"], count["Correctly client-tier"] }
  ' "$EXAMPLES")
  read -r global leakage client <<< "$counts"
  if [ "$global" -lt 3 ]; then printf '%s needs at least 3 list items under "## Correctly global" (found %s)' "$name" "$global"
  elif [ "$leakage" -lt 3 ]; then printf '%s needs at least 3 list items under "## Leakage" (found %s)' "$name" "$leakage"
  elif [ "$client" -lt 1 ] && jq -e 'any(.tiers[]; .tier == "client")' "$CONFIG" >/dev/null; then
    printf '%s needs at least 1 list item under "## Correctly client-tier", because the config has a group (found %s)' "$name" "$client"
  fi
}

problem=$(examples_problem)
if [ -n "$problem" ]; then
  if [ "$DRY_RUN" = 1 ]; then say "examples are not ready, a real run would stop here: $problem"; else die "$EX_PREFLIGHT" "$problem"; fi
fi

while IFS=$'\t' read -r scope slot; do
  [ -d "$(expand "$slot")" ] || die "$EX_PREFLIGHT" "the slot directory for scope $scope does not exist: $slot"
done < <(jq -r '.slots // {} | to_entries[] | [.key, .value] | join("\t")' "$CONFIG")
default_slot=$(jq -r '.default_slot // empty' "$CONFIG")
# Claude Code keeps the default folder's login under no name, and under another once the folder is named to it.
case "$(expand "$default_slot")" in "$HOME/.claude"|"$HOME/.claude/") die "$EX_PREFLIGHT" "default_slot is for a login kept somewhere other than ~/.claude, so leave it out";; esac
[ -z "$default_slot" ] || [ -d "$(expand "$default_slot")" ] || die "$EX_PREFLIGHT" "the default_slot directory does not exist: $default_slot"

started_at() {
  REPLY=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)
  read -r REPLY <<< "$REPLY"
}

lock_is_live() {
  local holder="" started=""
  { read -r holder; read -r started; } < "$1/pid" 2>/dev/null
  if [ -n "$holder" ]; then
    kill -0 "$holder" 2>/dev/null || return 1
    # A pid outlives its run in whatever process is given it next, so a run also records when it started.
    started_at "$holder"
    [ -z "$started" ] || [ "$REPLY" = "$started" ]
    return
  fi
  # A lock with no pid yet belongs to a run that is starting this instant, unless it is old.
  [ -z "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]
}

acquire_lock() {
  local lock="$OUTDIR/.custodian.lock" takeover="$OUTDIR/.custodian.lock.takeover"
  if ! mkdir "$lock" 2>/dev/null; then
    if lock_is_live "$lock"; then die "$EX_PREFLIGHT" "another run holds the lock at $(abbrev "$lock")"; fi
    # Two runs clearing one stale lock would each delete the other's fresh one, so only one may clear it.
    [ -z "$(find "$takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ] || rmdir "$takeover" 2>/dev/null
    mkdir "$takeover" 2>/dev/null || die "$EX_PREFLIGHT" "another run is taking over the lock at $(abbrev "$lock")"
    if lock_is_live "$lock"; then rmdir "$takeover"; die "$EX_PREFLIGHT" "another run holds the lock at $(abbrev "$lock")"; fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { rmdir "$takeover"; die "$EX_PREFLIGHT" "cannot take the lock at $(abbrev "$lock")"; }
    rmdir "$takeover"
  fi
  LOCK=$lock
  started_at $$
  printf '%s\n%s\n' "$$" "$REPLY" > "$lock/pid"
}

# With output set, the folder beside the report may be one the owner made, and only the runner's own is ever deleted.
ours() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  [ -f "$1/reason.txt" ] && return 0
  [ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ] && [ -z "$(ls -A "$1" 2>/dev/null)" ]
}

KEPT=""
keep_failure() {
  local dir=$1 reason=$2 keep="$OUTDIR/failed" name
  if ! ours "$keep"; then KEPT="the evidence was not kept, because $(abbrev "$keep") is not a folder Custodian made"; return; fi
  KEPT="kept in $(abbrev "$keep")"
  rm -rf "$keep"
  mkdir -p "$keep" && chmod 700 "$keep"
  printf '%s\n' "$reason" > "$keep/reason.txt"
  for name in prompt.md stream.jsonl stderr.txt report.rejected.json; do
    [ -e "$dir/$name" ] && cp "$dir/$name" "$keep/$name"
  done
  chmod 600 "$keep"/*
}

fail_batch() {
  local code=$1 i=$2 name=$3 reason=$4
  keep_failure "$WORK/batch-$i" "batch $name: $reason"
  die "$code" "batch $name: $reason ($KEPT)"
}

ROOT_COUNT=0
add_root() {
  local tier=$1 scope=$2 rpath=$3 announce=$4 layout=$5 real
  if excluded "$rpath"; then say "excluded: $(abbrev "$rpath")"; return; fi
  real=$(realpath "$rpath" 2>/dev/null) || { say "root cannot be resolved, skipped: $(abbrev "$rpath")"; return; }
  if excluded "$real"; then say "excluded: $(abbrev "$rpath")"; return; fi
  if awk -F '\t' -v real="$real" '$5 == real { found = 1 } END { exit !found }' "$WORK/roots.tsv"; then
    [ "$announce" = quiet ] || say "root listed twice, keeping the first: $(abbrev "$rpath")"
    return
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ROOT_COUNT" "$tier" "$scope" "$rpath" "$real" "$layout" >> "$WORK/roots.tsv"
  ROOT_COUNT=$((ROOT_COUNT+1))
}

build_roots() {
  local origin tier scope rpath written layout
  : > "$WORK/roots.tsv"
  while IFS=$'\t' read -r origin tier scope rpath written layout; do
    # Every table here is one path to a line beside tab-separated facts, and shasum and @tsv both rewrite a backslash.
    if [ "$origin" = odd ]; then say "root skipped, a backslash in its path: $(abbrev "$rpath")"; continue; fi
    if [ "$origin" = glob ]; then add_root project - "$rpath" quiet "$layout"; continue; fi
    if [ ! -d "$rpath" ]; then say "root not found, skipped: $written"; continue; fi
    add_root "$tier" "$scope" "$rpath" loud "$layout"
  done < <(config_roots "$CONFIG")
}

EXCLUDES=()
load_excludes() {
  local prefix real
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    prefix=$(expand "$prefix"); prefix=${prefix%/}
    EXCLUDES+=("$prefix")
    real=$(realpath "$prefix" 2>/dev/null) && [ "$real" != "$prefix" ] && EXCLUDES+=("$real")
  done < <(jq -r '.exclude // [] | .[]' "$CONFIG")
}

excluded() {
  local prefix
  for prefix in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
    case "$1" in "$prefix"|"$prefix"/*) return 0;; esac
  done
  return 1
}

first_link() {
  local rpath=$1 found=$2 cur part rest
  if [ -L "$rpath" ]; then printf '%s' "$rpath"; return; fi
  cur=$rpath; rest=${found#"$rpath"/}
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    cur="$cur/$part"
    if [ -L "$cur" ]; then printf '%s' "$cur"; return; fi
    case "$rest" in */*) rest=${rest#*/};; *) rest="";; esac
  done
  printf '%s' "-"
}

resolved_hit() {
  local base=$1 found=$2 canon
  printf '%s\n' "$found" >> "$WORK/seen-found.txt"
  if excluded "$found"; then say "excluded: $(abbrev "$found")"; return 1; fi
  if [ ! -e "$found" ]; then say "skipped, dangling link: $(abbrev "$found")"; return 1; fi
  canon=$(realpath "$found" 2>/dev/null) || { say "skipped, unresolvable: $(abbrev "$found")"; return 1; }
  if [ ! -f "$canon" ] || [ ! -r "$canon" ]; then say "skipped, not a readable file: $(abbrev "$found")"; return 1; fi
  case "$canon" in *"$WALK_TAB"*|*"$WALK_NL"*|*\\*) say "skipped, a tab, a line break or a backslash in its real path: $(abbrev "$found")"; return 1;; esac
  if excluded "$canon"; then say "excluded: $(abbrev "$found")"; return 1; fi
  REPLY="$found"$'\t'"$canon"$'\t'"$(first_link "$base" "$found")"
}

record_hit() {
  local ridx=$1 kind=$2 rpath=$3 found=$4
  resolved_hit "$rpath" "$found" || return 0
  printf '%s\t%s\t%s\tpattern\t-\n' "$ridx" "$kind" "$REPLY" >> "$WORK/hits.tsv"
}

# A file above the roots is resolved once, however many roots sit beneath it.
record_above() {
  local ridx tier scope rpath rreal layout dir found kind row nl=$'\n'
  local seen=$nl
  : > "$WORK/above.tsv"
  : > "$WORK/root-above.tsv"
  while IFS=$'\t' read -r ridx tier scope rpath rreal layout; do
    [ "$layout" = folder ] || continue
    dir=$rreal
    while [ "$dir" != "/" ]; do
      dir=${dir%/*}; [ -n "$dir" ] || dir=/
      printf '%s\t%s\n' "$ridx" "$dir" >> "$WORK/root-above.tsv"
      case "$seen" in *"$nl$dir$nl"*) continue;; esac
      seen="$seen$dir$nl"
      above_found "$dir" > "$WORK/matches.txt"
      while IFS= read -r found; do
        [ -n "$found" ] || continue
        case "$found" in "${dir%/}/.claude/rules/"*) kind=rule;; *) kind=claude_md;; esac
        if grep -Fxq -- "$found" "$WORK/seen-found.txt"; then
          row=$(awk -F '\t' -v found="$found" '$3 == found { print $3 FS $4 FS $5; exit }' "$WORK/hits.tsv")
          [ -z "$row" ] || printf '%s\t%s\t%s\n' "$dir" "$kind" "$row" >> "$WORK/above.tsv"
        elif resolved_hit "${dir%/}" "$found"; then
          printf '%s\t%s\t%s\n' "$dir" "$kind" "$REPLY" >> "$WORK/above.tsv"
        fi
      done < "$WORK/matches.txt"
    done
  done < "$WORK/roots.tsv"
  [ -s "$WORK/above.tsv" ] || return 0
  awk -F '\t' '
    FNR == NR { n[$1]++; row[$1, n[$1]] = $2 FS $3 FS $4 FS $5; next }
    { for (i = 1; i <= n[$2]; i++) print $1 FS row[$2, i] FS "above" FS "-" }
  ' "$WORK/above.tsv" "$WORK/root-above.tsv" >> "$WORK/hits.tsv" || die 1 "could not record the files above the roots"
}

import_note() {
  local line="$1: $(abbrev "$2")"
  grep -Fxq -- "$line" "$WORK/import-said.txt" && return
  printf '%s\n' "$line" >> "$WORK/import-said.txt"
  say "$line"
}

record_imports() {
  local level=1 holder token ext target canon
  : > "$WORK/import-edges.tsv"
  : > "$WORK/import-paths.txt"
  : > "$WORK/import-said.txt"
  awk -F '\t' '$2 == "claude_md" || $2 == "rule" { print $4 }' "$WORK/hits.tsv" | LC_ALL=C sort -u > "$WORK/holders.txt"
  cp "$WORK/holders.txt" "$WORK/import-read.txt"
  while [ "$level" -le "$IMPORT_DEPTH" ] && [ -s "$WORK/holders.txt" ]; do
    import_tokens < "$WORK/holders.txt" > "$WORK/tokens.tsv" || die 1 "could not read a file for its imports; it may have moved since discovery"
    : > "$WORK/import-next.txt"
    while IFS=$'\t' read -r holder token ext; do
      import_target "${holder%/*}" "$token"; target=$REPLY
      if [ -e "$target" ] && [ -f "$target" ]; then
        if [ -n "$ext" ]; then
          case " $IMPORT_EXTENSIONS " in *" $ext "*) ;; *) import_note "not followed, a file type Claude Code does not import" "$target"; continue;; esac
        fi
        if excluded "$target"; then import_note "excluded" "$target"; continue; fi
      fi
      case "$target" in *\\*) import_note "not followed, a backslash in its path" "$target"; continue;; esac
      # Recorded whether or not it is followed: what names nothing, a folder or a file left out today may be an import tomorrow.
      printf '%s\n' "$target" >> "$WORK/import-paths.txt"
      [ -f "$target" ] || continue
      if [ ! -r "$target" ]; then import_note "skipped, an imported file that cannot be read" "$target"; continue; fi
      canon=$(realpath "$target" 2>/dev/null) || { import_note "skipped, unresolvable" "$target"; continue; }
      case "$canon" in *"$WALK_TAB"*|*"$WALK_NL"*|*\\*) import_note "skipped, a tab, a line break or a backslash in its real path" "$target"; continue;; esac
      if excluded "$canon"; then import_note "excluded" "$target"; continue; fi
      if ! LC_ALL=C tr -d '\000' < "$canon" | cmp -s - "$canon"; then import_note "skipped, an imported file that is not text" "$target"; continue; fi
      printf '%s\t%s\t%s\n' "$holder" "$target" "$canon" >> "$WORK/import-edges.tsv"
      printf '%s\n' "$canon" >> "$WORK/import-next.txt"
    done < "$WORK/tokens.tsv"
    LC_ALL=C sort -u "$WORK/import-next.txt" | LC_ALL=C comm -13 "$WORK/import-read.txt" - > "$WORK/holders.txt"
    LC_ALL=C sort -u "$WORK/import-read.txt" "$WORK/holders.txt" > "$WORK/import-read.new" && mv "$WORK/import-read.new" "$WORK/import-read.txt"
    level=$((level+1))
  done
  [ -s "$WORK/import-edges.tsv" ] || return 0
  # Every root that reaches a file reaches what it imports, so reach follows the edges until nothing is new.
  awk -F '\t' '
    FNR == NR { if (!(($4, $1) in reached)) { reached[$4, $1] = 1; roots[$4] = roots[$4] " " $1 } next }
    { n++; holder[n] = $1; found[n] = $2; canon[n] = $3 }
    END {
      do {
        grew = 0
        for (i = 1; i <= n; i++) {
          m = split(roots[holder[i]], root, " ")
          for (k = 1; k <= m; k++) {
            if ((i, root[k]) in written) continue
            written[i, root[k]] = 1
            print root[k] FS "import" FS found[i] FS canon[i] FS "-" FS "import" FS holder[i]
            if (!((canon[i], root[k]) in reached)) { reached[canon[i], root[k]] = 1; roots[canon[i]] = roots[canon[i]] " " root[k]; grew = 1 }
          }
        }
      } while (grew)
    }
  ' "$WORK/hits.tsv" "$WORK/import-edges.tsv" > "$WORK/import-hits.tsv" || die 1 "could not record what the imports reach"
  cat "$WORK/import-hits.tsv" >> "$WORK/hits.tsv"
}

report_dangling_containers() {
  local rpath=$1 layout=$2 container entry rules
  walked_folder "$rpath" "$layout" rules; rules=$REPLY
  walked_folder "$rpath" "$layout" commands
  for container in "$rpath/skills" "$rpath/.claude/skills" "$rpath/agents" "$rpath/.claude/agents" "$rules" "$REPLY"; do
    if [ -L "$container" ] && [ ! -e "$container" ]; then
      say "skipped, dangling link: $(abbrev "$container")"
    fi
  done
  for container in skills .claude/skills; do
    for entry in "$rpath/$container"/*; do
      if [ -L "$entry" ] && [ ! -e "$entry" ]; then say "skipped, dangling link: $(abbrev "$entry")"; fi
    done
  done
}

# The block context-central writes into every hub is the same in every estate, so the judge calls it too generic one run in two.
BLOCK_START='<!-- context-central:start -->'
BLOCK_END='<!-- context-central:end -->'
BLOCKS_AWK='
  { line = $0; sub(/\r$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line) }
  line == start { from = NR; next }
  line == end && from { ranges = ranges (ranges == "" ? "" : ",") from "-" NR; from = 0 }
  END { print NR "\t" (ranges == "" ? "-" : ranges) }
'

discover() {
  local ridx tier scope rpath rreal layout spec kind pat found canon note name
  local WALK_NOTES="$WORK/walk-notes.tsv"
  : > "$WORK/hits.tsv"
  : > "$WORK/seen-found.txt"
  : > "$WALK_NOTES"
  while IFS=$'\t' read -r ridx tier scope rpath rreal layout; do
    report_dangling_containers "$rpath" "$layout"
    for spec in "${PATTERNS[@]}"; do
      kind=${spec%%:*}; pat=${spec#*:}
      # bash 3.2 keeps a process substitution's pipe open until the function returns, and breaks past about 250 of them.
      expand_pattern "$rpath" "$pat" "$layout" | LC_ALL=C sort > "$WORK/matches.txt"
      while IFS= read -r found; do
        [ -n "$found" ] && record_hit "$ridx" "$kind" "$rpath" "$found"
      done < "$WORK/matches.txt"
    done
  done < "$WORK/roots.tsv"
  record_above
  record_imports
  # A rules folder above a root may also be a root's own, and is then walked twice.
  awk '!seen[$0]++' "$WALK_NOTES" > "$WORK/notes.tsv"
  while IFS=$'\t' read -r note found name; do
    case "$note" in
      deep) say "skipped, more than $WALK_DEPTH folders below a $name folder: $(abbrev "$found")";;
      dangling) say "skipped, dangling link: $(abbrev "$found")";;
      unreadable) say "skipped, not a readable folder: $(abbrev "$found")";;
      unlisted) say "skipped, a tab, a line break or a backslash in its name: $(abbrev "$found")";;
    esac
  done < "$WORK/notes.tsv"
  [ -s "$WORK/hits.tsv" ] || die "$EX_PREFLIGHT" "nothing to audit: no context files under the configured roots"
  : > "$WORK/lines.tsv"
  while IFS= read -r canon; do
    printf '%s\t%s\n' "$canon" "$(awk -v start="$BLOCK_START" -v end="$BLOCK_END" "$BLOCKS_AWK" "$canon")" >> "$WORK/lines.tsv"
  done < <(cut -f4 "$WORK/hits.tsv" | LC_ALL=C sort -u)
}

MANIFEST_JQ="$TIER_BREADTH$JQ_KINDS"'
def rows($raw; $names):
  $raw | split("\n") | map(select(length > 0) | split("\t") as $c
    | reduce range(0; $names | length) as $i ({}; .[$names[$i]] = $c[$i]));
def nodash: if . == "-" then null else . end;
def abbrev:
  if startswith($home + "/") then "~/" + .[($home | length) + 1:]
  elif startswith($home_real + "/") then "~/" + .[($home_real | length) + 1:]
  else . end;
def expand: if startswith("~/") then $home + .[1:] else . end;
def batch_rank: if . == "global" then [0, ""] elif . == "unscoped" then [2, ""] else [1, .] end;
def within($dir): . == $dir or startswith($dir + "/");
def owner: if .tier == "global" then "global" elif .scope != null then "scope:" + .scope else "project:" + .real end;

(rows($roots_raw; ["idx", "tier", "scope", "path", "real"]) | map(.scope |= nodash)) as $listed
| ($listed | map(select(.tier == "client"))) as $clients
| ($listed | map(if .tier != "project" then . else
    . as $p | .scope = ([$clients[] | select(.real as $c | $p.real | within($c))] | sort_by(.real | length) | last | .scope)
  end)) as $roots
| (rows($hits_raw; ["root", "kind", "found", "canon", "link", "via", "by"]) | map(.link |= nodash)) as $hits
| (rows($lines_raw; ["canon", "count", "generated"]) | map({key: .canon, value: (.count | tonumber)}) | from_entries) as $lines
| (rows($lines_raw; ["canon", "count", "generated"])
   | map({key: .canon, value: (.generated | if . == null or . == "-" then [] else split(",") | map(split("-") | map(tonumber)) end)}) | from_entries) as $marked
| [ $hits | group_by(.canon)[]
    | . as $group
    | $group[0].canon as $canon
    | ([$group[] | select(.link == null and .via != "import")][0] // [$group[] | select(.via != "import")][0] // $group[0]).kind as $kind
    | ([$roots[] | select(.real as $r | $canon | startswith($r + "/"))] | sort_by(.real | length) | last) as $home
    | ([$group[] | select(.via == "above") | .root] | unique) as $beneath
    | ([$group[] | select(((.via == "above" or .via == "import") and $home != null and $home.tier == "project"
                            and (.root as $i | $roots[] | select(.idx == $i) | .real | startswith($home.real + "/"))) | not) | .root] | unique
       | if length == 0 then [$home.idx] else . end) as $reached
    | [$roots[] | select(.idx | IN($reached[]))] as $reach
    | (if any($reach[]; .tier == "global") or (($reach | map(owner) | unique | length) > 1) then {tier: "global", scope: null}
       elif any($reach[]; .tier == "client") or (($reach | map(select(.tier == "project")) | length) >= 2) then {tier: "client", scope: $reach[0].scope}
       else {tier: "project", scope: $reach[0].scope} end) as $placed
    | (if $home == null then "external"
       elif $home.tier == "global" then "global"
       elif $home.tier == "client" then $home.scope
       else ($home.scope // "project") + "/" + ($home.real | split("/") | last) end) as $label
    | (if $home == null then ($canon | abbrev) else $canon[($home.real | length) + 1:] end) as $rel
    | (if $kind == "skill" then ($rel | rtrimstr("/SKILL.md")) elif $kind == "agent" or $kind == "rule" or $kind == "command" then ($rel | rtrimstr(".md")) else $rel end) as $stem
    | { id: ($label + "/" + $stem),
        path: $canon,
        sits_at: ($canon | abbrev),
        linked_from: ([$group[] | .link | select(. != null) | abbrev] | unique),
        found_at: ([$group[].found] | unique),
        imported_by: ([$group[] | select(.via == "import") | .by | abbrev] | unique),
        above: (if $home != null then [] else [$roots[] | select(.idx | IN($beneath[])) | .path | abbrev] | sort end),
        kind: $kind,
        tier: $placed.tier,
        scope: $placed.scope,
        line_count: $lines[$canon],
        generated: (if $kind | by_line then ($marked[$canon] // []) else [] end),
        home: (if $home == null then {tier: null, scope: null, project: null, root: null}
               else {tier: $home.tier, scope: $home.scope,
                     project: (if $home.tier == "project" then ($home.real | split("/") | last) else null end),
                     root: ($home.path | abbrev)} end),
        home_at: (if $home == null then null else ($home.path | abbrev) end),
        home_tier: (if $home == null then null else $home.tier end),
        batch: (if $home == null then
                  (if $placed.tier == "global" then "global" elif $placed.scope != null then $placed.scope else "unscoped" end)
                elif $home.tier == "global" then "global"
                elif $home.scope != null then $home.scope
                else "unscoped" end) } ]
| (group_by(.id) | map(if length > 1 then map(.id += "@" + (.home_at // .sits_at)) else . end) | flatten) as $named
| ($named | sort_by([-(.tier | breadth), (.scope // ""), .id])) as $items
| [$items[] | select(.tier == "global" and .home_tier == "global" and (.kind | by_line)) | {id, sits_at, path, line_count}] as $reference
| ([$config[0].tiers[] | select(.tier == "client") | .scope] | unique) as $known_scopes
| ([$roots[] | select(.tier == "project" and .scope == null) | .real | split("/") | last] | unique) as $unscoped
| { batches: [ $items | group_by(.batch) | sort_by(.[0].batch | batch_rank)[]
    | .[0].batch as $batch
    | ($config[0].slots // {})[$batch] as $own
    # A group with an account of its own is sent nothing its sessions do not load and nothing that names another group.
    | { batch: $batch,
        slot: (($own // $config[0].default_slot) | if . == null then null else expand end),
        own_account: ($own != null),
        own_roots: (if $own == null then null
                    else [($roots[] | select(.scope == $batch) | .path, .real), ($own | expand | rtrimstr("/")), (.[] | .path, .found_at[])] | map(abbrev) | unique end),
        known_scopes: (if $own == null then $known_scopes else [$batch] end),
        unscoped_projects: (if $own == null then $unscoped else [] end),
        reference: (if $batch == "global" or $own != null then [] else $reference end),
        judge: map(del(.batch, .home_at, .home_tier)) } ] }
'

build_manifest() {
  jq -n --rawfile roots_raw "$WORK/roots.tsv" --rawfile hits_raw "$WORK/hits.tsv" \
    --rawfile lines_raw "$WORK/lines.tsv" --slurpfile config "$CONFIG" \
    --arg home "$HOME" --arg home_real "$HOME_REAL" \
    "$MANIFEST_JQ" > "$WORK/manifest.json" || die 1 "could not build the manifest"
}

stage_batch() {
  local i=$1 dir="$WORK/batch-$1" id source staged
  mkdir -p "$dir/staging" "$dir/cwd" && chmod 700 "$dir/staging" || die 1 "cannot create a staging folder"
  jq --arg staging "$dir/staging" ".batches[$i]"'
    | def staged($prefix): to_entries | map(.value + {read_path: "\($staging)/\($prefix)\(.key + 1001 | tostring | .[1:]).md"});
    .own_roots as $own
    | def mine: . as $p | any($own[]; . as $r | $p == $r or ($p | startswith($r + "/")));
      def named: if $own == null then . else map(select(mine)) + (if all(.[]; mine) then [] else ["outside this group"] end) end;
    .batch as $batch
    | del(.slot, .own_account, .own_roots)
    | .judge |= (map(.linked_from |= named | .imported_by |= named | .above |= named
                     | if $own != null and .scope != null and .scope != $batch then .scope = "outside this group" else . end)
                 | staged("")) | .reference |= staged("ref-")
  ' "$WORK/manifest.json" > "$dir/staged-manifest.json" || die 1 "could not plan the staging of batch $2"
  while IFS=$'\t' read -r id source staged; do
    cp "$source" "$staged" || die 1 "could not stage $id for batch $2; it may have moved since discovery"
  done < <(jq -r '(.judge + .reference)[] | [.id, .path, .read_path] | @tsv' "$dir/staged-manifest.json")
  jq '(.judge, .reference) |= map(del(.path, .found_at))' "$dir/staged-manifest.json" > "$dir/agent-manifest.json" \
    || die 1 "could not write the manifest of batch $2"
  fingerprint_batch "$dir" "$2"
}

fingerprint_batch() {
  local dir=$1 id source staged
  local -a copies=()
  jq -r '.judge[] | [.id, .path, .read_path] | @tsv' "$dir/staged-manifest.json" > "$dir/judge.tsv" || die 1 "could not list the files of batch $2"
  while IFS=$'\t' read -r id source staged; do copies+=("$staged"); done < "$dir/judge.tsv"
  shasum -a 256 "${copies[@]}" > "$dir/prints.txt" || die 1 "could not fingerprint batch $2"
  jq -n --rawfile judged "$dir/judge.tsv" --rawfile prints "$dir/prints.txt" "$JQ_ROWS"'
    [rows($judged), rows($prints)] | transpose
    | map((.[0] | split("\t")) as $row | {id: $row[0], path: $row[1], sha256: .[1][0:64]})
  ' > "$dir/facts.json" || die 1 "could not record the fingerprints of batch $2"
}

render_prompt() {
  local dir="$WORK/batch-$1"
  jq -n -r --rawfile template "$TEMPLATE" --rawfile examples "$EXAMPLES" --rawfile manifest "$dir/agent-manifest.json" '
    def fill($text; $marker; $value): $text | split($marker) | join($value);
    ($template | split("{{EXAMPLES}}")) | map(fill(.; "{{MANIFEST}}"; ($manifest | rtrimstr("\n")))) | join($examples | rtrimstr("\n"))
  ' > "$dir/prompt.md" && [ -s "$dir/prompt.md" ] || die 1 "could not render the prompt of batch $2"
}

SEAL_JQ='
def own: type == "object" and (((.source // "") | tostring | endswith("@builtin")) or .path == "builtin");
def release: [scan("[0-9]+") | tonumber] | .[0:3];
def seal:
  ["Read", "Glob", "Grep", "StructuredOutput"] as $allowed
  | if (.claude_code_version | type) != "string" or (.claude_code_version | release | length) != 3 then "the init event does not report its version"
    elif (.claude_code_version | release) < ($floor | release) then "the session ran on Claude Code \(.claude_code_version), older than \($floor), which the seal needs"
    elif (.tools | type) != "array" then "the init event lists no tools"
    elif ((.tools - $allowed) | length) > 0 then "the tool surface is wider than Read, Glob, Grep: \(.tools - $allowed | map(if type == "string" then . else tojson end) | join(", "))"
    elif (.mcp_servers | type) != "array" then "the init event does not report its MCP servers"
    elif (.mcp_servers | length) > 0 then "MCP servers are connected: \([.mcp_servers[] | (.name? // "unnamed") | if type == "string" then . else tojson end] | join(", "))"
    elif (.plugins | type) != "array" then "the init event does not report its plugins"
    elif any(.plugins[]; own | not)
      then "a plugin that is not Claude Code'"'"'s own is listed: \([.plugins[] | select(own | not) | if type == "object" and (.name | type) == "string" then .name else tojson end] | join(", "))"
    elif .permissionMode != "dontAsk" then "the permission mode is \(.permissionMode | tojson), expected dontAsk"
    elif (.apiKeySource | type) != "string" then "the init event does not report where its key came from"
    elif .apiKeySource != "none" then "the session used a key (\(.apiKeySource)) and not the subscription it is logged in with"
    elif has("analytics_disabled") and .analytics_disabled != true then "the session would send Claude Code'"'"'s own analytics, which the audit switches off"
    else "OK" end;
'

RESULT_JQ='
def said: (.result // "") | tostring | split("\n")[0] // "" | .[0:200];
def failure:
  if .api_error_status == 429 or (said | test("usage limit|rate limit|hit your limit"; "i"))
    then "the account has reached its usage limit, so wait for it to reset and audit again (Claude Code said: \(said))"
  elif (said | test("not logged in|/login"; "i")) then "the account is not logged in (Claude Code said: \(said))"
  elif said != "" then "the session ended in an error (Claude Code said: \(said))"
  else "the agent reported an error result (\(.subtype | tojson))" end;
'

# The init event comes at the start of the session, so a broken seal is seen before the batch has been judged and paid for.
await_seal() {
  local dir=$1
  REPLY=WAIT
  while [ "$REPLY" = WAIT ] && kill -0 "$CHILD" 2>/dev/null; do
    if [ -s "$dir/stream.jsonl" ]; then
      REPLY=$(jq -R -r -n --arg floor "$CLAUDE_CODE_FLOOR" "$SEAL_JQ"'[inputs | fromjson? | select(type == "object" and .type == "system" and .subtype == "init")][0] | if . == null then "WAIT" else seal end' "$dir/stream.jsonl" 2>/dev/null) || REPLY=WAIT
    fi
    [ "$REPLY" != WAIT ] || sleep 0.2
  done
}

stop_child() {
  local n=0
  kill "$CHILD" 2>/dev/null
  while kill -0 "$CHILD" 2>/dev/null && [ "$n" -lt 25 ]; do sleep 0.2; n=$((n+1)); done
  kill -KILL "$CHILD" 2>/dev/null
  wait "$CHILD" 2>/dev/null
  CHILD=""
}

stop_watchdog() {
  kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
  WATCHDOG=""
}

invoke_batch() {
  local i=$1 name=$2 dir="$WORK/batch-$1" status reason last_words
  sealed_env "$(jq -r ".batches[$i].slot // empty" "$WORK/manifest.json")"
  ( cd "$dir/cwd" && exec "${SEALED[@]}" CUSTODIAN_AUDIT=1 claude -p \
      --safe-mode --restricted \
      --tools "Read,Glob,Grep" --allowedTools "Read,Glob,Grep" \
      --add-dir "$dir/staging" --strict-mcp-config \
      --permission-mode dontAsk --permission-prompts none \
      --model "$MODEL" --json-schema "$(cat "$WORK/response.schema.json")" \
      --output-format stream-json --verbose --no-session-persistence \
      < "$dir/prompt.md" > "$dir/stream.jsonl" 2> "$dir/stderr.txt" ) &
  CHILD=$!
  ( trap 'kill "$nap" 2>/dev/null; exit 0' TERM
    sleep "$TIMEOUT" & nap=$!
    wait "$nap" || exit 0
    : > "$dir/timed-out"
    kill "$CHILD" 2>/dev/null
    sleep 5 & nap=$!
    wait "$nap" || exit 0
    kill -KILL "$CHILD" 2>/dev/null ) &
  WATCHDOG=$!
  await_seal "$dir"
  if [ "$REPLY" != WAIT ] && [ "$REPLY" != OK ]; then
    stop_child; stop_watchdog
    fail_batch "$EX_AGENT" "$i" "$name" "$REPLY"
  fi
  wait "$CHILD"; status=$?
  CHILD=""
  stop_watchdog
  [ ! -e "$dir/timed-out" ] || fail_batch "$EX_AGENT" "$i" "$name" "timed out after ${TIMEOUT}s"
  [ "$status" = 0 ] && return
  # Claude Code exits 1 on an error result, and that result says more than the status does.
  reason=$(jq -R -r -n "$RESULT_JQ"'[inputs | fromjson? | select(type == "object" and .type == "result" and .is_error == true)] | last | if . == null then empty else failure end' "$dir/stream.jsonl" 2>/dev/null)
  last_words=$(tail -n 1 "$dir/stderr.txt" 2>/dev/null | cut -c1-200)
  fail_batch "$EX_AGENT" "$i" "$name" "${reason:-claude exited with status $status${last_words:+: $last_words}}"
}

STREAM_RULES="$SEAL_JQ$RESULT_JQ"'
[.[] | select(.type == "system" and .subtype == "init")] as $init
| [.[] | select(.type == "result")] as $result
| if ($init | length) != 1 then "expected one init event, saw \($init | length)"
  elif ($init[0] | seal) != "OK" then $init[0] | seal
  elif ($result | length) != 1 then "expected one result event, saw \($result | length)"
  elif $result[0].subtype != "success" or $result[0].is_error != false then $result[0] | failure
  elif ($result[0].permission_denials | type) != "array" then "the result does not report its permission denials"
  elif ($result[0].permission_denials | length) > 0
    then "a tool call was refused: \([$result[0].permission_denials[] | "\(.tool_name) \(.tool_input.file_path? // .tool_input.path? // "")"] | join("; "))"
  elif ($result[0].structured_output | type) != "object" then "the result carries no structured output"
  else "OK" end
'

read_stream() {
  local i=$1 name=$2 dir="$WORK/batch-$1" verdict
  jq -R -n '[inputs | fromjson? | select(type == "object")]' "$dir/stream.jsonl" > "$dir/events.json" || die 1 "could not read the stream of batch $name"
  verdict=$(jq -r --arg floor "$CLAUDE_CODE_FLOOR" "$STREAM_RULES" "$dir/events.json") || die 1 "could not check the stream of batch $name"
  [ "$verdict" = "OK" ] || fail_batch "$EX_AGENT" "$i" "$name" "$verdict"
  jq '[.[] | select(.type == "result")][0].structured_output' "$dir/events.json" > "$dir/response.json"
  jq '[.[] | select(.type == "system" and .subtype == "init")][0] | {claude_code_version, model}' "$dir/events.json" > "$dir/init.json"
  jq 'def n: if type == "number" then . else null end;
      [.[] | select(.type == "result")][0]
      | {ms: (.duration_ms | n), output: (.usage.output_tokens? | n), usd: (.total_cost_usd | n),
         input: ([.usage.input_tokens?, .usage.cache_creation_input_tokens?, .usage.cache_read_input_tokens?] | if all(.[]; type == "number") then add else null end)}' \
    "$dir/events.json" > "$dir/used.json" || die 1 "could not read what batch $name used"
}

JUDGE_JQ="$TIER_BREADTH$JQ_NORM$JQ_KINDS"'
def distance($a; $b): ($a - $b) | if . < 0 then -. else . end;
def matches($q; $l):
  ($q | length) > 0 and ($l | length) > 0
  and ($q == $l
       or (($q | length) <= ($l | length) and ($q | length) >= 8 and ($l | contains($q)))
       or (($l | length) < ($q | length) and ($l | length) >= 8 and ($q | contains($l))));
def verified($file):
  . as $quote
  | ($quote.text | norm) as $q
  | [range(0; $file | length) | select(. as $n | matches($q; ($file[$n] | norm)))] as $hits
  | if ($hits | length) == 0 then null
    else ($hits | min_by(distance(.; $quote.line - 1))) as $at
      | $quote + {line: ($at + 1), text: ($file[$at] | rtrimstr("\r") | .[0:300])}
    end;
def generated($fact): . as $f | any(($fact.generated // [])[]; .[0] <= $f.line and $f.line <= .[1]);
def shape($fact):
  if $fact.kind | by_line then
    (if .evidence != null then "evidence must be null for \({"rule": "a rule file", "import": "an imported file"}[$fact.kind] // "a CLAUDE.md"): \(.id)" else empty end)
  else
    (if (.findings | length) > 0 then "findings must be empty for a \($fact.kind): \(.id)" else empty end),
    (if .verdict == "pass" and (.suggested_tier != null or .evidence != null) then "a pass carries no suggested tier or evidence: \(.id)" else empty end),
    (if .verdict != "pass" and .suggested_tier == null then "a \(.verdict) needs a suggested tier: \(.id)" else empty end),
    (if .verdict != "pass" and .suggested_tier != null and .evidence == null
        and (.verdict == "fail" or (.suggested_tier | breadth) <= ($fact.tier | breadth))
     then "a verdict of too specific needs evidence: \(.id)" else empty end)
  end;

($manifest[0].judge | map({key: .id, value: .}) | from_entries) as $facts
| ($manifest[0].judge | map(.id)) as $wanted
| ($response[0].items | map(.id)) as $got
| ( [$got | group_by(.)[] | select(length > 1) | "judged more than once: \(.[0])"]
  + [($wanted - $got)[] | "no judgement for: \(.)"]
  + [($got - $wanted)[] | "judgement for an id outside the batch: \(.)"] ) as $coverage
| if ($coverage | length) > 0 then {errors: $coverage, items: []} else
    [ $response[0].items[] | . as $j | $facts[$j.id] as $fact | ($lines[0][$fact.read_path] // []) as $file
      | [$j | shape($fact)] as $broken
      | if ($broken | length) > 0 then {errors: $broken}
        elif $fact.kind | by_line then
          [$j.findings[] | . as $f | (verified($file) // {missing: $f.line})] as $checked
          | if any($checked[]; has("missing")) then {errors: [$checked[] | select(has("missing")) | "quote not found in the file: \($j.id) line \(.missing)"]}
            # A block a tool wrote is no more the owner'"'"'s to move than it is theirs to reword, so "too generic" does not stand inside one. A leak does.
            else ($checked | map(select((.verdict == "warn" and (.suggested_tier | breadth) > ($fact.tier | breadth) and generated($fact)) | not)) | sort_by(.line)) as $findings
              | (if any($findings[]; .verdict == "fail") then "fail" elif ($findings | length) > 0 then "warn" else "pass" end) as $verdict
              | {item: ($j + {findings: $findings, verdict: $verdict,
                              suggested_tier: (if $verdict == "pass" then null else [$findings[] | select(.verdict == $verdict)][0].suggested_tier end)})}
            end
        elif $j.evidence == null then {item: $j}
        else ($j.evidence | verified($file)) as $evidence
          | if $evidence == null then {errors: ["quote not found in the file: \($j.id) line \($j.evidence.line)"]} else {item: ($j + {evidence: $evidence})} end
        end ] as $results
    | {errors: [$results[] | .errors // [] | .[]], items: [$results[] | .item // empty]}
  end
'

check_response() {
  local i=$1 name=$2 dir="$WORK/batch-$1" staged
  check-jsonschema --schemafile "$WORK/response.schema.json" "$dir/response.json" >/dev/null 2>&1 \
    || fail_batch "$EX_REJECTED" "$i" "$name" "the response does not match the response schema"
  # One jq per file: fed several at once, jq joins a last line that has no newline onto the next file.
  : > "$dir/lines.jsonl"
  for staged in "$dir/staging"/*.md; do
    jq -c -Rs --arg path "$staged" '{($path): (split("\n") | if .[-1] == "" then .[:-1] else . end)}' "$staged" >> "$dir/lines.jsonl" \
      || die 1 "could not read a staged file of batch $name"
  done
  jq -s 'add // {}' "$dir/lines.jsonl" > "$dir/lines.json" || die 1 "could not index the staged files of batch $name"
  jq -n --slurpfile response "$dir/response.json" --slurpfile manifest "$dir/agent-manifest.json" \
    --slurpfile lines "$dir/lines.json" "$JUDGE_JQ" > "$dir/checked.json" || die 1 "could not check the response of batch $name"
  [ "$(jq '.errors | length' "$dir/checked.json")" = 0 ] \
    || fail_batch "$EX_REJECTED" "$i" "$name" "$(jq -r '.errors | join("; ")' "$dir/checked.json")"
  rm -rf "$dir/staging"
}

assemble_report() {
  jq -n --slurpfile manifest "$WORK/manifest.json" --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg examples_sha256 "$(jq -r .sha256 "$WORK/examples.json")" \
    --arg plugin_version "$(jq -r '.version // empty' "$here/../.claude-plugin/plugin.json" 2>/dev/null)" "$TIER_BREADTH"'
    [inputs] as $batches
    | def total(f): [$batches[] | .used | f] | if any(.[]; . == null) then null else add end;
    ($batches | map(.response.items[]) | map({key: .id, value: .}) | from_entries) as $judged
    | ($batches | map(.facts[]) | map({key: .id, value: .sha256}) | from_entries) as $prints
    | [ $manifest[0].batches[].judge[] | . as $fact | $judged[$fact.id] as $j
        | { id: $fact.id, path: $fact.path, sha256: $prints[$fact.id], linked_from: $fact.linked_from, home: $fact.home, kind: $fact.kind,
            tier: $fact.tier, scope: $fact.scope, above: ($fact.above // []), imported_by: ($fact.imported_by // []), verdict: $j.verdict, suggested_tier: $j.suggested_tier,
            rationale: $j.rationale, evidence: $j.evidence, findings: $j.findings } ]
      | sort_by([-(.tier | breadth), (.scope // ""), .id]) as $items
    | { schema_version: 1,
        generated_at: $generated_at,
        examples_sha256: $examples_sha256,
        claude_code_version: $batches[0].init.claude_code_version,
        model: ($batches | map(.init.model) | unique | join(", ")),
        plugin_version: (if $plugin_version == "" then null else $plugin_version end),
        usage: { seconds: (total(.ms) | if . == null then null else (. / 1000 | round) end),
                 input_tokens: total(.input), output_tokens: total(.output), api_equivalent_usd: total(.usd) },
        summary: { total: ($items | length),
                   pass: ($items | map(select(.verdict == "pass")) | length),
                   warn: ($items | map(select(.verdict == "warn")) | length),
                   fail: ($items | map(select(.verdict == "fail")) | length) },
        items: $items }
  ' "$@"
}

write_report() {
  # The temp file sits beside the target because a rename is atomic only within one filesystem.
  TMP_OUT=$(mktemp "$OUTDIR/.audit.json.XXXXXX") || die 1 "cannot write beside $(abbrev "$OUTPUT")"
  chmod 600 "$TMP_OUT" && cat "$WORK/report.json" > "$TMP_OUT" && cmp -s "$WORK/report.json" "$TMP_OUT" \
    || die 1 "could not write the report; the previous one is untouched"
  mv -f "$TMP_OUT" "$OUTPUT" || die 1 "could not move the report into place; the previous one is untouched"
  TMP_OUT=""
}

write_baseline() {
  jq -n --slurpfile report "$WORK/report.json" --slurpfile examples "$WORK/examples.json" --slurpfile config "$CONFIG" \
    --rawfile found "$WORK/found.txt" --rawfile imports "$WORK/found-imports.txt" --rawfile resolved "$WORK/found-stats.tsv" --rawfile hits "$WORK/hits.tsv" \
    --arg judge_sha256 "$(judge_print "$here/..")" "$JQ_ROWS$JQ_ROOTS"'
    (rows($hits) | map(split("\t") | {key: .[2], value: .[3]}) | from_entries) as $canonical
    | ([inputs | .facts[]] | map({key: .path, value: .sha256}) | from_entries) as $print
    # stat -L describes the link itself when it cannot follow it, so such a row says nothing about a target.
    | (rows($resolved) | map(split("\t") | select(.[4] != "Symbolic Link") | {key: .[3], value: {inode: .[0], size: (.[1] | tonumber), mtime: (.[2] | tonumber)}}) | from_entries) as $stat
    | { schema_version: 1,
        report_generated_at: $report[0].generated_at,
        roots: ($config[0] | roots),
        judge: ($config[0] | judged_by),
        judge_sha256: $judge_sha256,
        found: ([rows($found)[] | {path: .}] + [rows($imports)[] | {path: ., import: true}]
                | map(.path as $path | . + {sha256: ($print[$canonical[$path] // ""] // null)} + ($stat[$path] // {inode: null, size: null, mtime: null}))),
        examples: $examples[0] }
  ' "$@" > "$WORK/baseline.json" || die 1 "could not assemble the baseline; the previous report is untouched"
  write_private "$BASELINE" < "$WORK/baseline.json"
}

account_name() { jq -r --arg home "$HOME" "$JQ_ACCOUNT"'account($home)'; }

check_accounts() {
  local account slot who problem
  jq -c '[.batches[] | {slot, own_account, batch}] | group_by(.slot)[] | .[0] + {reads: (map(.batch) | join(", "))}' "$WORK/manifest.json" > "$WORK/accounts.jsonl" \
    || die 1 "could not list the accounts"
  while IFS= read -r account; do
    slot=$(jq -r '.slot // empty' <<< "$account")
    problem=$(login_problem "$slot")
    [ -n "$problem" ] || continue
    who=$(jq -r --arg home "$HOME" "$JQ_ACCOUNT"'if .own_account then "account at \(at($home)), which reads \(.reads)," else account($home) end' <<< "$account")
    die "$EX_PREFLIGHT" "the $who $problem, so nothing was sent. Run $(login_command "$slot"), log in with a Claude subscription, then audit again."
  done < "$WORK/accounts.jsonl"
}

load_excludes
build_roots
discover
build_manifest

if [ "$DRY_RUN" = 1 ]; then
  jq . "$WORK/manifest.json"
  exit 0
fi

claude_version_problem
[ -z "$REPLY" ] || die "$EX_PREFLIGHT" "$REPLY, so nothing was sent. Update it with: claude update"
check_accounts

if [ ! -d "$OUTDIR" ]; then
  mkdir -p "$OUTDIR" && chmod 700 "$OUTDIR" || die "$EX_PREFLIGHT" "cannot create $(abbrev "$OUTDIR")"
fi
acquire_lock

raw_expansion "$CONFIG" > "$WORK/found.txt" || die 1 "could not list the found paths"
LC_ALL=C sort -u "$WORK/import-paths.txt" | LC_ALL=C comm -13 "$WORK/found.txt" - > "$WORK/found-imports.txt"
found_paths=()
while IFS= read -r found_path; do found_paths+=("$found_path"); done < <(cat "$WORK/found.txt" "$WORK/found-imports.txt")
# Taken before anything is staged: a file edited while the audit runs must not look unchanged afterwards.
stat -L -f '%d:%i'$'\t''%z'$'\t''%m'$'\t''%N'$'\t''%HT' "${found_paths[@]}" > "$WORK/found-stats.tsv" 2>/dev/null
jq -n --arg path "$EXAMPLES" --arg sha256 "$(shasum -a 256 "$EXAMPLES" | cut -d' ' -f1)" --arg stat "$(stat -f '%z %m' "$EXAMPLES")" \
  '($stat | split(" ")) as $s | {path: $path, size: ($s[0] | tonumber), mtime: ($s[1] | tonumber), sha256: $sha256}' > "$WORK/examples.json" \
  || die 1 "could not fingerprint the examples file"

jq -c '."$defs".agentResponse + {"$defs": (."$defs" | del(.item, .agentResponse))}' "$SCHEMA" > "$WORK/response.schema.json" \
  || die 1 "could not extract the response schema"

batch_count=$(jq '.batches | length' "$WORK/manifest.json")
batch_files=()
i=0
while [ "$i" -lt "$batch_count" ]; do
  batch_name=$(jq -r ".batches[$i].batch" "$WORK/manifest.json")
  batch_started=$SECONDS
  say "batch $batch_name: judging $(jq ".batches[$i].judge | length" "$WORK/manifest.json") items ($(jq ".batches[$i]" "$WORK/manifest.json" | account_name))"
  stage_batch "$i" "$batch_name"
  render_prompt "$i" "$batch_name"
  invoke_batch "$i" "$batch_name"
  read_stream "$i" "$batch_name"
  check_response "$i" "$batch_name"
  jq -n --slurpfile checked "$WORK/batch-$i/checked.json" --slurpfile init "$WORK/batch-$i/init.json" --slurpfile facts "$WORK/batch-$i/facts.json" \
    --slurpfile used "$WORK/batch-$i/used.json" '{response: {items: $checked[0].items}, init: $init[0], facts: $facts[0], used: $used[0]}' > "$WORK/batch-$i/judged.json"
  batch_files+=("$WORK/batch-$i/judged.json")
  say "batch $batch_name: done in $((SECONDS - batch_started))s"
  i=$((i+1))
done

assemble_report "${batch_files[@]}" > "$WORK/report.json" || die 1 "could not assemble the report"
if ! check-jsonschema --schemafile "$SCHEMA" "$WORK/report.json" >/dev/null 2>&1; then
  cp "$WORK/report.json" "$WORK/report.rejected.json"
  keep_failure "$WORK" "the assembled report does not match the schema"
  die "$EX_REJECTED" "the assembled report does not match the schema ($KEPT)"
fi
write_baseline "${batch_files[@]}"
write_report
! ours "$OUTDIR/failed" || rm -rf "$OUTDIR/failed"
rm -f "$CONFIG_HOME/status.json"

used=$(jq -r '.usage | select(all(.[]; . != null)) | "used \(.input_tokens) tokens in and \(.output_tokens) out, in \(.seconds)s; the API would have charged about $\(.api_equivalent_usd * 100 | round / 100), and a subscription is not charged by the run"' "$OUTPUT")
[ -z "$used" ] || say "$used"
jq -r --arg out "$(abbrev "$OUTPUT")" \
  '"custodian: \(.summary.total) items, \(.summary.pass) pass, \(.summary.warn) warn, \(.summary.fail) fail -> \($out)"' "$OUTPUT"
