PATTERNS=(
  "claude_md:CLAUDE.md" "claude_md:CLAUDE.local.md" "claude_md:.claude/CLAUDE.md"
  "skill:skills/*/SKILL.md" "skill:.claude/skills/*/SKILL.md"
  "agent:agents/*.md" "agent:.claude/agents/*.md"
  "rule:rules/**" "command:commands/**"
)

walked_folder() {
  if [ "$2" = config ]; then REPLY="$1/$3"; else REPLY="$1/.claude/$3"; fi
}

WALK_DEPTH=8
WALK_TAB=$'\t'
WALK_NL=$'\n'
WALKED=rules

walk_note() {
  [ -z "${WALK_NOTES:-}" ] || printf '%s\t%s\t%s\n' "$1" "$2" "$WALKED" >> "$WALK_NOTES"
}

walk_md() {
  local dir=$1 depth=$2 entry
  [ -d "$dir" ] || return 0
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then walk_note unreadable "$dir"; return 0; fi
  for entry in "$dir"/*; do
    # Every list of paths here is one path to a line, tab-separated beside its facts.
    case "$entry" in *"$WALK_TAB"*|*"$WALK_NL"*|*\\*) walk_note unlisted "${entry//[$WALK_TAB$WALK_NL]/?}"; continue;; esac
    if [ -d "$entry" ]; then
      if [ "$depth" -lt "$WALK_DEPTH" ]; then walk_md "$entry" $((depth + 1)); else walk_note deep "$entry"; fi
    elif [ -L "$entry" ] && [ ! -e "$entry" ]; then
      case "$entry" in *.md) printf '%s\n' "$entry";; *) walk_note dangling "$entry";; esac
    elif [ -e "$entry" ]; then
      case "$entry" in *.md) printf '%s\n' "$entry";; esac
    fi
  done
}

above_found() {
  local dir=${1%/} name
  case "$dir" in *"$WALK_TAB"*|*"$WALK_NL"*|*\\*) walk_note unlisted "${dir//[$WALK_TAB$WALK_NL]/?}"; return 0;; esac
  for name in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do
    if [ -e "$dir/$name" ] || [ -L "$dir/$name" ]; then printf '%s\n' "$dir/$name"; fi
  done
  WALKED=rules; walk_md "$dir/.claude/rules" 0
}

expand_pattern() {
  local root=$1 pat=$2 layout=${3:-folder} match
  case "$pat" in
    "rules/**"|"commands/**") WALKED=${pat%/\*\*}; walked_folder "$root" "$layout" "$WALKED"; walk_md "$REPLY" 0;;
    *"*"*)
      # The root is quoted, so a glob character in its own name stands for itself, and the shell's own globbing starts no process.
      for match in "$root/${pat%%\**}"*"${pat#*\*}"; do
        [ -e "$match" ] || [ -L "$match" ] || continue
        case "$match" in
          *"$WALK_TAB"*|*"$WALK_NL"*|*\\*) walk_note unlisted "${match//[$WALK_TAB$WALK_NL]/?}";;
          *) printf '%s\n' "$match";;
        esac
      done;;
    *) if [ -e "$root/$pat" ] || [ -L "$root/$pat" ]; then printf '%s\n' "$root/$pat"; fi;;
  esac
}

plain_root() {
  REPLY=$1
  case "$REPLY" in "~/"*) REPLY="$HOME/${REPLY#"~/"}";; esac
  while [ "${REPLY%/}" != "$REPLY" ] && [ "$REPLY" != "/" ]; do REPLY=${REPLY%/}; done
}

canonical_dir() {
  local here=$PWD
  REPLY=$1
  if cd -P "$1" 2>/dev/null; then REPLY=$PWD; cd "$here" 2>/dev/null; fi
}

config_roots() {
  local config=$1 rows tier scope origin written root match layout slots="" nl=$'\n'
  rows=$(jq -r '(((.slots | objects | .[] | strings), (.default_slot | strings)) | ["slot", "-", "slot", .]),
                (.tiers[] | [.tier, (.scope // "-"), (if has("path") then "path" else "glob" end), (.path // .glob)]) | @tsv' "$config") || return 1
  # @tsv doubles a backslash, and a glob may hold one so that a bracket in a folder's own name matches itself.
  rows=${rows//\\\\/\\}
  while IFS=$'\t' read -r tier scope origin written; do
    [ "$origin" = slot ] || continue
    plain_root "$written"; canonical_dir "$REPLY"; slots="$slots$nl$REPLY"
  done <<< "$rows"
  while IFS=$'\t' read -r tier scope origin written; do
    [ "$origin" = path ] || continue
    plain_root "$written"; root=$REPLY
    layout=folder
    if [ "$tier" = global ]; then layout=config
    elif [ -n "$slots" ]; then canonical_dir "$root"; case "$slots$nl" in *"$nl$REPLY$nl"*) layout=config;; esac; fi
    case "$root" in *\\*) printf 'odd\t%s\t%s\t%s\t%s\t%s\n' "$tier" "$scope" "$root" "$written" "$layout"; continue;; esac
    printf 'path\t%s\t%s\t%s\t%s\t%s\n' "$tier" "$scope" "$root" "$written" "$layout"
  done <<< "$rows"
  while IFS=$'\t' read -r tier scope origin written; do
    [ "$origin" = glob ] || continue
    case "$written" in "~/"*) written="$HOME/${written#"~/"}";; esac
    while IFS= read -r match; do
      [ -n "$match" ] || continue
      root=${match%/*}; root=${root%/.claude}
      case "$root" in *\\*) printf 'odd\tproject\t-\t%s\t%s\tfolder\n' "$root" "$root"; continue;; esac
      printf 'glob\tproject\t-\t%s\t%s\tfolder\n' "$root" "$root"
    done < <(compgen -G "$written" | LC_ALL=C sort)
  done <<< "$rows"
}

raw_expansion() {
  local origin tier scope root written layout spec dir nl=$'\n'
  local seen=$nl
  while IFS=$'\t' read -r origin tier scope root written layout; do
    [ "$origin" != odd ] || continue
    for spec in "${PATTERNS[@]}"; do expand_pattern "$root" "${spec#*:}" "$layout"; done
    [ "$layout" = folder ] || continue
    canonical_dir "$root"; dir=$REPLY
    while [ "$dir" != "/" ]; do
      dir=${dir%/*}; [ -n "$dir" ] || dir=/
      case "$seen" in *"$nl$dir$nl"*) break;; esac
      seen="$seen$dir$nl"
      above_found "$dir"
    done
  done < <(config_roots "$1") | LC_ALL=C sort -u
}
