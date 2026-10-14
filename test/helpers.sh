# Shared by the smoke suites: assertions, the fake claude, and a fresh fixture world per case.
for tool in jq realpath check-jsonschema; do
  command -v "$tool" >/dev/null 2>&1 || { echo "smoke: $tool is required on PATH" >&2; exit 2; }
done

pass=0; fail=0; worlds=0; ran=0; dirtied=""
SANDBOX=$(realpath "$(mktemp -d)")
trap 'chmod -R u+rwx "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

t() {
  local name=$1 cond=$2 detail=${3:-}
  if eval "$cond"; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name"; [ -n "$detail" ] && echo "     $detail"; fi
}

jqt() {
  local name=$1 file=$2 expr=$3
  shift 3
  if jq -e "$@" "$expr" "$file" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name"; echo "     $(jq -c . "$file" 2>&1 | cut -c1-600)"; fi
}

mk() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }
lnk() { mkdir -p "$(dirname "$2")"; ln -s "$1" "$2"; }
auth_as() { mk "$1/.fake-auth" "$2"; }
fake_settings() {
  local pair
  { printf 'export FAKE_LOG=%q\n' "$LOG"
    for pair in ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$@"; do
      case "$pair" in FAKE_*=*) printf 'export %s=%q\n' "${pair%%=*}" "${pair#*=}";; esac
    done; } > "$BIN/fake.env"
}
account_folder() { local dir; for dir in "$@"; do mkdir -p "$dir"; printf '{}' > "$dir/.claude.json"; done; }
config() { cat > "$CFG"; }
cfg_set() { jq "$1" "$CFG" > "$CFG.new" && chmod "$(stat -f %Lp "$CFG")" "$CFG.new" && mv "$CFG.new" "$CFG"; }

write_fake() {
  cat > "$1" <<'FAKE'
#!/bin/bash
inherited=$(env | sed -n 's/=.*//p')
# The audit hands its sessions a named list of variables, so the settings come from a file beside this one.
[ ! -r "${0%/*}/fake.env" ] || . "${0%/*}/fake.env"
if [ "${1:-}" = "--help" ]; then
  [ "${FAKE_HELP:-}" = old ] && { echo "  --model <model>"; exit 0; }
  printf '  %s\n' --safe-mode --restricted --tools --allowedTools --add-dir --strict-mcp-config --permission-mode --permission-prompts --model --json-schema --output-format --verbose --no-session-persistence
  exit 0
fi
if [ "${1:-}" = "--version" ]; then echo "${FAKE_VERSION:-9.9.9-fake} (Claude Code)"; exit 0; fi
# Every name of Anthropic's or Claude Code's that reached this process, but for the two the runner sets itself.
credential_vars() { printf '%s\n' "$inherited" | grep -E '^(ANTHROPIC_|CLAUDE|CCR_|AGENT_PROXY_|AWS_BEARER_)' | grep -vxE 'CLAUDE_CONFIG_DIR|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' | LC_ALL=C sort; }
if [ "${1:-}" = "auth" ]; then
  auth=${FAKE_AUTH:-subscription}
  account=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  # As Claude Code does: shown a folder it has never used, it sets one up there.
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || [ -e "$CLAUDE_CONFIG_DIR/.claude.json" ] || printf '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
  [ -r "$account/.fake-auth" ] && auth=$(cat "$account/.fake-auth")
  [ -z "${ANTHROPIC_API_KEY:-}" ] || auth=key
  [ -z "${ANTHROPIC_AUTH_TOKEN:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || auth=token
  [ -z "${CLAUDE_CODE_USE_BEDROCK:-}" ] || auth=bedrock
  [ -z "${FAKE_LOG:-}" ] || printf '%s\t%s\t%s\n' "${CLAUDE_CONFIG_DIR-__UNSET__}" "$(ls "$FAKE_LOG" 2>/dev/null | wc -l | tr -d ' ')" "$(credential_vars | tr '\n' ',')" >> "$FAKE_LOG.auth"
  case "$auth" in
    subscription) echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"SECRET-ADDRESS","orgName":"SECRET-ORG","subscriptionType":"max"}';;
    out) echo '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'; exit 1;;
    key) echo '{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","apiKeySource":"ANTHROPIC_API_KEY"}';;
    helper) echo '{"loggedIn":true,"authMethod":"api_key_helper","apiProvider":"firstParty","apiKeySource":"apiKeyHelper"}';;
    token) echo '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}';;
    bedrock) echo '{"loggedIn":true,"authMethod":"third_party","apiProvider":"bedrock"}';;
    garbage) echo 'this is not json';;
    old) echo "error: unknown command 'auth'" >&2; exit 1;;
  esac
  exit 0
