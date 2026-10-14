#!/bin/bash
# Speaks to the person through systemMessage alone: anything else on stdout would reach the model.
set -u
umask 077

[ "${CUSTODIAN_AUDIT:-}" = 1 ] && exit 0
[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ] && exit 0
IFS= read -r -d '' -t 2 input
starting='"source"[[:space:]]*:[[:space:]]*"(startup|resume)"'
[[ ${input:-} =~ $starting ]] || exit 0

DATA="${CUSTODIAN_HOME:-$HOME/.custodian}"
[ -d "$DATA" ] || exit 0
ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd -P) || exit 0
STAMPS="$DATA/hook"

pointer=""
[ -r "$DATA/plugin-root" ] && IFS= read -r pointer < "$DATA/plugin-root"
[ "$pointer" = "$ROOT" ] || printf '%s\n' "$ROOT" > "$DATA/plugin-root"

[ -r "$DATA/config.json" ] || exit 0
read -r today now < <(date '+%Y-%m-%d %s')
[ -n "${now:-}" ] || exit 0
[ -e "$STAMPS/reminded-$today" ] && exit 0
hour=$((now / 3600))
for stamp in "$STAMPS/checked-$hour" "$STAMPS/checked-$((hour - 1))"; do
  [ -r "$stamp" ] || continue
  claimed=""
  IFS= read -r claimed < "$stamp"
  # A hook killed between creating its claim and writing the time leaves it empty, so the hour it names stands in.
  [ -n "$claimed" ] || claimed=$(( ${stamp##*-} * 3600 ))
  [ $((now - claimed)) -lt 3600 ] && exit 0
done

mkdir -p "$STAMPS" || exit 0
( set -C; printf '%s\n' "$now" > "$STAMPS/checked-$hour" ) 2>/dev/null || exit 0
for stamp in "$STAMPS"/checked-*; do [ "$stamp" = "$STAMPS/checked-$hour" ] || rm -f "$stamp"; done
[ "$(uname 2>/dev/null)" = Darwin ] || exit 0

give_up() {
  printf '%s %s\n' "$today" "$*" > "$STAMPS/error" 2>/dev/null
  exit 0
}

. "$ROOT/lib/jq-defs.sh"
. "$ROOT/lib/expansion.sh"
. "$ROOT/lib/reminder.sh"

remind=""
IFS=$'\t' read -r remind backstop output roots_now judge_now < <(jq -r "$JQ_ROOTS"'
  [(if has("remind") then .remind else true end), (.stale_after_days // 7), (.output // "-"), roots, judged_by] | @tsv' "$DATA/config.json" 2>/dev/null)
[ -n "$remind" ] || give_up "the config cannot be read"
[ "$remind" = false ] && exit 0
case "$backstop" in ""|0|*[!0-9]*) give_up "stale_after_days in the config is not a whole number of days";; esac
report="$DATA/audit.json"
case "$output" in "-") ;; "~/"*) report="$HOME/${output#"~/"}";; *) report=$output;; esac
[ -r "$report" ] || exit 0

sources=()
baseline=no
[ -r "$DATA/baseline.json" ] && { sources+=("$DATA/baseline.json"); baseline=yes; }
[ -r "$DATA/status.json" ] && sources+=("$DATA/status.json")

known=""
named=()
roots_then=""
examples_path=""
drifted=0
examples_changed=false
roots_changed=false
judge_then="-"
judge_changed=false
open_leaks=0
generated=""
if [ ${#sources[@]} -gt 0 ]; then
  known=$(jq -r -s '
    (if any(.[]; .schema_version != 1) then error("another version wrote this") else . end)
    | (map(select(has("found")))[0]) as $baseline | (map(select(has("drift")))[0]) as $checked
    | (if $baseline != null and $checked != null and $checked.report_generated_at != $baseline.report_generated_at then null else $checked end) as $status
    | ["generated", (($baseline // $status).report_generated_at | fromdateiso8601)],
      ["leaks", ($status.open_leaks // 0)],
      (if $baseline == null then empty
       else ["roots", $baseline.roots],
            ["judge", ($baseline.judge // "-")],
            ($baseline.examples | ["examples", .path, .size, .mtime, .sha256]),
            ($baseline.found[] | select(.import == true) | ["import", .path]),
            ($baseline.found[] | ["found", .path, (.inode // "-"), (.size // "-"), (.mtime // "-"), (.sha256 // "-")]),
            (($status.rejected // [])[] | ["rejected", .]) end)
    | @tsv' "${sources[@]}" 2>/dev/null) || give_up "the baseline or the status file cannot be read"
  while IFS=$'\t' read -r row first rest; do
    case "$row" in
      generated) generated=$first;;
      leaks) open_leaks=$first;;
      roots) roots_then=$first;;
      judge) judge_then=$first;;
      examples) examples_path=$first;;
      import) named+=("$first");;
      *) break;;
    esac
  done <<< "$known"
fi

if [ "$baseline" = yes ]; then
  newline=$'\n'
  tab=$'\t'
  [ "$roots_now" = "$roots_then" ] || roots_changed=true
  [ "$judge_then" = "-" ] || [ "$judge_now" = "$judge_then" ] || judge_changed=true
  found_now=$(raw_expansion "$DATA/config.json") || give_up "the config's roots cannot be expanded"
  for path in ${named[@]+"${named[@]}"}; do found_now="$found_now$newline$path"; done
  present=()
  while IFS= read -r path; do [ -n "$path" ] && present+=("$path"); done <<< "$found_now"
  resolved=$(stat -L -f "stat$tab%d:%i$tab%z$tab%m$tab%N$tab%HT" ${present[@]+"${present[@]}"} "$examples_path" 2>/dev/null)
  verdicts=$(awk -F '\t' '
    $1 == "found" { known[$2] = 1; inode[$2] = $3; size[$2] = $4; mtime[$2] = $5; print_of[$2] = $6; next }
    $1 == "examples" { examples = $2; examples_size = $3; examples_mtime = $4; next }
    $1 == "rejected" { rejected[$2] = 1; next }
    $1 == "import" { named[$2] = 1; next }
    $1 == "now" { if ($2 != "") present[$2] = 1; next }
    $1 == "stat" {
      if ($6 == "Symbolic Link") next
      resolves[$5] = 1
      if ($5 == examples) { if ($3 != examples_size || $4 != examples_mtime) print "suspect\t" $5 }
      else if (($5 in known) && print_of[$5] != "-" && ($2 != inode[$5] || $3 != size[$5] || $4 != mtime[$5])) print "suspect\t" $5
      else if (($5 in named) && print_of[$5] == "-" && inode[$5] != "-" && $6 == "Regular File" && !($5 in rejected) && ($2 != inode[$5] || $3 != size[$5] || $4 != mtime[$5])) moved++
      next
    }
    END {
      for (path in present) {
        if (!(path in known)) { if (!(path in rejected)) moved++ }
        else if (print_of[path] != "-") { if (!(path in resolves)) moved++ }
        else if (inode[path] == "-" && (path in resolves) && !(path in rejected)) moved++
      }
      for (path in known) if (print_of[path] != "-" && !(path in present)) moved++
      if (examples != "" && !(examples in resolves)) print "examples\tgone"
      print "moved\t" moved + 0
    }' <<< "$known${newline}now$tab${found_now//$newline/${newline}now$tab}$newline$resolved")
  suspects=()
  while IFS=$'\t' read -r kind value; do
    case "$kind" in suspect) suspects+=("$value");; examples) examples_changed=true;; moved) drifted=$value;; esac
  done <<< "$verdicts"
  if [ ${#suspects[@]} -gt 0 ]; then
    read -r changed examples_differ < <(awk -F '\t' '
      FNR == NR { if ($1 == "found") recorded[$2] = $6; else if ($1 == "examples") { recorded[$2] = $5; examples = $2 } next }
      { path = substr($0, 67); if (recorded[path] != substr($0, 1, 64)) { if (path == examples) differ = 1; else changed++ } }
      END { print changed + 0, differ + 0 }' <(printf '%s\n' "$known") <(shasum -a 256 "${suspects[@]}" 2>/dev/null))
    drifted=$((drifted + ${changed:-0}))
    [ "${examples_differ:-0}" = 1 ] && examples_changed=true
  fi
elif [ -z "$generated" ]; then
  generated=$(stat -f %m "$report" 2>/dev/null)
fi

[ -n "$generated" ] || give_up "the age of the report cannot be told"
age_days=$(( (now - generated) / 86400 ))
[ "$age_days" -lt 0 ] && age_days=0
too_old=false
[ $((now - generated)) -gt $((backstop * 86400)) ] && too_old=true

[ -e "$STAMPS/error" ] && rm -f "$STAMPS/error"
printf '%s %s\n' "$now" "$SECONDS" > "$STAMPS/last-check"

line=$(reminder_line "$drifted" "$examples_changed" "$roots_changed" "$too_old" "$age_days" "$open_leaks" "$judge_changed")
[ -n "$line" ] || exit 0
( set -C; printf '%s\n' "$line" > "$STAMPS/reminded-$today" ) 2>/dev/null || exit 0
for stamp in "$STAMPS"/reminded-*; do [ "$stamp" = "$STAMPS/reminded-$today" ] || rm -f "$stamp"; done
printf '{"systemMessage":"%s"}\n' "$line"
exit 0
