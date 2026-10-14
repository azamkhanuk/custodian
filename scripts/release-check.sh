#!/bin/bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/lib/common.sh"

REPO=$ROOT
QUICK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die 2 "--repo needs a folder"; REPO=$(cd "$2" && pwd -P) || die 2 "no repository at $2"; shift 2;;
    --quick) QUICK=1; shift;;
    *) die 2 "unknown argument: $1";;
  esac
done

[ -r "$DATA/config.json" ] || die 2 "the check reads the names to look for from your config at $(abbrev "$DATA/config.json"), and there is none"
git -C "$REPO" rev-parse --verify -q HEAD >/dev/null 2>&1 || die 2 "$REPO has no commits to check"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/custodian-release.XXXXXX") || die 1 "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT

problems=0
found() { printf '%s\n' "$*"; problems=$((problems+1)); }

jq -r '
  if (.tiers | type) != "array" or (.tiers | length) == 0 then error("no tiers") else . end
  | [ (.tiers[] | select(.tier == "client") | .scope),
      (.tiers[] | select(.tier != "global" and .path != null) | .path | sub("/+$"; "") | split("/") | last),
      ((.slots // {})[] | sub("/+$"; "") | split("/") | last),
      (.default_slot // empty | sub("/+$"; "") | split("/") | last) ] | unique[] | select(length > 0)' "$DATA/config.json" > "$WORK/names" \
  || die 2 "your config lists no roots, so the check has no names to look for"
basename "$HOME" >> "$WORK/names"
jq -r '[.tiers[] | select(.tier != "global" and .path != null) | .path | sub("^~/"; "") | sub("/+$"; "")][]' "$DATA/config.json" > "$WORK/paths" \
  || die 2 "could not read the roots from your config"
printf '%s\n' "$HOME" >> "$WORK/paths"

# A short name matches only as a word of its own, or a three-letter scope would turn up inside ordinary words.
pattern_for() {
  local escaped
  escaped=$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
  if [ "${#1}" -ge 5 ] || [ "$2" = path ]; then printf '%s\n' "$escaped"; else printf '(^|[^A-Za-z])%s([^A-Za-z]|$)\n' "$escaped"; fi
}

ignored=0
: > "$WORK/patterns"
while IFS= read -r name; do
  if [ -r "$DATA/release-ignore" ] && grep -Fxqi -- "$name" "$DATA/release-ignore"; then ignored=$((ignored+1)); continue; fi
  pattern_for "$name" name >> "$WORK/patterns"
done < <(tr 'A-Z' 'a-z' < "$WORK/names" | LC_ALL=C sort -u)
while IFS= read -r path; do pattern_for "$path" path >> "$WORK/patterns"; done < "$WORK/paths"
[ "$ignored" = 0 ] || say "skipping $ignored ignored names from $(abbrev "$DATA/release-ignore")"
[ -s "$WORK/patterns" ] || die 2 "there is nothing to look for, so the check cannot vouch for anything"

ADDRESS='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+'
author=$(jq -r '.author.email // empty' "$REPO/.claude-plugin/plugin.json" 2>/dev/null)
stray_address() {
  case "$1" in ""|"$author"|*@example.com|*@example.org|git@*|noreply@*) return 1;; esac
}

searched() { [ "$1" -le 1 ] || die 1 "git could not search $REPO"; }

git -C "$REPO" grep -n -I -i -E -f "$WORK/patterns" -- . > "$WORK/tracked-hits" 2>/dev/null; searched $?
while IFS= read -r hit; do
  found "names something of yours: $(printf '%s' "$hit" | cut -d: -f1,2)"
done < "$WORK/tracked-hits"

git -C "$REPO" grep -n -I -o -E "$ADDRESS" -- . > "$WORK/address-hits" 2>/dev/null; searched $?
while IFS= read -r hit; do
  stray_address "$(printf '%s' "$hit" | cut -d: -f3-)" && found "an e-mail address that is not the author's: $(printf '%s' "$hit" | cut -d: -f1,2)"
done < "$WORK/address-hits"

git -C "$REPO" ls-files > "$WORK/tracked" || die 1 "git could not list $REPO"
git -C "$REPO" rev-list HEAD > "$WORK/commits" || die 1 "git could not list the history of $REPO"
: > "$WORK/history"
while IFS= read -r commit; do
  short=$(git -C "$REPO" rev-parse --short "$commit")
  git -C "$REPO" log -1 --format=%B "$commit" > "$WORK/message" || die 1 "git could not read commit $short"
  grep -q -i -E -f "$WORK/patterns" "$WORK/message" && found "names something of yours: commit $short, in its message"
  while IFS= read -r address; do
    stray_address "$address" && found "an e-mail address that is not the author's: commit $short, in its message"
  done < <(grep -o -E "$ADDRESS" "$WORK/message")
  git -C "$REPO" grep -l -I -i -E -f "$WORK/patterns" "$commit" -- . 2>/dev/null | cut -d: -f2- >> "$WORK/history"
done < "$WORK/commits"

while IFS= read -r path; do
  grep -Fxq -- "$path" "$WORK/tracked" && grep -q "^$(printf '%s' "$path" | sed 's/[][\.*^$]/\\&/g'):" "$WORK/tracked-hits" && continue
  found "names something of yours in history only: $path. Publish from a clean history with scripts/release-export.sh"
done < <(LC_ALL=C sort -u "$WORK/history")

plugin_version=$(jq -r '.version // empty' "$REPO/.claude-plugin/plugin.json" 2>/dev/null)
[ -n "$plugin_version" ] || found "the plugin manifest has no version"
# With the number in two places a release can ship one and announce the other.
jq -e '.plugins[0] | has("version") | not' "$REPO/.claude-plugin/marketplace.json" >/dev/null 2>&1 \
  || found "the marketplace entry repeats the version; the plugin manifest holds the only one"
newest=$(sed -n 's/^## \([0-9][0-9.]*\) - [0-9-]*$/\1/p' "$REPO/CHANGELOG.md" 2>/dev/null | head -n 1)
if [ -z "$newest" ]; then found "CHANGELOG.md has no section for ${plugin_version:-a version}"
elif [ "$newest" != "$plugin_version" ]; then found "the changelog's newest section ($newest) is not the manifest's version (${plugin_version:-none})"; fi

if [ "$QUICK" = 0 ]; then
  claude plugin validate --strict "$REPO" >/dev/null 2>&1 || found "strict validation of the marketplace manifest fails: claude plugin validate --strict ."
  claude plugin validate --strict "$REPO/.claude-plugin/plugin.json" >/dev/null 2>&1 || found "strict validation of the plugin fails: claude plugin validate --strict .claude-plugin/plugin.json"
  "$REPO/test/run.smoke.sh" >/dev/null 2>&1 || found "the runner's smoke suite fails: test/run.smoke.sh"
  "$REPO/test/custodian.smoke.sh" >/dev/null 2>&1 || found "the command's smoke suite fails: test/custodian.smoke.sh"
fi

say "the history is authored as: $(git -C "$REPO" log --format='%ae%n%ce' | LC_ALL=C sort -u | tr '\n' ' ')"
if [ "$problems" = 0 ]; then say "release check passed for version $plugin_version"; else say "$problems problems; nothing should be published yet"; exit 1; fi
