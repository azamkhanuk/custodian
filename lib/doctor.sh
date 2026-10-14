#!/bin/bash
set -u
ROOT=${CUSTODIAN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
. "$ROOT/lib/common.sh"
. "$ROOT/lib/claude-flags.sh"
. "$ROOT/lib/seal.sh"

problems=0
ok() { printf 'ok   %s\n' "$*"; }
fix() { printf 'FIX  %s\n' "$*"; problems=$((problems+1)); }

if on_macos; then ok "macOS"; else fix "only macOS is supported, and this is $(system_name)"; exit 1; fi

tools_ready=1
need() {
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; else fix "$1 is missing: $2"; tools_ready=0; fi
}
need jq "brew install jq"
need realpath "it ships with macOS 13 and later"
need check-jsonschema "brew install check-jsonschema"
need claude "install Claude Code"

if command -v claude >/dev/null 2>&1; then
  help=$(claude --help 2>&1)
  missing=""
  for flag in "${CLAUDE_FLAGS[@]}"; do
    printf '%s' "$help" | grep -q -- "$flag" || missing="$missing $flag"
  done
  if [ -z "$missing" ]; then ok "Claude Code has every flag the audit passes"; else fix "this Claude Code lacks$missing, so update Claude Code"; fi
  claude_version_problem
  if [ -z "$REPLY" ]; then ok "Claude Code $CLAUDE_VERSION is new enough for the audit"; else fix "$REPLY: claude update"; fi
fi

check_login() {
  local slot=$1 who=$2 problem
  problem=$(login_problem "$(expand "$slot")")
  if [ -z "$problem" ]; then ok "the $who is logged in with a Claude subscription"
  else fix "the $who $problem: run $(login_command "$slot") and log in with a Claude subscription"; fi
}

if command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  dropped_vars
  [ -z "$REPLY" ] || ok "set here and not passed on to the audit: $REPLY"
  default_slot=$(jq -r '.default_slot | strings' "$DATA/config.json" 2>/dev/null)
  if [ -n "$default_slot" ]; then check_login "$default_slot" "personal account at $default_slot"; else check_login "" "personal account"; fi
  while IFS=$'\t' read -r slot scopes; do
    [ -n "$slot" ] && check_login "$slot" "account at $slot, which reads $scopes,"
  done < <(jq -r '.slots | objects | to_entries | map(select(.value | type == "string")) | group_by(.value)[] | [.[0].value, (map(.key) | join(", "))] | @tsv' "$DATA/config.json" 2>/dev/null)
fi

private() {
  local path=$1 want=$2
  [ -e "$path" ] || return 0
  # A link's own mode says nothing, and its target is a file the owner keeps elsewhere on purpose.
  [ -L "$path" ] && return 0
  [ "$(stat -f %Lp "$path")" = "$want" ] || fix "others can read $(basename "$path"): chmod $want $(abbrev "$path")"
}

if [ "$(stat -f %Lp "$DATA")" = 700 ]; then ok "the data folder at $(abbrev "$DATA") is private"; else fix "others can read the data folder: chmod 700 $(abbrev "$DATA")"; fi
for name in config.json examples.md audit.json state.json dashboard.html baseline.json baseline.unread.json status.json setup.json; do private "$DATA/$name" 600; done
private "$DATA/failed" 700
for kept in "$DATA/failed"/*; do private "$kept" 600; done
private "$DATA/hook" 700
for kept in "$DATA/hook"/*; do private "$kept" 600; done

# Everything from here reads JSON, and without jq it would blame what it could not check.
command -v jq >/dev/null 2>&1 || exit 1

hook=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$ROOT/hooks/hooks.json" 2>/dev/null | tr -d '"')
hook=${hook/'${CLAUDE_PLUGIN_ROOT}'/$ROOT}
if [ -n "$hook" ] && [ -x "$hook" ]; then ok "the reminder hook is in place"; else fix "the plugin's reminder hook is missing or cannot run, so reinstall the plugin"; fi
if ! reminders_on; then
  ok "reminders are off, because remind is false in the config"
else
  shown=""
  for stamp in "$DATA/hook"/reminded-*; do [ -e "$stamp" ] && shown=${stamp##*reminded-}; done
  if [ -n "$shown" ]; then ok "reminders are on; the last one was shown on $shown"; else ok "reminders are on; none has been shown yet"; fi
fi
if [ -s "$DATA/hook/error" ]; then
  read -r failed_on complaint < "$DATA/hook/error"
  fix "the reminder's check on $failed_on gave up: $complaint. custodian status rebuilds what it reads"
fi
finished=0
took=0
[ -r "$DATA/hook/last-check" ] && read -r finished took < "$DATA/hook/last-check"
[ "${took:-0}" -le 1 ] || fix "the reminder's last check took ${took}s, which slows session start: narrow the project glob, or set remind to false"
for stamp in "$DATA/hook"/checked-*; do
  [ -s "$stamp" ] || continue
  read -r claimed < "$stamp"
  if [ "$claimed" -gt "${finished:-0}" ] && [ $(( $(date +%s) - claimed )) -gt 10 ]; then
    fix "the reminder's last check started and never finished, so it was probably too slow and was stopped: narrow the project glob, or set remind to false"
  fi
done

if [ ! -r "$DATA/config.json" ]; then
  fix "there is no config yet: custodian init"
elif [ "$tools_ready" = 1 ]; then
  if complaints=$("$ROOT/lib/run.sh" --config "$DATA/config.json" --dry-run 2>&1 >/dev/null); then
    ok "the config is valid"
    case "$complaints" in
      *"examples are not ready"*) fix "$(printf '%s\n' "$complaints" | sed -n 's/^custodian: examples are not ready, a real run would stop here: //p')";;
      *) ok "the examples file is filled in";;
    esac
  else
    while IFS= read -r line; do fix "${line#custodian: }"; done <<< "$complaints"
  fi
fi

[ "$problems" = 0 ] || exit 1
