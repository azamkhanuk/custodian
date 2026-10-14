#!/bin/bash
# Reads the disk and proposes a config. It writes nothing but an offer the owner turned down.
set -u
set -o pipefail
ROOT=${CUSTODIAN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
. "$ROOT/lib/common.sh"
. "$ROOT/lib/claude-flags.sh"
. "$ROOT/lib/seal.sh"

FORMAT=text
ALL=0
DECLINE=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json; shift;;
    --all) ALL=1; shift;;
    --decline) [ $# -ge 2 ] || die 2 "--decline needs the key of an offer"; DECLINE+=("$2"); shift 2;;
    *) die 2 "unknown argument: $1";;
  esac
done

SETUP="$DATA/setup.json"
if [ ${#DECLINE[@]} -gt 0 ]; then
  for key in "${DECLINE[@]}"; do
    case "$key" in group:?*|glob:?*|exclude:?*|slot:?*|default_slot:?*) ;; *) die 2 "$key is not the key of an offer; custodian detect --json lists them";; esac
  done
  ensure_data_folder
  [ ! -e "$SETUP" ] || jq -e '(.schema_version // 1) == 1 and (.declined | type) == "array"' "$SETUP" >/dev/null 2>&1 \
    || die 2 "$(abbrev "$SETUP") was written by a version of Custodian this one cannot read; move it aside"
  declined=$(jq -n --slurpfile old <(cat "$SETUP" 2>/dev/null || printf '{}') '{schema_version: 1, declined: ((($old[0].declined // []) + $ARGS.positional) | unique)}' --args "${DECLINE[@]}") \
    || die 1 "could not record what was turned down"
  write_private "$SETUP" <<< "$declined"
  for key in "${DECLINE[@]}"; do say "${key#*:} will not be offered again"; done
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/custodian-detect.XXXXXX") || die 1 "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/accounts.tsv"; : > "$WORK/seen.tsv"; : > "$WORK/repos.tsv"; : > "$WORK/containers.tsv"; : > "$WORK/editors.tsv"
: > "$WORK/bases.txt"; : > "$WORK/dead.txt"; : > "$WORK/launcher_dirs.txt"

# Claude Code names a session's folder after its working folder with every other character turned into a dash, so a name is tried against the disk.
unflatten() {
  local rest=$1 dir=$2 entry flat
  [ -n "$rest" ] || { REPLY=$dir; return 0; }
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -d "$entry" ] || continue
    flat=${entry##*/}; flat=${flat//[^A-Za-z0-9]/-}
    case "$rest" in
      "$flat") REPLY=$entry; return 0;;
      "$flat"-*) unflatten "${rest#"$flat"-}" "$entry" && return 0;;
    esac
  done
  return 1
}

home_flat=${HOME//[^A-Za-z0-9]/-}
have_claude=0
command -v claude >/dev/null 2>&1 && have_claude=1

for account in "$HOME/.claude" "$HOME"/.claude[-_.]*; do
  [ -d "$account" ] || continue
  [ -d "$account/projects" ] || [ -f "$account/settings.json" ] || [ -f "$account/.claude.json" ] || [ -f "$account/.credentials.json" ] || continue
  login="-"
  if [ "$have_claude" = 1 ]; then
    if [ "$account" = "$HOME/.claude" ]; then login=$(login_problem ""); else login=$(login_problem "$account"); fi
    [ -n "$login" ] || login=subscription
  fi
  sessions=0
  for session in "$account"/projects/*/; do
    [ -d "$session" ] || continue
    sessions=$((sessions+1))
    name=${session%/}; name=${name##*/}
    case "$name" in
      "$home_flat"-*) if unflatten "${name#"$home_flat"-}" "$HOME"; then printf '%s\t%s\n' "$account" "$REPLY" >> "$WORK/seen.tsv"; fi;;
    esac
  done
  printf '%s\t%s\t%s\n' "$account" "$login" "$sessions" >> "$WORK/accounts.tsv"
done

# The first folder below home on the way to where a session ran is where repos live.
while IFS=$'\t' read -r account seen; do
  rest=${seen#"$HOME"/}; first=${rest%%/*}
  case "$first" in .*|Library|Applications|Desktop|Downloads|Movies|Music|Pictures|Public) continue;; esac
  # A repo that sits straight in the home folder is no place where repos live.
  [ ! -e "$HOME/$first/.git" ] || continue
  printf '%s\n' "$HOME/$first" >> "$WORK/bases.txt"
