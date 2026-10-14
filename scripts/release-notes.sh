#!/bin/bash
# Prints the tag, the title or the notes of the release the manifest names: release-notes.sh [--tag | --title]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
name=$(jq -r '.name // empty' "$ROOT/.claude-plugin/plugin.json") && version=$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json")
[ -n "${name:-}" ] && [ -n "${version:-}" ] || { echo "release-notes: the plugin manifest names no version" >&2; exit 1; }

case "${1:-}" in
  --tag) printf '%s--v%s\n' "$name" "$version";;
  --title) printf '%s %s\n' "$name" "$version";;
  "")
    notes=$(awk -v version="$version" '
      /^## / { if (found) exit; found = ($2 == version); next }
      found { print }' "$ROOT/CHANGELOG.md" 2>/dev/null | sed -e '/./,$!d')
    [ -n "$notes" ] || { echo "release-notes: CHANGELOG.md has no section for $version" >&2; exit 1; }
    printf '%s\n' "$notes";;
  *) echo "usage: release-notes.sh [--tag | --title]" >&2; exit 2;;
esac