fi
n=$(( $(ls "$FAKE_LOG" 2>/dev/null | wc -l) + 1 ))
d="$FAKE_LOG/$n"; mkdir -p "$d"
printf '%s\n' "$@" > "$d/argv"
pwd -P > "$d/cwd"
ls -A . > "$d/cwd_listing"
if [ "${CLAUDE_CONFIG_DIR+set}" = set ]; then printf '%s' "$CLAUDE_CONFIG_DIR" > "$d/config_dir"; else printf '__UNSET__' > "$d/config_dir"; fi
printf '%s' "${CUSTODIAN_AUDIT:-}" > "$d/audit_mark"
if [ "${CLAUDE_CODE_PLUGIN_DIRS+set}" = set ]; then printf '%s' "$CLAUDE_CODE_PLUGIN_DIRS" > "$d/plugin_dirs"; else printf '__UNSET__' > "$d/plugin_dirs"; fi
credential_vars > "$d/credential_vars"
printf '%s\n' "$inherited" > "$d/vars"
printf '%s %s %s' "${HTTPS_PROXY:-}" "${NODE_EXTRA_CA_CERTS:-}" "${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-}" > "$d/kept_values"
cat > "$d/stdin"
echo $$ > "$d/pid"
ls -d "$TMPDIR"/custodian.*/batch-*/staging > "$d/stagings" 2>/dev/null
adddir=""; prev=""
for a in "$@"; do [ "$prev" = "--add-dir" ] && adddir=$a; prev=$a; done
[ -n "$adddir" ] && [ -d "$adddir" ] && cp -R "$adddir" "$d/staging"
v="FAKE_RM_AT_$n"; [ -n "${!v:-}" ] && rm -f "${!v}"
v="FAKE_APPEND_AT_$n"; [ -n "${!v:-}" ] && printf 'edited while the audit ran\n' >> "${!v}"
mode=${FAKE_MODE:-ok}; v="FAKE_MODE_AT_$n"; mode=${!v:-$mode}
init='{"type":"system","subtype":"init","tools":["Glob","Grep","Read","StructuredOutput"],"mcp_servers":[],"plugins":[{"name":"cc-plugin-agents-md","path":"builtin","source":"cc-plugin-agents-md@builtin"}],"model":"claude-sonnet-5","permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"9.9.9-fake"}'
[ -z "${ANTHROPIC_API_KEY:-}" ] || init=$(printf '%s' "$init" | jq -c '.apiKeySource = "ANTHROPIC_API_KEY"')
init=$(printf '%s' "$init" | jq -c --arg quiet "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" '.analytics_disabled = ($quiet == "1")')
case "$mode" in
  exit1) echo "boom" >&2; exit 1;;
  garbage) echo "this is not json"; exit 0;;
  scalars) printf '42\n"text"\n[1,2]\n'; exit 0;;
  hang) exec sleep 60;;
  hang_hard) trap "" TERM; exec sleep 60;;
  init_bash) init=$(printf '%s' "$init" | jq -c '.tools += ["Bash"]');;
  init_mcp) init=$(printf '%s' "$init" | jq -c '.mcp_servers = [{"name":"gmail","status":"connected"}]');;
  mcp_not_named) init=$(printf '%s' "$init" | jq -c '.mcp_servers = [{"name":{"a":1}}, "bare"]');;
  init_mode) init=$(printf '%s' "$init" | jq -c '.permissionMode = "auto"');;
  no_mcp_field) init=$(printf '%s' "$init" | jq -c 'del(.mcp_servers)');;
  init_plugin) init=$(printf '%s' "$init" | jq -c '.plugins += [{"name":"probe-mod","path":"/elsewhere","source":"probe-mod@inline"}]');;
  no_plugins_field) init=$(printf '%s' "$init" | jq -c 'del(.plugins)');;
  plugins_not_array) init=$(printf '%s' "$init" | jq -c '.plugins = "none"');;
  plugin_not_object) init=$(printf '%s' "$init" | jq -c '.plugins += ["probe-mod"]');;
  plugin_named_oddly) init=$(printf '%s' "$init" | jq -c '.plugins += [{"name":{"a":1},"path":"/elsewhere"}]');;
  init_old) init=$(printf '%s' "$init" | jq -c '.claude_code_version = "2.1.294"');;
  no_version) init=$(printf '%s' "$init" | jq -c 'del(.claude_code_version)');;
  analytics_on) init=$(printf '%s' "$init" | jq -c '.analytics_disabled = false');;
  no_analytics_field) init=$(printf '%s' "$init" | jq -c 'del(.analytics_disabled)');;
  tools_not_names) init=$(printf '%s' "$init" | jq -c '.tools = [{"name": "Read"}]');;
  init_key) init=$(printf '%s' "$init" | jq -c '.apiKeySource = "ANTHROPIC_API_KEY"');;
  no_key_source) init=$(printf '%s' "$init" | jq -c 'del(.apiKeySource)');;