done < "$WORK/seen.tsv"
if [ ! -s "$WORK/bases.txt" ]; then
  # Names come from the listing, so a disk that ignores case gives each folder once and as it is spelt.
  for entry in "$HOME"/*/ "$HOME"/Documents/*/; do
    entry=${entry%/}
    case "${entry#"$HOME"/}" in
      [Dd]eveloper|[Pp]rojects|[Cc]ode|[Ss]rc|[Dd]ev|[Ww]ork|[Rr]epos|[Gg]it|[Ww]orkspace|Documents/GitHub) printf '%s\n' "$entry" >> "$WORK/bases.txt";;
    esac
  done
fi
LC_ALL=C sort -u "$WORK/bases.txt" > "$WORK/bases.sorted"

# The folder straight under a base that a session ran in or below: a group folder, or a repo of its own.
awk -F '\t' 'FNR == NR { base[$0] = 1; next }
  { for (b in base) if (index($2, b "/") == 1) { rest = substr($2, length(b) + 2); split(rest, part, "/"); print $1 FS b "/" part[1] } }' \
  "$WORK/bases.sorted" "$WORK/seen.tsv" | LC_ALL=C sort -u > "$WORK/areas.tsv"

remote_owner() {
  [ -f "$1/.git/config" ] || { REPLY="-"; return; }
  REPLY=$(awk '
    /^\[/ { origin = ($0 ~ /^\[remote "origin"\]/) }
    origin && /^[[:space:]]*url[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/^[a-z+]*:\/\//, ""); sub(/^[^@\/]*@/, ""); sub(/:/, "/")
      n = split($0, part, "/"); if (n >= 3) print tolower(part[1] "/" part[2]); exit
    }' "$1/.git/config" 2>/dev/null)
  [ -n "$REPLY" ] || REPLY="-"
}

add_repo() {
  local repo=$1 depth=$2 context=0
  if [ -e "$repo/CLAUDE.md" ] || [ -e "$repo/CLAUDE.local.md" ] || [ -d "$repo/.claude" ]; then context=1; fi
  remote_owner "$repo"
  printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "${repo%/*}" "$depth" "$context" "$REPLY" >> "$WORK/repos.tsv"
}

# An account other than the default whose sessions all ran in one such folder marks it, whatever it holds.
alone_in() {
  awk -F '\t' -v dir="$1" -v default="$HOME/.claude" '
    $1 != default { n[$1]++; if ($2 == dir) here[$1] = 1 }
    END { for (a in here) if (n[a] == 1) found = 1; exit !found }' "$WORK/areas.tsv"
}

tab=$'\t'
newline=$'\n'
while IFS= read -r base; do
  for entry in "$base"/*/; do
    entry=${entry%/}
    [ -d "$entry" ] || continue
    # Every table here is one path to a line beside tab-separated facts.
    case "$entry" in *"$tab"*|*"$newline"*) continue;; esac
    held=0
    if [ -e "$entry/.git" ]; then
      add_repo "$entry" 1; held=1
      alone_in "$entry" || continue
    else
      for inner in "$entry"/*/; do
        inner=${inner%/}
        case "$inner" in *"$tab"*|*"$newline"*) continue;; esac
        [ -e "$inner/.git" ] || continue
        add_repo "$inner" 2; held=$((held+1))
      done
      [ "$held" -gt 0 ] || alone_in "$entry" || continue
    fi
    signs=""
    [ -e "$entry/CLAUDE.md" ] && signs="$signs|a CLAUDE.md of its own"
    [ -d "$entry/.claude" ] && signs="$signs|a .claude folder of its own"
    estate="-"
    if [ -f "$entry/estate.json" ]; then
      estate=$(jq -r 'select(.contextCentral == 1 and (.name | type) == "string") | .name | gsub("[\t\n]"; " ")' "$entry/estate.json" 2>/dev/null)
      [ -n "$estate" ] || estate="-"
    fi
    awk -F '\t' -v dir="$entry" '$2 == dir { found = 1 } END { exit !found }' "$WORK/seen.tsv" && signs="$signs|sessions started in it"
    printf '%s\t%s\t%s\t%s\n' "$entry" "$held" "${signs#|}" "$estate" >> "$WORK/containers.tsv"
  done
done < "$WORK/bases.sorted"

for apps in /Applications "$HOME/Applications"; do
  [ -d "$apps/Zed.app" ] && printf 'Zed\tzed://file/{path}:{line}\n' >> "$WORK/editors.tsv"
  [ -d "$apps/Visual Studio Code.app" ] && printf 'Visual Studio Code\tvscode://file/{path}:{line}\n' >> "$WORK/editors.tsv"
  [ -d "$apps/Cursor.app" ] && printf 'Cursor\tcursor://file/{path}:{line}\n' >> "$WORK/editors.tsv"
  [ -d "$apps/Windsurf.app" ] && printf 'Windsurf\twindsurf://file/{path}:{line}\n' >> "$WORK/editors.tsv"
done

launcher=""
IFS=: read -r -a path_dirs <<< "$PATH"
for dir in ${path_dirs[@]+"${path_dirs[@]}"}; do
  [ -n "$dir" ] || continue
  if [ -z "$launcher" ] && [ -f "$dir/custodian" ] && grep -q "custodian launcher" "$dir/custodian" 2>/dev/null; then launcher="$dir/custodian"; fi
  case "$dir" in "$HOME"/*) [ -d "$dir" ] && [ -w "$dir" ] && printf '%s\n' "$dir" >> "$WORK/launcher_dirs.txt";; esac
done

exists=false
valid=null
starter=false
printf 'null' > "$WORK/config.json"
: > "$WORK/problems.txt"
if [ -r "$DATA/config.json" ]; then
  exists=true
  # The starter config init writes is nobody's choice, and where the default folder holds no context yet it finds nothing.
  if jq -e '. == {tiers: [{tier: "global", path: "~/.claude"}]}' "$DATA/config.json" >/dev/null 2>&1; then
    starter=true
    valid=true
  elif "$ROOT/lib/run.sh" --config "$DATA/config.json" --dry-run >/dev/null 2> "$WORK/dry.err" || tail -n 1 "$WORK/dry.err" | grep -q "nothing to audit"; then
    valid=true
    cp "$DATA/config.json" "$WORK/config.json"
    while IFS= read -r prefix; do
      [ -e "$(expand "$prefix")" ] || printf '%s\n' "$prefix" >> "$WORK/dead.txt"
    done < <(jq -r '.exclude // [] | .[]' "$DATA/config.json")
  else
    valid=false
    sed -n 's/^custodian: //p' "$WORK/dry.err" > "$WORK/problems.txt"
  fi
fi
printf '{}' > "$WORK/setup.json"
if [ -r "$SETUP" ] && jq -e '(.declined | type) == "array"' "$SETUP" >/dev/null 2>&1; then cp "$SETUP" "$WORK/setup.json"; fi

jq -n --rawfile accounts "$WORK/accounts.tsv" --rawfile repos "$WORK/repos.tsv" --rawfile containers "$WORK/containers.tsv" \
  --rawfile areas "$WORK/areas.tsv" --rawfile editors "$WORK/editors.tsv" --rawfile bases "$WORK/bases.sorted" --rawfile dead "$WORK/dead.txt" --rawfile launcher_dirs "$WORK/launcher_dirs.txt" \
  --rawfile problems "$WORK/problems.txt" --slurpfile config "$WORK/config.json" --slurpfile setup "$WORK/setup.json" \
  --arg home "$HOME" --arg launcher "$launcher" --argjson exists "$exists" --argjson valid "$valid" --argjson starter "$starter" --argjson all "$ALL" '
  def rows($text): $text | split("\n") | map(select(length > 0) | split("\t"));
  def short: if . == $home then "~" elif startswith($home + "/") then "~/" + .[($home | length) + 1:] else . end;
  def long: if startswith("~/") then $home + .[1:] else . end;
  def plain: long | sub("/+$"; "");
  def scope_of:
    ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | sub("-+$"; "")
    | if . == "" or IN("global", "project", "external", "unscoped") then "group-" + . else . end | sub("-$"; "");
  def majority: group_by(.) | map(select(length >= 2)) | max_by(length) | (.[0] // null);
  def literal: gsub("(?<c>[\\[\\]*?\\\\])"; "\\\(.c)");

  $config[0] as $have
  | (if $all == 1 then [] else ($setup[0].declined // []) end) as $declined
  | (rows($accounts) | map({path: .[0], login: (if .[1] == "-" then null else .[1] end), sessions: (.[2] | tonumber)})) as $found_accounts
  | (rows($repos) | map({path: .[0], parent: .[1], depth: (.[2] | tonumber), context: (.[3] == "1"), owner: (if .[4] == "-" then null else .[4] end)})) as $all_repos
  | (rows($containers) | map({path: .[0], repos: (.[1] | tonumber), signs: (.[2] | split("|") | map(select(length > 0))), estate: (if .[3] == "-" then null else .[3] end)})) as $held
  | (rows($areas) | map({account: .[0], dir: .[1]})) as $areas
  | ($found_accounts | map(. as $a
        | ([$areas[] | select(.account == $a.path) | .dir] | unique) as $in
        | $a + {default: ($a.path == $home + "/.claude"),
                works_in: (if $a.path == $home + "/.claude" then [] else $in end),
                only: (if $a.path != $home + "/.claude" and ($in | length) == 1 then $in[0] else null end)})) as $accounts_seen
  | ([$accounts_seen[] | select(.default) | .login] | .[0]) as $default_login
  | ([$accounts_seen[] | select(.default | not) | select(.login == "subscription" and .only == null)] | if $default_login != "subscription" and length == 1 then .[0].path else null end) as $elsewhere
  | ([($have.tiers // [])[] | select(.tier == "client") | .path | plain]) as $known_groups
  | ([($have.tiers // [])[] | select(.tier == "project" and has("glob")) | .glob | long]) as $known_globs
  | ([($have.exclude // [])[] | plain]) as $left_out
  | (($have.slots // {}) | to_entries | map(.value | plain)) as $known_slots
  | [ $held[] | . as $c
      | ([$accounts_seen[] | select(.only == $c.path and .login != null) | .path][0]) as $own
      | ($c.signs
         + (if $c.estate != null and $c.repos >= 2 then ["a context-central estate named \($c.estate)"] else [] end)
         + (if $own != null then ["every session under \($own | short) that ran below your home folder ran in it"] else [] end)) as $why
      | select(($why | map(select(. != "sessions started in it")) | length) > 0 and ($c.repos >= 2 or $own != null))
      | {key: "group:\($c.path | short)", path: ($c.path | short), scope: (($c.estate // ($c.path | split("/") | last)) | scope_of), repos: $c.repos, why: $why, slot: ($own | if . == null then null else short end)} ] as $candidates
  | ([($have.tiers // [])[] | select(.tier == "client") | .scope]) as $taken
  # Two folders may share a name, and a scope names one group.
  | ([$candidates[] | select((.path | plain | IN($known_groups[]) | not) and (.key | IN($declined[]) | not))]
     | reduce .[] as $g ({out: [], taken: $taken};
         . as $so_far
         | (first($g.scope, ($g.scope + "-" + (range(2; 100) | tostring)) | select(. as $name | $so_far.taken | index($name) | not))) as $name
         | {out: (.out + [$g + {scope: $name}]), taken: (.taken + [$name])})
     | .out) as $groups
  | [ $candidates[] | . as $c | select($c.slot != null and ($c.path | plain | IN($known_groups[])) and ($c.slot | plain | IN($known_slots[]) | not))
      | {key: "slot:\($c.slot)", scope: ([$have.tiers[] | select(.tier == "client" and (.path | plain) == ($c.path | plain)) | .scope][0]), path: $c.slot}
      | select(.key | IN($declined[]) | not) ] as $slots
  | ([ rows($bases)[] | .[0] as $b | ($b | literal) as $at
       | (if any($all_repos[]; .depth == 2 and (.path | startswith($b + "/"))) then ($at + "/*/*/CLAUDE.md", $at + "/*/*/.claude") else empty end),
         (if any($all_repos[]; .depth == 1 and .parent == $b) then ($at + "/*/CLAUDE.md", $at + "/*/.claude") else empty end) ]
     | map(select(IN($known_globs[]) | not) | short | {key: "glob:\(.)", glob: .} | select(.key | IN($declined[]) | not))) as $globs
  | [ $all_repos | group_by(.parent)[] | (map(.owner | select(. != null)) | majority) as $usual
      | .[] | select($usual != null and .owner != null and .owner != $usual and .context)
      | {key: "exclude:\(.path | short)", path: (.path | short)}
      | select((.path | plain) as $p | all($left_out[]; . as $x | ($p == $x or ($p | startswith($x + "/"))) | not))
      | select(.key | IN($declined[]) | not) ] as $foreign
  | ([ select($elsewhere != null and ($have.default_slot // null) == null)
       | {key: "default_slot:\($elsewhere | short)", path: ($elsewhere | short)} | select(.key | IN($declined[]) | not) ] | .[0]) as $default_slot
  | ([ select($default_slot != null and $have != null and all($have.tiers[]; ((.path // "") | plain) != ($default_slot.path | plain)))
       | {tier: "global", path: $default_slot.path} ]
     + [$groups[] | {tier: "client", path, scope}, (select(.slot != null) | {tier: "client", path: .slot, scope})]
     + [$globs[] | {tier: "project", glob: .glob}]) as $new_tiers
  | (([$groups[] | select(.slot != null) | {key: .scope, value: .slot}] + [$slots[] | {key: .scope, value: .path}]) | from_entries) as $new_slots
  | { config: {exists: $exists, valid: $valid, starter: $starter, problems: rows($problems) | map(.[0])},
      accounts: [$accounts_seen[] | {path: (.path | short), default, login, sessions, works_in: (.works_in | map(short))}],
      bases: (rows($bases) | map(.[0] | short)),
      groups: $groups,
      slots: $slots,
      default_slot: $default_slot,
      globs: $globs,
      foreign: $foreign,
      dead_excludes: (rows($dead) | map(.[0])),
      editors: (rows($editors) | map({name: .[0], editor_url: .[1]}) | unique_by(.name)),
      launcher: (if $launcher == "" then null else $launcher | short end),
      launcher_dirs: (rows($launcher_dirs) | map(.[0] | short) | unique),
      declined: ($setup[0].declined // [] | length),
      nothing_to_add: (($groups | length) + ($slots | length) + ($globs | length) + ($foreign | length) == 0 and $default_slot == null),
      proposed: (if $valid == false then null
                 elif $have == null then
                   {tiers: ([{tier: "global", path: (($default_slot.path) // "~/.claude")}] + $new_tiers)}
                   + (if ($new_slots | length) > 0 then {slots: $new_slots} else {} end)
                   + (if $default_slot != null then {default_slot: $default_slot.path} else {} end)
                 else
                   $have + {tiers: ($have.tiers + $new_tiers)}
                   + (if ($new_slots | length) > 0 then {slots: (($have.slots // {}) + $new_slots)} else {} end)
                   + (if $default_slot != null then {default_slot: $default_slot.path} else {} end)
                 end) }' > "$WORK/found.json" || die 1 "could not put together what was found"

if [ "$FORMAT" = json ]; then cat "$WORK/found.json"; exit 0; fi

jq -r '
  def listed: if length == 0 then "none" else join(", ") end;
  "accounts: " + ([.accounts[] | "\(.path) (\(if .login == "subscription" then "a Claude subscription" elif .login == null then "login not checked" else .login end)\(if .default then ", the default" elif (.works_in | length) > 0 then ", works in " + (.works_in | join(" and ")) else "" end))"] | listed),
  (if .config.exists and .config.valid == false then "the config needs fixing first: " + (.config.problems | listed) else empty end),
  (if .config.starter then "the config is still the starter that init wrote" else empty end),
  (if .config.valid == true and .nothing_to_add and (.config.starter | not) then "the config already holds everything found" else empty end),
  (if (.groups | length) > 0 then "groups to add: " + ([.groups[] | "\(.scope) at \(.path) (\(.repos) repos\(if .slot then ", read under " + .slot else "" end))"] | listed) else empty end),
  (if (.slots | length) > 0 then "accounts to add: " + ([.slots[] | "\(.path) for \(.scope)"] | listed) else empty end),
  (if .default_slot then "your own login is in \(.default_slot.path), not ~/.claude" else empty end),
  (if (.globs | length) > 0 then "repos are found by: " + ([.globs[].glob] | listed) else empty end),
  (if (.foreign | length) > 0 then "checkouts that look like someone else'"'"'s: " + ([.foreign[].path] | listed) else empty end),
  (if (.dead_excludes | length) > 0 then "exclusions that match nothing: " + (.dead_excludes | listed) else empty end),
  (if (.editors | length) > 0 then "editors: " + ([.editors[].name] | listed) else empty end),
  (if .launcher then "terminal launcher: " + .launcher else "no terminal launcher on PATH" end),
  (if .declined > 0 then "\(.declined) turned down before and not offered again; --all shows them" else empty end)
' "$WORK/found.json"
