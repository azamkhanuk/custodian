# The judge's environment, and who is logged in under it. Sourced by the runner and by doctor.

# No list of names to leave out can be whole, since Claude Code reads dozens it does not document, so the session is given these and no other.
SEALED_KEEP=" HOME USER LOGNAME SHELL PATH TMPDIR LANG TERM TZ __CF_USER_TEXT_ENCODING \
HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY http_proxy https_proxy no_proxy all_proxy \
NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR NODE_TLS_REJECT_UNAUTHORIZED NODE_USE_SYSTEM_CA \
CLAUDE_CODE_CERT_STORE CLAUDE_CODE_CLIENT_CERT CLAUDE_CODE_CLIENT_KEY CLAUDE_CODE_CLIENT_KEY_PASSPHRASE CLAUDE_CODE_PROXY_RESOLVES_HOSTS \
CLAUDE_CODE_MAX_OUTPUT_TOKENS "

kept() {
  case "$1" in LC_*|XDG_*) return 0;; esac
  case "$SEALED_KEEP" in *" $1 "*) return 0;; esac
  return 1
}

sealed_env() {
  local name
  SEALED=(env -i)
  for name in $(compgen -e); do
    ! kept "$name" || SEALED+=("$name=${!name}")
  done
  # Safe mode ignores a telemetry switch kept in settings, so the session is given one of its own.
  SEALED+=(CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
  # Claude Code keys the stored login on a hash of this exact string, so it is passed through untouched.
  [ -z "${1:-}" ] || SEALED+=("CLAUDE_CONFIG_DIR=$1")
}

# What doctor names: everything of Anthropic's or Claude Code's that is set here and left out.
dropped_vars() {
  local name
  REPLY=""
  for name in $(compgen -e); do
    case "$name" in ANTHROPIC_*|CLAUDE*) kept "$name" || REPLY="$REPLY $name";; esac
  done
  REPLY=${REPLY# }
}

login_problem() {
  local answer
  # Shown a folder it has never used, Claude Code sets it up and runs its first-start migrations over whatever settings lie there.
  if [ -n "${1:-}" ] && [ ! -f "$1/.claude.json" ]; then
    printf 'has never been set up as a Claude Code config folder, so nobody is logged in there'
    return
  fi
  sealed_env "${1:-}"
  answer=$("${SEALED[@]}" claude auth status 2>/dev/null)
  # An empty answer must read as a problem, so jq is given the text and never the stream.
  jq -r -n --arg answer "$answer" '
    (try ($answer | fromjson) catch null) as $a
    | if ($a | type) != "object" or ($a.loggedIn | type) != "boolean" then "has a login that claude auth status could not be read for, so update Claude Code"
      elif $a.loggedIn | not then "is not logged in to Claude Code"
      elif $a.authMethod == "claude.ai" and $a.apiProvider == "firstParty" then empty
      elif $a.apiProvider != "firstParty" then "is set up for \($a.apiProvider | tostring), and Custodian audits on a Claude subscription only"
      elif ($a.authMethod | tostring | startswith("api_key")) then "is set up with an API key (\($a.apiKeySource // "source unknown")), and Custodian audits on a Claude subscription only"
      else "is logged in by \($a.authMethod | tostring), and Custodian audits on a Claude subscription only" end
  ' 2>/dev/null || printf 'has a login that could not be checked, because jq failed'
}

login_command() {
  if [ -n "${1:-}" ]; then printf 'CLAUDE_CONFIG_DIR=%s claude' "$(abbrev "$1")"
  # In a shell that names another config folder, the plain command would log that one in.
  elif [ "${CLAUDE_CONFIG_DIR+set}" = set ]; then printf 'env -u CLAUDE_CONFIG_DIR claude'
  else printf 'claude'; fi
}

version_below() {
  local i
  local -a have want
  IFS=. read -r -a have <<< "$1"
  IFS=. read -r -a want <<< "$2"
  for i in 0 1 2; do
    [ "${have[$i]:-0}" -lt "${want[$i]:-0}" ] && return 0
    [ "${have[$i]:-0}" -gt "${want[$i]:-0}" ] && return 1
  done
  return 1
}

claude_version_problem() {
  local digits
  CLAUDE_VERSION=$(claude --version 2>/dev/null)
  CLAUDE_VERSION=${CLAUDE_VERSION%% *}
  digits=${CLAUDE_VERSION%%[^0-9.]*}
  REPLY=""
  case "$digits" in
    [0-9]*.[0-9]*.[0-9]*) ! version_below "$digits" "$CLAUDE_CODE_FLOOR" || REPLY="Claude Code $CLAUDE_VERSION is older than $CLAUDE_CODE_FLOOR, which the audit needs";;
    *) REPLY="the Claude Code version could not be read from claude --version";;
  esac
}
