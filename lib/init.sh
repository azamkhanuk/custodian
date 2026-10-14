#!/bin/bash
set -u
ROOT=${CUSTODIAN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
. "$ROOT/lib/common.sh"

IMPORT=""
LAUNCHER_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --import) [ $# -ge 2 ] || die 2 "--import needs the path of an existing config"; IMPORT=$2; shift 2;;
    --launcher) [ $# -ge 2 ] || die 2 "--launcher needs a folder that is on your PATH"; LAUNCHER_DIR=$2; shift 2;;
    *) die 2 "unknown argument: $1";;
  esac
done

if [ -n "$IMPORT" ]; then
  [ -r "$IMPORT" ] && jq -e 'type == "object"' "$IMPORT" >/dev/null 2>&1 || die 2 "there is no readable config at $IMPORT"
fi
if [ -n "$LAUNCHER_DIR" ]; then
  [ -d "$LAUNCHER_DIR" ] || die 2 "there is no folder at $LAUNCHER_DIR; pick one that is on your PATH"
  if [ -e "$LAUNCHER_DIR/custodian" ] && ! grep -q "custodian launcher" "$LAUNCHER_DIR/custodian"; then
    die 2 "$LAUNCHER_DIR/custodian is not a Custodian launcher, so it was left alone"
  fi
fi

ensure_data_folder
WORK=$(mktemp -d "${TMPDIR:-/tmp}/custodian-init.XXXXXX") || die 1 "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT

printf '{\n  "tiers": [\n    { "tier": "global", "path": "~/.claude" }\n  ]\n}\n' > "$WORK/starter.json"

place() {
  local target=$1 source=$2
  if [ -e "$target" ]; then say "kept the existing $(abbrev "$target")"; return; fi
  write_private "$target" < "$source"
  say "wrote $(abbrev "$target")"
}

replace_unless_mine() {
  local target=$1 source=$2 pristine=$3
  if [ ! -e "$target" ] || cmp -s "$target" "$source"; then return 0; fi
  [ -n "$pristine" ] && cmp -s "$target" "$pristine"
}

if [ -n "$IMPORT" ]; then
  jq 'del(.output, .canonical_store)' "$IMPORT" > "$WORK/config.json" || die 1 "could not read $IMPORT"
  store=$(jq -r '.canonical_store // empty' "$IMPORT")
  report=$(jq -r '.output // empty' "$IMPORT")
  [ -n "$store" ] && [ -r "$(expand "$store")/custodian.examples.md" ] && cp "$(expand "$store")/custodian.examples.md" "$WORK/examples.md"
  [ -n "$report" ] && [ -r "$(expand "$report")" ] && cp "$(expand "$report")" "$WORK/audit.json"

  conflicts=""
  replace_unless_mine "$DATA/config.json" "$WORK/config.json" "$WORK/starter.json" || conflicts="$conflicts config.json"
  [ ! -e "$WORK/examples.md" ] || replace_unless_mine "$DATA/examples.md" "$WORK/examples.md" "$ROOT/templates/examples.md" || conflicts="$conflicts examples.md"
  [ ! -e "$WORK/audit.json" ] || replace_unless_mine "$DATA/audit.json" "$WORK/audit.json" "" || conflicts="$conflicts audit.json"
  [ -z "$conflicts" ] || die 2 "the data folder already holds its own$conflicts, so nothing was imported. Move them aside and import again."

  for name in config.json examples.md audit.json; do
    [ -e "$WORK/$name" ] || continue
    write_private "$DATA/$name" < "$WORK/$name"
    say "imported $(abbrev "$DATA/$name")"
  done
  [ ! -e "$WORK/audit.json" ] || rm -f "$DATA/baseline.json" "$DATA/status.json"
else
  place "$DATA/config.json" "$WORK/starter.json"
fi
place "$DATA/examples.md" "$ROOT/templates/examples.md"

if [ -n "$LAUNCHER_DIR" ]; then
  launcher=$(mktemp "$LAUNCHER_DIR/.custodian.XXXXXX") || die 1 "cannot write into $LAUNCHER_DIR"
  cat > "$launcher" <<'LAUNCHER'
#!/bin/bash
# custodian launcher: runs the installed plugin's command, wherever the last update put it.
data="${CUSTODIAN_HOME:-$HOME/.custodian}"
root=$(cat "$data/plugin-root" 2>/dev/null)
if [ -z "$root" ] || [ ! -x "$root/bin/custodian" ]; then
  echo "custodian: the plugin is no longer where it was. Run any Custodian skill in Claude Code once, for example /custodian:dashboard, then try again." >&2
  exit 2
fi
exec "$root/bin/custodian" "$@"
LAUNCHER
  chmod 755 "$launcher" && mv -f "$launcher" "$LAUNCHER_DIR/custodian" || { rm -f "$launcher"; die 1 "could not install the launcher"; }
  say "installed the launcher at $(abbrev "$LAUNCHER_DIR/custodian")"
  case ":$PATH:" in *":$LAUNCHER_DIR:"*) ;; *) say "$LAUNCHER_DIR is not on your PATH yet, so add it before using the custodian command in a terminal";; esac
fi