esac
[ "$mode" != slow_start ] || sleep 1
if [ -n "${FAKE_HANG_AFTER_INIT:-}" ]; then printf '%s\n' "$init"; exec sleep 60; fi
manifest=$(sed -n '/^<manifest>$/,/^<\/manifest>$/p' "$d/stdin" | sed '1d;$d')
resp=$(printf '%s' "$manifest" | jq -c '{items: [.judge[] | {id, verdict: "pass", suggested_tier: null, rationale: "Belongs where it sits.", evidence: null, findings: []}]}')
if [ -n "${FAKE_FILTER:-}" ]; then resp=$(printf '%s' "$resp" | jq -c "$FAKE_FILTER"); fi
result=$(jq -cn --argjson response "$resp" '{type: "result", subtype: "success", is_error: false, structured_output: $response, permission_denials: [], duration_ms: 1500, total_cost_usd: 0.25,
  usage: {input_tokens: 100, cache_creation_input_tokens: 20, cache_read_input_tokens: 30, output_tokens: 40}}')
case "$mode" in
  error_result) result='{"type":"result","subtype":"error_during_execution","is_error":true,"permission_denials":[]}';;
  denial) result=$(printf '%s' "$result" | jq -c '.permission_denials = [{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}]');;
  no_output) result=$(printf '%s' "$result" | jq -c 'del(.structured_output)');;
  no_denials_field) result=$(printf '%s' "$result" | jq -c 'del(.permission_denials)');;
  no_usage) result=$(printf '%s' "$result" | jq -c 'del(.usage, .total_cost_usd, .duration_ms)');;
  limit) printf '%s\n' "$init" '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"terminal_reason":"api_error","result":"You have hit your limit. It resets at 3pm.\nA second line.","permission_denials":[]}'; exit 1;;
  logged_out) printf '%s\n' "$init" '{"type":"result","subtype":"success","is_error":true,"api_error_status":null,"terminal_reason":"api_error","result":"Not logged in · Please run /login","permission_denials":[]}'; exit 1;;
  api_error) printf '%s\n' "$init" '{"type":"result","subtype":"success","is_error":true,"api_error_status":529,"result":"API Error: overloaded","permission_denials":[]}'; exit 1;;
