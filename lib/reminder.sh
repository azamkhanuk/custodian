age_phrase() {
  case "$1" in
    0) printf 'less than a day ago';;
    1) printf '1 day ago';;
    *) printf '%s days ago' "$1";;
  esac
}

also() { if [ -n "$stale" ]; then stale="$stale $1 too."; else stale=" $1 $since."; fi; }

reminder_line() {
  local drifted=$1 examples_changed=$2 roots_changed=$3 too_old=$4 age_days=$5 open_leaks=$6 judge_changed=${7:-false} stale="" leaks="" since
  since="since your audit $(age_phrase "$age_days")"
  if [ "$drifted" = 1 ]; then stale=" 1 context file has changed, appeared or gone $since."
  elif [ "$drifted" -gt 1 ]; then stale=" $drifted context files have changed, appeared or gone $since."; fi
  [ "$examples_changed" = true ] && also "Your examples have changed"
  [ "$roots_changed" = true ] && also "Your config's roots have changed"
  [ "$judge_changed" = true ] && also "The model or the accounts in your config have changed"
  if [ "$too_old" = true ] && [ -z "$stale" ]; then
    if [ "$age_days" = 1 ]; then stale=" Your audit is 1 day old."; else stale=" Your audit is $age_days days old."; fi
  fi
  if [ "$open_leaks" = 1 ]; then leaks=" 1 file still leaks."
  elif [ "$open_leaks" -gt 1 ]; then leaks=" $open_leaks files still leak."; fi
  if [ -n "$stale" ]; then printf 'Custodian:%s%s /custodian:audit re-judges everything, /custodian:dashboard shows the detail.' "$stale" "$leaks"
  elif [ -n "$leaks" ]; then printf 'Custodian:%s /custodian:dashboard shows where.' "$leaks"; fi
}
