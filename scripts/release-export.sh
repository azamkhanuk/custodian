#!/bin/bash
# One commit of the tracked tree in a new repository, because the private history names things. Pushes nothing.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/lib/common.sh"

[ $# -ge 1 ] || die 2 "usage: release-export.sh <new folder> [--from <repo>] [--quick]"
TARGET=$1; shift
SOURCE=$ROOT
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ $# -ge 2 ] || die 2 "--from needs a repository"; SOURCE=$(cd "$2" && pwd -P) || die 2 "no repository at $2"; shift 2;;
    *) PASS+=("$1"); shift;;
  esac
done
if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then die 2 "$TARGET is not empty, so nothing was exported"; fi
[ -z "$(git -C "$SOURCE" status --porcelain)" ] || say "uncommitted changes are not part of the export, which takes HEAD"

mkdir -p "$TARGET" || die 2 "cannot create $TARGET"
git -C "$SOURCE" archive HEAD | tar -x -C "$TARGET" || die 1 "could not export the tracked tree"
git -C "$TARGET" init -q -b main && git -C "$TARGET" add -A \
  && git -C "$TARGET" commit -q -m "feat: initial public release" \
  || die 1 "could not make the first commit in $TARGET. Put the export somewhere your git identity applies."

"$ROOT/scripts/release-check.sh" --repo "$TARGET" ${PASS[@]+"${PASS[@]}"} || die 1 "the export is at $TARGET but does not pass the release check"
say "exported one clean commit to $TARGET. Nothing was pushed."