esac
printf '%s\n%s\n' "$init" "$result"
FAKE
  chmod +x "$1"
}

new_world() {
  worlds=$((worlds+1))
  WORLD="$SANDBOX/w$worlds"; FAKE_HOME="$WORLD/home"; BIN="$WORLD/bin"; LOG="$WORLD/fake"; TMPD="$WORLD/tmp"
  mkdir -p "$FAKE_HOME/store" "$BIN" "$LOG" "$TMPD" "$WORLD/cwd"
  CFG="$WORLD/custodian.config.json"; OUTDIR="$FAKE_HOME/Developer/.custodian"; OUT="$OUTDIR/audit.json"; STDOUT="$WORLD/stdout"; ERR="$WORLD/stderr"
  write_fake "$BIN/claude"
  local tool
  for tool in jq realpath check-jsonschema; do ln -s "$(command -v "$tool")" "$BIN/$tool"; done
  EXTRA_ENV=()
}

examples_ok() {
  mk "$FAKE_HOME/store/custodian.examples.md" '# Custodian examples

## Correctly global

- Write commit subjects in the imperative mood.
- Prefer early returns over nested conditionals.
- Run the smoke script after editing a hook.

## Leakage

- Always run the staging smoke test against acme-staging.internal before opening a PR.
- Ticket keys look like GLOBEX-1234 and go first in the branch name.
- The orders table lives in the acme_core schema.

## Correctly client-tier

- acme-release: encodes the approval chain of the acme change board, which exists nowhere else.
'
}

examples_stub() {
  mk "$FAKE_HOME/store/custodian.examples.md" '# Custodian examples

<!-- One list item each. -->

## Correctly global

<!-- At least three. -->

## Leakage

<!-- At least three.
- a list item inside a comment does not count
-->

## Correctly client-tier
'
}

wanted() { [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]]; }
group() { if wanted "$1"; then ran=$((ran+1)); echo "--- $1"; "$1"; fi; }
gone() { local n=0; while kill -0 "$1" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done; ! kill -0 "$1" 2>/dev/null; }

sha() { shasum -a 256 "$1" | cut -d" " -f1; }

real_tool() { if [ -L "$BIN/$1" ]; then readlink "$BIN/$1"; else PATH=/usr/bin:/bin command -v "$1"; fi; }

log_calls() {
  local tool real
  for tool in "$@"; do
    real=$(real_tool "$tool")
    rm -f "$BIN/$tool" "$WORLD/calls.$tool"
    printf '#!/bin/bash\necho x >> "%s"\nexec "%s" "$@"\n' "$WORLD/calls.$tool" "$real" > "$BIN/$tool"
    chmod +x "$BIN/$tool"
  done
}
calls() { if [ -f "$WORLD/calls.$1" ]; then wc -l < "$WORLD/calls.$1" | tr -d ' '; else echo 0; fi; }

log_descriptors() {
  local tool=$1 real
  real=$(real_tool "$tool")
  rm -f "$BIN/$tool" "$WORLD/descriptors.$tool"
  printf '#!/bin/bash\nls /dev/fd | wc -l >> "%s"\nexec "%s" "$@"\n' "$WORLD/descriptors.$tool" "$real" > "$BIN/$tool"
  chmod +x "$BIN/$tool"
}
most_descriptors() { sort -n "$WORLD/descriptors.$1" | tail -1 | tr -d ' '; }

clock_forward() {
  cat > "$BIN/date" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in -j|-r|-f) exec /bin/date "\$@";; esac; done
exec /bin/date -r \$(( \$(/bin/date +%s) + $1 )) "\$@"
EOF
  chmod +x "$BIN/date"
}

finish() {
  echo
  if [ -n "${FILTER:-}" ] && [ "$ran" = 0 ]; then echo "no group matches $FILTER"; return 1; fi
  echo "passed $pass, failed $fail"
  [ "$fail" = 0 ]
}
