# Shared by every script. remember_install_root expects ROOT to be set.
DATA="${CUSTODIAN_HOME:-$HOME/.custodian}"

say() { printf 'custodian: %s\n' "$*" >&2; }
die() { local code=$1; shift; say "$*"; exit "$code"; }

on_macos() { [ "$(uname 2>/dev/null)" = Darwin ]; }
system_name() { local name; name=$(uname 2>/dev/null); printf '%s' "${name:-an unknown system}"; }

expand() {
  case "$1" in
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}";;
    *) printf '%s' "$1";;
  esac
}

abbrev() {
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}";;
    "${HOME_REAL:-$HOME}"/*) printf '~/%s' "${1#"${HOME_REAL:-$HOME}"/}";;
    *) printf '%s' "$1";;
  esac
}

ensure_data_folder() {
  [ -d "$DATA" ] && return
  mkdir -p "$DATA" && chmod 700 "$DATA" || die 2 "cannot create the data folder at $(abbrev "$DATA")"
}

write_private() {
  local target=$1 tmp
  tmp=$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX") || die 1 "cannot write beside $(abbrev "$target")"
  chmod 600 "$tmp" && cat > "$tmp" && mv -f "$tmp" "$target" || { rm -f "$tmp"; die 1 "could not write $(abbrev "$target")"; }
}

remember_install_root() {
  [ "$(cat "$DATA/plugin-root" 2>/dev/null)" = "$ROOT" ] || write_private "$DATA/plugin-root" <<< "$ROOT"
}

report_path() {
  local configured=""
  [ -r "$DATA/config.json" ] && configured=$(jq -r '.output // empty' "$DATA/config.json" 2>/dev/null)
  if [ -n "$configured" ]; then expand "$configured"; else printf '%s' "$DATA/audit.json"; fi
}

examples_path() {
  local config=$1 store
  store=$(jq -r '.canonical_store // empty' "$config" 2>/dev/null)
  if [ -n "$store" ]; then printf '%s/custodian.examples.md' "$(expand "$store")"; else printf '%s/examples.md' "$(cd "$(dirname "$config")" && pwd)"; fi
}

# A reader that guesses at a file of another shape shows wrong facts, so each one asks first.
this_schema() { jq -e '.schema_version == 1' "$1" >/dev/null 2>&1; }
require_schema() {
  this_schema "$1" || die 2 "$(abbrev "$1") was written by a version of Custodian this one cannot read; $2"
}
require_state_schema() {
  [ ! -r "$1" ] || jq -e '(.schema_version // 1) == 1' "$1" >/dev/null 2>&1 \
    || die 2 "$(abbrev "$1") was written by a version of Custodian this one cannot read; move it aside to start its acknowledgements again"
}

judge_print() { cat "$1/lib/prompt.md" "$1/lib/schema.json" 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }

describes_report() {
  [ "$(jq -r .report_generated_at "$1" 2>/dev/null)" = "$(jq -r .generated_at "$2" 2>/dev/null)" ]
}

reminders_on() { [ "$(jq -r 'if has("remind") then .remind else true end' "$DATA/config.json" 2>/dev/null)" != false ]; }
backstop_days() { jq -r '.stale_after_days // 7' "$DATA/config.json" 2>/dev/null || printf 7; }

require_config() {
  [ -r "$DATA/config.json" ] || die 2 "no config at $(abbrev "$DATA/config.json"); run: custodian init"
}
