#!/usr/bin/env bash
# tests/fm-backend-paseo-agent.test.sh - fake-paseo-CLI tests for the native
# Paseo agent adapter (bin/backends/paseo-agent.sh), host-follow backend
# resolution (bin/fm-backend.sh), and the paseo-agent arms of the lifecycle
# scripts. The fake `paseo` is stateful: one world.json per case holds the
# daemon status, the provider catalog, projects, workspaces, agents, and
# pending permissions, and every call is logged as one JSON line, so a case
# asserts on Paseo's resulting state and on call order. Nothing reaches a real
# Paseo daemon; docs/verification/runtime-backends.md "Paseo agents" owns the
# live evidence.
# shellcheck disable=SC2016  # $1/$2 inside single quotes belong to the bash -c snippets pa_run and pa_resolve forward.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the paseo-agent adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-paseo-agent-tests)
# fm-spawn.sh creates each task's /tmp/fm-<id> outside TMP_ROOT, so every id a
# case spawns is recorded and its directory removed on exit; the run tag keeps
# concurrent runs of this suite apart.
PA_TASK_IDS="$TMP_ROOT/task-ids"
PA_RUN=$(printf '%05x%04x' "$(( $$ % 1048576 ))" "$RANDOM")
cleanup() {
  local id
  if [ -f "$PA_TASK_IDS" ]; then
    while IFS= read -r id; do
      [ -z "$id" ] || rm -rf "/tmp/fm-$id"
    done < "$PA_TASK_IDS"
  fi
  fm_test_cleanup
}
trap cleanup EXIT
pa_uid() {  # <base> -> <base><run-tag>, recorded for cleanup
  printf '%s\n' "$1$PA_RUN" >> "$PA_TASK_IDS"
  printf '%s' "$1$PA_RUN"
}

# The suite runs inside whatever session launched it; none of the host markers
# fm_backend_detect_host reads may leak into a case that does not set them.
unset PASEO_AGENT_ID PASEO_CLI TMUX HERDR_ENV ZELLIJ REX_BLOCK CMUX_WORKSPACE_ID TERN_PANE HC_TERMINAL_ID \
  ORCA_STRUCTURED_SESSION ORCA_AGENT_SESSION_ID ORCA_TERMINAL_HANDLE FM_BACKEND FM_OMP_HARNESS
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/paseo" <<'SH'
#!/usr/bin/env bash
# Stateful fake Paseo CLI (tests/fm-backend-paseo-agent.test.sh).
set -u
W="${PASEO_WORLD:?}"
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "${PASEO_LOG:?}"
json_list() {  # <values...> -> a JSON array of strings
  [ $# -gt 0 ] || { printf '[]'; return 0; }
  printf '%s\n' "$@" | jq -R . | jq -cs .
}
upd() {
  local tmp
  tmp=$(mktemp "$W.XXXXXX")
  jq "$@" "$W" > "$tmp" && mv "$tmp" "$W"
}
not_found() {
  printf 'electron warning line\n{"error":{"code":"AGENT_NOT_FOUND","message":"Agent not found: %s"}}\n' "$1" >&2
  exit 1
}
key=${1:-}
case "$key" in workspace|project|provider|permit) key="$1 ${2:-}" ;; esac
inject=$(jq -r --arg k "$key" '.fail[$k] // empty' "$W")
case "$inject" in
  typed:*) printf 'electron warning line\n{"error":{"code":"%s","message":"refused"}}\n' "${inject#typed:}" >&2; exit 1 ;;
  lost) echo "Error: connection closed before the daemon answered" >&2; exit 1 ;;
esac
case "$key" in
  -v) jq -r .version "$W" ;;
  status) jq -c .status "$W" ;;
  "provider models") jq -c --arg h "$3" '.models[$h] // []' "$W" ;;
  "project ls") jq -c .projects "$W" ;;
  "project create")
    upd --arg p "$3" '.seq += 1 | .projects += [{projectId: ("prj_" + (.seq | tostring)), path: $p}]'
    jq -c '.projects[-1] | {projectId}' "$W"
    ;;
  "workspace create")
    shift 2
    prj='' path='' title=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --project) prj=$2; shift 2 ;;
        --path) path=$2; shift 2 ;;
        --title) title=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    upd --arg prj "$prj" --arg p "$path" --arg t "$title" \
      '.seq += 1 | .workspaces += [{workspaceId: ("wks_" + (.seq | tostring)), cwd: $p, projectId: $prj, title: $t, archived: false}]'
    jq -c '.workspaces[-1] | {workspaceId, cwd}' "$W"
    ;;
  "workspace ls") jq -c '[.workspaces[] | select(.archived | not) | {workspaceId, cwd}]' "$W" ;;
  "workspace archive")
    upd --arg id "$3" '(.workspaces[] | select(.workspaceId == $id) | .archived) = true'
    printf '{"workspaceId":"%s","archived":true}\n' "$3"
    ;;
  run)
    shift
    wks='' provider='' mode='' title='' thinking='' prompt=''
    labels=() envs=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --workspace) wks=$2; shift 2 ;;
        --provider) provider=$2; shift 2 ;;
        --mode) mode=$2; shift 2 ;;
        --title) title=$2; shift 2 ;;
        --thinking) thinking=$2; shift 2 ;;
        --label) labels+=("$2"); shift 2 ;;
        --env) envs+=("$2"); shift 2 ;;
        --no-wait|--json) shift ;;
        *) prompt=$1; shift ;;
      esac
    done
    cwd=$(jq -r --arg w "$wks" '.workspaces[] | select(.workspaceId == $w and (.archived | not)) | .cwd' "$W")
    [ -n "$cwd" ] || { printf '{"error":{"code":"WORKSPACE_NOT_FOUND","message":"no workspace %s"}}\n' "$wks" >&2; exit 1; }
    upd --arg w "$wks" --arg cwd "$cwd" --arg provider "$provider" --arg mode "$mode" --arg title "$title" \
      --arg thinking "$thinking" --arg prompt "$prompt" \
      --argjson labels "$(json_list ${labels[@]+"${labels[@]}"})" \
      --argjson env "$(json_list ${envs[@]+"${envs[@]}"})" '
      .seq += 1
      | (.seq | tostring) as $n
      | ("00000000-0000-4000-8000-" + ("000000000000" + $n)[-12:]) as $id
      | .agents[$id] = {Id: $id, Status: (.runStatus // "running"), Archived: false, Cwd: $cwd,
          PendingPermissions: [], Workspace: $w, Provider: $provider, Mode: $mode, Title: $title,
          Thinking: $thinking, Labels: $labels, Env: $env, Prompt: $prompt, Messages: []}
      | .lastAgent = $id'
    jq -c '{agentId: .lastAgent, status: "running"}' "$W"
    ;;
  inspect)
    jq -e --arg id "$2" '.agents[$id] != null' "$W" >/dev/null || not_found "$2"
    jq -c --arg id "$2" '.agents[$id] | {Id, Status, Archived, Cwd, PendingPermissions}' "$W"
    ;;
  send)
    agent=$2
    shift 2
    file=''
    while [ $# -gt 0 ]; do
      case "$1" in --prompt-file) file=$2; shift 2 ;; *) shift ;; esac
    done
    jq -e --arg id "$agent" '.agents[$id] != null and (.agents[$id].Archived | not)' "$W" >/dev/null || not_found "$agent"
    upd --arg id "$agent" --rawfile text "$file" '.agents[$id].Messages += [$text] | .agents[$id].Status = "running"'
    printf '{"status":"sent","agentId":"%s"}\n' "$agent"
    ;;
  stop)
    jq -e --arg id "$2" '.agents[$id] != null' "$W" >/dev/null || not_found "$2"
    [ "$inject" = noop ] || upd --arg id "$2" '(.agents[$id] | select(.Status == "running" or .Status == "initializing") | .Status) = "idle"'
    printf '{"agentId":"%s"}\n' "$2"
    ;;
  archive)
    jq -e --arg id "$2" '.agents[$id] != null' "$W" >/dev/null || not_found "$2"
    [ "$inject" = noop ] || upd --arg id "$2" '.agents[$id].Archived = true | .agents[$id].Status = "closed"'
    printf '{"agentId":"%s","status":"archived"}\n' "$2"
    ;;
  logs) printf 'assistant: working on %s\n' "$2" ;;
  "permit ls") jq -c .permits "$W" ;;
  *) echo "fake paseo: unsupported call: $*" >&2; exit 64 ;;
esac
SH
chmod +x "$FAKEBIN/paseo"
export PATH="$FAKEBIN:$PATH"

OPUS=anthropic/claude-opus-5-5

# pa_case <name>: a fresh world with a reachable 0.17.4 daemon whose process
# ids nothing descends from, and the omp catalog the live daemon reported.
# Sets CASE_DIR, PASEO_WORLD, PASEO_LOG, and an FM_HOME with state/config.
pa_case() {
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/home/state" "$CASE_DIR/home/config" "$CASE_DIR/home/data"
  export PASEO_WORLD="$CASE_DIR/world.json" PASEO_LOG="$CASE_DIR/paseo.log"
  : > "$PASEO_LOG"
  jq -n --arg opus "$OPUS" '{
    version: "0.17.4",
    status: {localDaemon: "running", connectedDaemon: "reachable", pid: 2147483000, workerPid: 2147483001},
    models: {omp: [
      {id: $opus, thinkingOptionIds: ["auto", "low", "medium", "high", "xhigh", "max"]},
      {id: "anthropic/claude-haiku-4-5", thinkingOptionIds: ["auto", "low"]},
      {id: "openai/gpt-5-sol", thinkingOptionIds: ["low", "high"]},
      {id: "azure/gpt-5-sol", thinkingOptionIds: ["low"]}]},
    projects: [], workspaces: [], agents: {}, permits: [], fail: {}, seq: 0}' > "$PASEO_WORLD"
}

pa_set() {  # <jq program over the world>
  local tmp
  tmp=$(mktemp "$PASEO_WORLD.XXXXXX")
  jq "$1" "$PASEO_WORLD" > "$tmp" && mv "$tmp" "$PASEO_WORLD"
}

pa_get() {  # <jq -r program over the world>
  jq -r "$1" "$PASEO_WORLD"
}

# pa_agent <id> <status> [archived] [pending-permission-count] [cwd]: one agent row.
pa_agent() {
  local id=$1 status=$2 archived=${3:-false} pending=${4:-0} cwd=${5:-/nonexistent}
  pa_set ".agents[\"$id\"] = {Id: \"$id\", Status: \"$status\", Archived: $archived, Cwd: \"$cwd\",
    PendingPermissions: [range(0; $pending) | {id: (\"perm-\" + tostring)}], Messages: []}"
}

# pa_calls: the fake's calls in order, one space-joined argv per line.
pa_calls() {
  tr '\037' ' ' < "$PASEO_LOG"
}

# pa_call_line <grep -E pattern> -> 1-based line of the first matching call, 0 when none.
pa_call_line() {
  local n
  n=$(pa_calls | grep -nE -- "$1" | head -1 | cut -d: -f1)
  printf '%s' "${n:-0}"
}

# pa_run <snippet> [args...]: the snippet runs with fm-backend.sh, the adapter,
# and the transition library loaded, as bin/fm-watch.sh's push splice has them.
pa_run() {
  FM_HOME="$CASE_DIR/home" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" FM_STATE_OVERRIDE="$CASE_DIR/home/state" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-transition-lib.sh"; fm_backend_source paseo-agent || exit 1; '"$1" "$ROOT" "${@:2}"
}

A1=00000000-0000-4000-8000-0000000000a1

test_status_table_maps_every_paseo_row() {
  local status row
  pa_case status-table
  for status in running initializing idle closed error; do
    pa_agent "$A1" "$status"
    row=$(pa_run 'printf "%s|%s|%s" "$(fm_backend_paseo_agent_probe "$1")" "$(fm_backend_paseo_agent_busy_state "$1")" "$(fm_backend_paseo_agent_agent_state "$1")"' "$A1")
    case "$status" in
      running) assert_equals "running|busy|alive" "$row" "a running agent is busy and alive" ;;
      initializing) assert_equals "starting|busy|alive" "$row" "an initializing agent is busy and alive" ;;
      idle) assert_equals "idle|idle|alive" "$row" "an idle agent is idle and alive" ;;
      closed) assert_equals "closed|idle|alive" "$row" "a closed runtime is idle and alive (a send resumes it)" ;;
      error) assert_equals "error|unknown|dead" "$row" "an errored agent is unknown and dead" ;;
    esac
  done
  pa_agent "$A1" running false 2
  row=$(pa_run 'printf "%s|%s" "$(fm_backend_paseo_agent_probe "$1")" "$(fm_backend_paseo_agent_busy_state "$1")"' "$A1")
  assert_equals "blocked|idle" "$row" "a pending permission reads blocked and idle, never as a running turn"
  pa_agent "$A1" closed true
  row=$(pa_run 'printf "%s|%s" "$(fm_backend_paseo_agent_probe "$1")" "$(fm_backend_paseo_agent_agent_state "$1")"' "$A1")
  assert_equals "archived|dead" "$row" "an archived agent is dead: its workspace and worktree remain"
  row=$(pa_run 'printf "%s|%s" "$(fm_backend_paseo_agent_probe "$1")" "$(fm_backend_paseo_agent_agent_state "$1")"' 00000000-0000-4000-8000-00000000dead)
  assert_equals "not-found|missing" "$row" "the daemon's own AGENT_NOT_FOUND is missing"
  pa_set '.fail.inspect = "lost"'
  row=$(pa_run 'printf "%s|%s|%s" "$(fm_backend_paseo_agent_probe "$1")" "$(fm_backend_paseo_agent_busy_state "$1")" "$(fm_backend_paseo_agent_agent_state "$1")"' "$A1")
  assert_equals "unreadable|unknown|unreadable" "$row" "an inspect failure without Paseo's answer is unreadable, never missing"
  pass "paseo-agent status table: running/starting busy, idle/closed/blocked idle, error/archived dead, not-found missing, lost read unreadable"
}

test_model_selection_resolves_against_the_catalog() {
  local out rc
  pa_case model-selection
  out=$(pa_run 'fm_backend_paseo_agent_model_selection omp default default')
  assert_equals "omp"$'\t' "$out" "no model leaves both choices to the provider"
  out=$(pa_run 'fm_backend_paseo_agent_model_selection omp default high')
  assert_equals "omp"$'\t'"high" "$out" "an effort without a model passes to the provider unchecked"
  [ "$(pa_calls | grep -c 'provider models')" = 0 ] || fail "no model must not read the catalog"
  out=$(pa_run 'fm_backend_paseo_agent_model_selection omp claude-opus-5-5 medium')
  assert_equals "omp/$OPUS"$'\t'"medium" "$out" "an unprefixed model resolves to the one catalog id it ends"
  out=$(pa_run 'fm_backend_paseo_agent_model_selection omp anthropic/claude-haiku-4-5 default')
  assert_equals "omp/anthropic/claude-haiku-4-5"$'\t' "$out" "an exact catalog id is used as is"
  out=$(pa_run 'fm_backend_paseo_agent_model_selection omp claude-opus-5-5 minimal' 2>&1); rc=$?
  expect_code 1 "$rc" "an effort the model does not offer"
  assert_contains "$out" "it offers: auto low medium high xhigh max" "the refusal lists the model's thinking options"
  out=$(pa_run 'fm_backend_paseo_agent_model_selection omp gpt-5-sol low' 2>&1); rc=$?
  expect_code 1 "$rc" "an unprefixed model that ends two catalog ids"
  assert_contains "$out" "matches several" "an ambiguous model is refused, never guessed"
  out=$(pa_run 'fm_backend_paseo_agent_model_selection omp nope default' 2>&1); rc=$?
  expect_code 1 "$rc" "a model the catalog lacks"
  assert_contains "$out" "lists no model 'nope'" "an unknown model is refused with the catalog"
  pass "paseo-agent model selection: exact or unique suffix id, effort checked against the model's thinking options"
}

test_send_text_submit_verdicts_and_verbatim_text() {
  local out text
  pa_case send-verdicts
  pa_agent "$A1" idle
  text=$'--force looks like an option\nsecond line'
  out=$(pa_run 'fm_backend_paseo_agent_send_text_submit "$1" "$2"' "$A1" "$text")
  assert_equals empty "$out" "a send Paseo reports sent is delivered"
  [ "$(pa_get ".agents[\"$A1\"].Messages[0]")" = "$text" ] || fail "the text must reach Paseo verbatim through the prompt file"
  pa_calls | grep -q -- '--behavior steer' || fail "a steer must use Paseo's steer behaviour"
  pa_calls | grep -q -- 'looks like an option' && fail "the text must never ride argv"
  pa_set '.fail.send = "typed:AGENT_BUSY"'
  out=$(pa_run 'fm_backend_paseo_agent_send_text_submit "$1" hi' "$A1" 2>/dev/null)
  assert_equals send-failed "$out" "Paseo's typed refusal means nothing was sent"
  pa_set '.fail.send = "lost"'
  out=$(pa_run 'fm_backend_paseo_agent_send_text_submit "$1" hi' "$A1" 2>/dev/null)
  assert_equals unconfirmed "$out" "a call that lost Paseo's answer may have landed"
  pass "paseo-agent send: sent is delivered, a typed refusal is send-failed, a lost answer is unconfirmed; text rides a file"
}

test_kill_is_a_proven_idempotent_archive() {
  local rc
  pa_case kill
  pa_agent "$A1" running
  pa_run 'fm_backend_paseo_agent_kill "$1"' "$A1"; rc=$?
  expect_code 0 "$rc" "killing a running agent"
  [ "$(pa_get ".agents[\"$A1\"].Archived")" = true ] || fail "kill must archive the agent"
  : > "$PASEO_LOG"
  pa_run 'fm_backend_paseo_agent_kill "$1"' "$A1"; rc=$?
  expect_code 0 "$rc" "killing an archived agent"
  [ "$(pa_call_line '^archive')" = 0 ] || fail "an archived agent must not be archived again"
  pa_run 'fm_backend_paseo_agent_kill "$1"' 00000000-0000-4000-8000-00000000dead; rc=$?
  expect_code 0 "$rc" "killing an agent the daemon no longer has"
  pa_agent "$A1" running
  pa_set '.fail.archive = "noop"'
  pa_run 'fm_backend_paseo_agent_kill "$1"' "$A1"; rc=$?
  expect_code 1 "$rc" "an archive Paseo does not read back"
  pa_set '.fail = {inspect: "lost"}'
  pa_run 'fm_backend_paseo_agent_kill "$1"' "$A1"; rc=$?
  expect_code 1 "$rc" "an unreadable agent"
  pass "paseo-agent kill: succeeds only on a read-back archive or absence, never on an unreadable agent"
}

test_native_interrupt_claims() {
  local out rc
  pa_case interrupt
  pa_agent "$A1" running
  out=$(FM_BACKEND_PASEO_AGENT_INTERRUPT_WAIT=2 pa_run 'fm_backend_paseo_agent_native_interrupt "$1"' "$A1")
  assert_equals confirmed "$out" "a running turn Paseo stopped is confirmed"
  out=$(pa_run 'fm_backend_paseo_agent_native_interrupt "$1"' "$A1")
  assert_equals not-running "$out" "an idle agent is not running"
  pa_agent "$A1" running
  pa_set '.fail.stop = "noop"'
  out=$(FM_BACKEND_PASEO_AGENT_INTERRUPT_WAIT=1 pa_run 'fm_backend_paseo_agent_native_interrupt "$1"' "$A1")
  assert_equals unconfirmed "$out" "a turn still running after the wait is unconfirmed"
  pa_agent "$A1" closed true
  pa_run 'fm_backend_paseo_agent_native_interrupt "$1"' "$A1"; rc=$?
  expect_code 1 "$rc" "interrupting an archived agent"
  pass "paseo-agent interrupt: confirmed, not-running, or unconfirmed from Paseo's read-back; an archived agent refuses"
}

test_workspace_state_and_retire() {
  local wt other out rc
  pa_case workspaces
  wt="$CASE_DIR/wt"; other="$CASE_DIR/other"
  mkdir -p "$wt" "$other"
  ln -s "$wt" "$CASE_DIR/wt-link"
  pa_set ".workspaces = [{workspaceId: \"wks_1\", cwd: \"$wt\", archived: false}, {workspaceId: \"wks_2\", cwd: \"$other\", archived: false}]"
  out=$(pa_run 'fm_backend_paseo_agent_workspace_state wks_1 "$1"' "$CASE_DIR/wt-link")
  assert_equals active "$out" "the task workspace on its worktree (through a symlink) is active"
  out=$(pa_run 'fm_backend_paseo_agent_workspace_state wks_2 "$1"' "$wt")
  assert_equals elsewhere "$out" "a workspace on another directory is elsewhere"
  out=$(pa_run 'fm_backend_paseo_agent_workspace_state wks_9 "$1"' "$wt")
  assert_equals absent "$out" "an unknown workspace is absent"
  pa_run 'fm_backend_paseo_agent_workspace_retire wks_2 "$1"' "$wt" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "retiring a workspace that points elsewhere"
  [ "$(pa_get '.workspaces[1].archived')" = false ] || fail "a workspace on another directory must be left in place"
  pa_run 'fm_backend_paseo_agent_workspace_retire wks_1 "$1"' "$wt"; rc=$?
  expect_code 0 "$rc" "retiring the task workspace"
  [ "$(pa_get '.workspaces[0].archived')" = true ] || fail "retire must archive the task workspace"
  : > "$PASEO_LOG"
  pa_run 'fm_backend_paseo_agent_workspace_retire wks_1 "$1"' "$wt"; rc=$?
  expect_code 0 "$rc" "retiring an archived workspace"
  [ "$(pa_call_line '^workspace archive')" = 0 ] || fail "an absent workspace is already the end state"
  pa_set '.fail["workspace ls"] = "lost"'
  pa_run 'fm_backend_paseo_agent_workspace_retire wks_1 "$1"' "$wt" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "retiring against an unreadable inventory"
  pass "paseo-agent workspaces: active, elsewhere, absent; retire archives only the task's own live workspace"
}

test_project_ensure_matches_realpath_or_registers() {
  local proj out
  pa_case projects
  proj="$CASE_DIR/proj"
  mkdir -p "$proj"
  ln -s "$proj" "$CASE_DIR/proj-link"
  pa_set ".projects = [{projectId: \"prj_7\", path: \"$proj\"}]"
  out=$(pa_run 'fm_backend_paseo_agent_project_ensure "$1"' "$CASE_DIR/proj-link")
  assert_equals prj_7 "$out" "a project registered at the physical path is reused"
  [ "$(pa_call_line '^project create')" = 0 ] || fail "a known project must not be registered again"
  pa_set '.projects = []'
  out=$(pa_run 'fm_backend_paseo_agent_project_ensure "$1"' "$CASE_DIR/proj-link")
  case "$out" in prj_*) ;; *) fail "an unknown project must be registered, got '$out'" ;; esac
  [ "$(pa_get '.projects[0].path')" = "$proj" ] || fail "registration must use the physical path"
  pass "paseo-agent projects: matched by physical path, registered when Paseo has none"
}

test_pending_permission_escalates_once() {
  local state rc record
  pa_case permits
  state="$CASE_DIR/home/state"
  pa_set ".permits = [{id: \"perm-1\", agentId: \"$A1\"}]"
  record=$(FM_BACKEND_PASEO_AGENT_WAIT_STEP=0.1 pa_run 'fm_backend_paseo_agent_wait_transition s 0.3 "$1" "$2"' "$state" "$A1"); rc=$?
  expect_code 0 "$rc" "a fresh pending permission"
  assert_contains "$record" "$A1" "the blocked record names the agent"
  assert_contains "$record" "perm-1" "the blocked record names the request"
  pa_run 'fm_backend_paseo_agent_commit_transition "$1" s "$2"' "$state" "$record" || fail "commit must record the escalation"
  FM_BACKEND_PASEO_AGENT_WAIT_STEP=0.1 pa_run 'fm_backend_paseo_agent_wait_transition s 0.3 "$1" "$2"' "$state" "$A1" >/dev/null; rc=$?
  expect_code 1 "$rc" "the same request set again"
  pa_set ".permits += [{id: \"perm-2\", agentId: \"$A1\"}]"
  FM_BACKEND_PASEO_AGENT_WAIT_STEP=0.1 pa_run 'fm_backend_paseo_agent_wait_transition s 0.3 "$1" "$2"' "$state" "$A1" >/dev/null; rc=$?
  expect_code 0 "$rc" "a new request joining the set"
  pa_set '.permits = []'
  FM_BACKEND_PASEO_AGENT_WAIT_STEP=0.1 pa_run 'fm_backend_paseo_agent_wait_transition s 0.2 "$1" "$2"' "$state" "$A1" >/dev/null; rc=$?
  expect_code 1 "$rc" "no pending request"
  assert_absent "$(pa_run 'fm_backend_paseo_agent_escalation_marker "$1" "$2"' "$state" "$A1")" "an answered request clears its escalation marker"
  pa_set '.fail["permit ls"] = "lost"'
  FM_BACKEND_PASEO_AGENT_WAIT_STEP=0.1 pa_run 'fm_backend_paseo_agent_wait_transition s 0.2 "$1" "$2"' "$state" "$A1" >/dev/null; rc=$?
  expect_code 2 "$rc" "an unreadable permission list"
  pass "paseo-agent push wait: a pending permission set escalates once, a changed set again, an unreadable daemon is distinct"
}

# Host-follow: the session's own host decides the backend of a new spawn. The
# fake daemon reports this suite's own process as its worker, so a case's
# `bash -c` child descends from it exactly as a primary descends from Paseo.
pa_resolve() {  # <env assignments...> -> "<resolved>|<detected>|<signal>" on stdout, notices on stderr
  env "$@" FM_HOME="$CASE_DIR/home" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" FM_BACKEND_CONFIG_DIR="$CASE_DIR/home/config" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_resolve ${PA_RESOLVE_FLAG:-}; printf "%s|%s|%s" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECTED" "$FM_BACKEND_DETECT_SIGNAL"' "$ROOT"
}

test_host_follow_selects_paseo_agent_only_inside_a_real_paseo_agent() {
  local out err
  pa_case host-paseo
  printf 'orca\n' > "$CASE_DIR/home/config/backend"
  pa_set ".status.workerPid = $$"
  pa_agent "$A1" idle false 0 "$CASE_DIR/home"
  err="$CASE_DIR/err"
  out=$(pa_resolve PASEO_AGENT_ID="$A1" 2>"$err")
  assert_equals "paseo-agent|paseo-agent|paseo-agent-host" "$out" "a primary inside a live Paseo agent in this home spawns Paseo agents"
  assert_contains "$(cat "$err")" "rather than config/backend's 'orca'" "the host overriding config/backend prints a notice naming both"
  out=$(pa_resolve PASEO_AGENT_ID="$A1" PA_RESOLVE_FLAG=--no-host 2>/dev/null)
  assert_equals "orca||" "$out" "a secondmate spawn skips the host and keeps config/backend"
  out=$(pa_resolve PASEO_AGENT_ID="$A1" FM_BACKEND=tmux 2>/dev/null)
  assert_equals "tmux||" "$out" "FM_BACKEND still wins over the host"
  out=$(pa_resolve PASEO_AGENT_ID="$A1" TMUX=/tmp/tmux-sock,1,0 2>/dev/null)
  assert_equals "orca||" "$out" "a nested multiplexer is the innermost layer, not the Paseo agent"
  pa_set '.status.workerPid = 2147483001'
  out=$(pa_resolve PASEO_AGENT_ID="$A1" 2>/dev/null)
  assert_equals "orca||" "$out" "an inherited marker outside the daemon's process tree is not a host"
  pa_set ".status.workerPid = $$"
  pa_agent "$A1" idle false 0 "$CASE_DIR"
  out=$(pa_resolve PASEO_AGENT_ID="$A1" 2>/dev/null)
  assert_equals "orca||" "$out" "an agent working elsewhere (a worker in its worktree) is not this home's host"
  pa_agent "$A1" closed true 0 "$CASE_DIR/home"
  out=$(pa_resolve PASEO_AGENT_ID="$A1" 2>/dev/null)
  assert_equals "orca||" "$out" "an archived agent is not a host"
  pass "host-follow: paseo-agent only inside a live, unarchived Paseo agent in this home that descends from the daemon"
}

test_host_follow_selects_orca_from_its_own_markers() {
  local out
  pa_case host-orca
  out=$(pa_resolve ORCA_STRUCTURED_SESSION=1 ORCA_AGENT_SESSION_ID=chat-1 2>/dev/null)
  assert_equals "orca|orca|orca-chat" "$out" "an Orca chat primary spawns Orca workers"
  out=$(pa_resolve ORCA_TERMINAL_HANDLE=term-1 2>/dev/null)
  assert_equals "orca|orca|orca-terminal" "$out" "an Orca terminal primary spawns Orca workers"
  out=$(pa_resolve ORCA_STRUCTURED_SESSION=1 2>/dev/null)
  assert_equals "tmux||" "$out" "a structured-session flag without a chat id is not an Orca chat"
  pass "host-follow: Orca chat and terminal markers select orca with their signal"
}

test_busy_and_dispatch_read_paseo_native_state() {
  local out
  pa_case dispatch
  pa_agent "$A1" running
  out=$(FM_HOME="$CASE_DIR/home" bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; fm_busy_classify paseo-agent "$1" omp t1 "$2" ""' "$ROOT" "$A1" "$CASE_DIR/home/state")
  assert_equals "busy paseo-agent-native" "$out" "a running agent is natively busy"
  pa_agent "$A1" idle
  out=$(FM_HOME="$CASE_DIR/home" bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; fm_busy_classify paseo-agent "$1" omp t1 "$2" ""' "$ROOT" "$A1" "$CASE_DIR/home/state")
  assert_equals "idle paseo-agent-native" "$out" "an idle agent is natively idle"
  pa_set '.fail.inspect = "lost"'
  out=$(FM_HOME="$CASE_DIR/home" bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; printf "%s|" "$(fm_busy_classify paseo-agent "$1" omp t1 "$2" "")"; fm_busy_is_busy paseo-agent "$1" omp t1 "$2" "" && printf busy || printf idle' "$ROOT" "$A1" "$CASE_DIR/home/state")
  assert_equals "unknown paseo-agent-native|busy" "$out" "native uncertainty is treated as busy, never as an idle worker"
  pa_set '.fail = {}'
  out=$(FM_HOME="$CASE_DIR/home" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state paseo-agent "$1"' "$ROOT" 00000000-0000-4000-8000-00000000dead)
  assert_equals missing "$out" "the dispatcher routes agent_state to the adapter"
  pass "paseo-agent busy and dispatch: Paseo's native status is the busy truth and uncertainty stays busy"
}

# --- lifecycle scripts --------------------------------------------------------

# The fake treehouse logs into the same call log, so a case reads the order of
# Paseo and Treehouse calls from one place; `get` hands out the case worktree.
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
{ printf 'treehouse\037'; for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "${PASEO_LOG:?}"
case "${1:-}" in
  get) printf '%s\n' "${PA_TREEHOUSE_WT:?}" ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/treehouse"
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

# pa_task_case <name> <id>: a project, its leased worktree on fm/<id>, and a
# home with the task's brief. Sets PROJ, WT, DATA, STATE, CONFIG.
pa_task_case() {
  pa_case "$1"
  PROJ="$CASE_DIR/project"; WT="$CASE_DIR/wt"
  DATA="$CASE_DIR/home/data"; STATE="$CASE_DIR/home/state"; CONFIG="$CASE_DIR/home/config"
  fm_git_worktree "$PROJ" "$WT" "fm/$2"
  mkdir -p "$DATA/$2"
  cat > "$DATA/$2/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Paseo agent dispatch.

## Firstmate spec
Verify the paseo-agent lifecycle behavior under test.
EOF
  touch "$STATE/.last-watcher-beat"
}

pa_spawn() {  # <id> [fm-spawn args after the project...]
  local id=$1
  shift
  HOME="$SPAWN_HOME" PA_TREEHOUSE_WT="$WT" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "$@" 2>&1
}

pa_meta() {  # <id> <key>
  bash -c '. "$1"; fm_meta_get "$2" "$3"' _ "$ROOT/bin/fm-backend.sh" "$STATE/$1.meta" "$2"
}

test_spawn_leases_slot_opens_workspace_and_starts_agent_last() {
  local id out agent wks
  id=$(pa_uid paspawn)
  pa_task_case spawn "$id"
  out=$(pa_spawn "$id" omp --mode no-mistakes --yolo off --model claude-opus-5-5 --effort medium --backend paseo-agent)
  expect_code 0 $? "fm-spawn.sh --backend paseo-agent against the fake Paseo"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=omp kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$WT" "spawn summary"
  agent=$(pa_get '.lastAgent')
  wks=$(pa_get '.workspaces[0].workspaceId')
  assert_equals paseo-agent "$(pa_meta "$id" backend)" "meta backend"
  assert_equals "$agent" "$(pa_meta "$id" paseo_agent_id)" "meta records the agent Paseo assigned"
  assert_equals "$wks" "$(pa_meta "$id" paseo_agent_workspace_id)" "meta records the task workspace"
  assert_equals "fm-$id" "$(pa_meta "$id" window)" "meta window is the stable alias"
  assert_equals "$WT" "$(pa_meta "$id" worktree)" "meta worktree is the leased slot"
  assert_equals "$WT" "$(pa_get '.workspaces[0].cwd')" "the workspace is a local one on the leased worktree"
  assert_equals "fm-$id" "$(pa_get '.workspaces[0].title')" "the workspace title is the alias"
  assert_equals "$(pa_get '.projects[0].projectId')" "$(pa_get '.workspaces[0].projectId')" "the workspace is attached to the project"
  assert_equals "omp/$OPUS" "$(pa_get ".agents[\"$agent\"].Provider")" "the agent runs the catalog model"
  assert_equals medium "$(pa_get ".agents[\"$agent\"].Thinking")" "the agent carries the effort"
  assert_equals full "$(pa_get ".agents[\"$agent\"].Mode")" "the agent runs full access"
  assert_equals "$WT" "$(pa_get ".agents[\"$agent\"].Cwd")" "the agent works in the leased worktree"
  assert_contains "$(pa_get ".agents[\"$agent\"].Labels | join(\" \")")" "fm-task=$id" "the agent carries its task label"
  assert_contains "$(pa_get ".agents[\"$agent\"].Env | join(\" \")")" "FM_TASK_INBOX=$STATE/$id.inbox" "the agent gets its steering inbox"
  assert_contains "$(pa_get ".agents[\"$agent\"].Env | join(\" \")")" "FM_TASK_ID=$id" "the agent gets its task id"
  assert_contains "$(pa_get ".agents[\"$agent\"].Env | join(\" \")")" "COMPACT_ADVISER_DISABLE=1" "the agent gets the compact-adviser kill switch"
  assert_contains "$(pa_get ".agents[\"$agent\"].Env | join(\" \")")" "PLANNOTATOR_INBOX_TOOL=0" "a ship agent starts with the Plannotator Inbox tool off"
  assert_not_contains "$(pa_get ".agents[\"$agent\"].Env | join(\" \")")" "GIT_CONFIG" "no Git config override rides the Paseo environment"
  assert_contains "$(pa_get ".agents[\"$agent\"].Prompt")" "FIRSTMATE_OP: v1 launch-brief:" "the first message is the encoded launch brief"
  assert_contains "$(pa_get ".agents[\"$agent\"].Prompt")" "Verify the paseo-agent lifecycle behavior under test." "the first message carries the brief body"
  assert_contains "$out" "cannot deliver the AI-trailer strip hooks" "the spawn warns that the trailer strip cannot reach the agent"
  [ "$(pa_call_line "^treehouse get --lease --lease-holder $id")" -gt 0 ] || fail "spawn must lease the slot durably"
  [ "$(pa_call_line '^workspace create')" -gt "$(pa_call_line '^treehouse get')" ] || fail "the workspace must follow the lease"
  [ "$(pa_call_line '^run ')" -gt "$(pa_call_line '^workspace create')" ] || fail "the agent must start after its workspace exists"
  [ "$(pa_call_line '^treehouse return')" = 0 ] || fail "a successful spawn keeps its lease"
  pass "fm-spawn.sh --backend paseo-agent: leases the slot, opens a local workspace on it, starts the agent with the brief, records metadata"
}

# A spawn without --backend inside a Paseo agent in this home follows the host
# end to end: fm-spawn's own state must not reset the PASEO_AGENT_ID it inherits.
test_spawn_without_backend_follows_a_paseo_agent_host() {
  local id out
  id=$(pa_uid pahost)
  pa_task_case spawnhost "$id"
  printf 'orca\n' > "$CONFIG/backend"
  pa_set ".status.workerPid = $$"
  pa_agent "$A1" idle false 0 "$CASE_DIR/home"
  out=$(PASEO_AGENT_ID="$A1" pa_spawn "$id" omp --scout)
  expect_code 0 $? "fm-spawn.sh without --backend inside a Paseo agent"$'\n'"$out"
  assert_contains "$out" "rather than config/backend's 'orca'" "the spawn names the host it followed over config/backend"
  assert_equals paseo-agent "$(pa_meta "$id" backend)" "the scout runs on the host's backend"
  assert_equals paseo-agent-host "$(pa_meta "$id" backend_detect)" "meta records the host signal"
  assert_equals "$(pa_get '.lastAgent')" "$(pa_meta "$id" paseo_agent_id)" "meta records the new worker agent, not the host"
  pass "fm-spawn.sh without --backend: a Paseo-hosted session spawns a native Paseo agent"
}

pa_control() {  # <id> <verb> [args...]
  HOME="$SPAWN_HOME" PA_TREEHOUSE_WT="$WT" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=3 FM_CONTROL_LAUNCH_WAIT=1 FM_BACKEND_PASEO_AGENT_INTERRUPT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

test_control_lib_tables() {
  bash -c '. "$0/bin/fm-control-lib.sh"; fm_control_backend_supports_key paseo-agent Escape && fm_control_backend_supports_key paseo-agent Enter && fm_control_backend_supports_key paseo-agent C-c && ! fm_control_backend_supports_key paseo-agent C-u && fm_control_backend_state_verified paseo-agent && fm_control_backend_exit_supported paseo-agent && fm_control_backend_relaunch_supported paseo-agent' "$ROOT" \
    || fail "control-lib must accept Escape/Enter/C-c, refuse C-u, and treat paseo-agent as state-verified with exit and relaunch"
  pass "fm-control-lib: paseo-agent key set, state-verified, exit, and relaunch membership"
}

test_control_interrupt_exit_and_relaunch() {
  local id out rc first second wks
  id=$(pa_uid pactl)
  pa_task_case control "$id"
  out=$(pa_spawn "$id" omp --scout --backend paseo-agent)
  expect_code 0 $? "scout spawn"$'\n'"$out"
  first=$(pa_meta "$id" paseo_agent_id)
  wks=$(pa_meta "$id" paseo_agent_workspace_id)
  out=$(pa_control "$id" interrupt); rc=$?
  expect_code 0 "$rc" "interrupt on a running Paseo agent"$'\n'"$out"
  [ "$(pa_call_line "^stop $first")" -gt 0 ] || fail "interrupt must stop the turn through Paseo"
  assert_equals idle "$(pa_get ".agents[\"$first\"].Status")" "the interrupted agent is idle"
  assert_equals false "$(pa_get ".agents[\"$first\"].Archived")" "interrupt never archives"
  out=$(pa_control "$id" exit); rc=$?
  expect_code 0 "$rc" "exit on a Paseo agent"$'\n'"$out"
  assert_equals true "$(pa_get ".agents[\"$first\"].Archived")" "exit is a proven archive"
  assert_equals false "$(pa_get ".workspaces[0].archived")" "exit leaves the workspace for a relaunch"
  assert_present "$STATE/$id.meta" "exit keeps the task record"
  out=$(pa_control "$id" relaunch --note "fresh context"); rc=$?
  expect_code 0 "$rc" "relaunch on an exited Paseo agent"$'\n'"$out"
  second=$(pa_meta "$id" paseo_agent_id)
  assert_not_equals "$first" "$second" "relaunch rebinds the record to a new agent"
  assert_equals "$wks" "$(pa_meta "$id" paseo_agent_workspace_id)" "relaunch keeps the recorded workspace"
  assert_equals "$wks" "$(pa_get ".agents[\"$second\"].Workspace")" "the new agent starts in the recorded workspace"
  assert_equals 1 "$(pa_get '.workspaces | length')" "relaunch opens no second workspace"
  assert_contains "$(pa_get ".agents[\"$second\"].Prompt")" "FIRSTMATE_OP: v1 launch-brief:" "the new agent starts from the brief"
  assert_contains "$(pa_get ".agents[\"$second\"].Env | join(\" \")")" "PLANNOTATOR_INBOX_TOOL=0" "the relaunched scout still starts with the Plannotator Inbox tool off"
  pass "fm-control.sh backend=paseo-agent: interrupt stops the turn, exit archives the agent, relaunch starts a new agent in the same workspace"
}

test_scout_teardown_archives_agent_and_workspace_before_slot_return() {
  local id out rc agent
  id=$(pa_uid patear)
  pa_task_case teardown "$id"
  out=$(pa_spawn "$id" omp --scout --backend paseo-agent)
  expect_code 0 $? "scout spawn"$'\n'"$out"
  agent=$(pa_meta "$id" paseo_agent_id)
  printf 'report\n' > "$DATA/$id/report.md"
  # The report holds no captain calls, as an inventoried scout's would record.
  printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$STATE/$id.meta"
  mkdir -p "$CASE_DIR/neutral/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_DIR/neutral/bin/fm-guard.sh"
  chmod +x "$CASE_DIR/neutral/bin/fm-guard.sh"
  : > "$PASEO_LOG"
  out=$( PA_TREEHOUSE_WT="$WT" FM_ROOT_OVERRIDE="$CASE_DIR/neutral" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 ); rc=$?
  expect_code 0 "$rc" "scout teardown once the report exists"$'\n'"$out"
  assert_equals true "$(pa_get ".agents[\"$agent\"].Archived")" "teardown archives the agent"
  assert_equals true "$(pa_get '.workspaces[0].archived')" "teardown archives the task workspace"
  [ "$(pa_call_line "^archive $agent")" -gt 0 ] || fail "teardown must archive through Paseo"
  [ "$(pa_call_line '^workspace archive')" -gt "$(pa_call_line "^archive $agent")" ] || fail "the workspace is archived after its agent"
  [ "$(pa_call_line '^treehouse return')" -gt "$(pa_call_line '^workspace archive')" ] || fail "the slot returns only after the workspace is archived"
  assert_absent "$STATE/$id.meta" "teardown removes the task record"
  pass "fm-teardown.sh backend=paseo-agent: archives the agent, then its workspace, then returns the slot"
}

# A design worker is the one task worker that keeps the Plannotator Inbox: its
# Paseo agent starts without the kill switch every ship and scout carries, its
# record keeps the role, and a relaunch reads the role back from that record.
test_design_worker_keeps_the_plannotator_inbox() {
  local id out rc first second
  id=$(pa_uid padesign)
  pa_task_case design "$id"
  printf '\n# Design contract\nWorker role: design\nAsk the captain directly.\n' >> "$DATA/$id/brief.md"
  out=$(pa_spawn "$id" omp --mode local-only --yolo off --design --backend paseo-agent)
  expect_code 0 $? "design spawn"$'\n'"$out"
  assert_contains "$out" "role=design" "the spawn summary names the design role"
  assert_equals design "$(pa_meta "$id" role)" "the task record keeps the design role"
  first=$(pa_meta "$id" paseo_agent_id)
  assert_not_contains "$(pa_get ".agents[\"$first\"].Env | join(\" \")")" "PLANNOTATOR_INBOX_TOOL" "a design worker keeps its Inbox tool"
  assert_contains "$(pa_get ".agents[\"$first\"].Prompt")" "You are a design worker" "the design worker's role contract replaces the never-address-the-captain rule"
  out=$(pa_control "$id" exit); rc=$?
  expect_code 0 "$rc" "exit the design worker"$'\n'"$out"
  out=$(pa_control "$id" relaunch --note "fresh context"); rc=$?
  expect_code 0 "$rc" "relaunch the design worker"$'\n'"$out"
  second=$(pa_meta "$id" paseo_agent_id)
  assert_not_equals "$first" "$second" "relaunch starts a new agent"
  assert_equals design "$(pa_meta "$id" role)" "relaunch keeps the design role"
  assert_not_contains "$(pa_get ".agents[\"$second\"].Env | join(\" \")")" "PLANNOTATOR_INBOX_TOOL" "the relaunched design worker keeps its Inbox tool"
  assert_contains "$(pa_get ".agents[\"$second\"].Prompt")" "You are a design worker" "the relaunched worker keeps the design role contract"
  pass "fm-spawn.sh --design backend=paseo-agent: the design worker keeps the Inbox across a relaunch while ships and scouts lose it"
}

test_spawn_refuses_what_paseo_cannot_honor() {
  local id out rc
  id=$(pa_uid parefuse)
  pa_task_case refusals "$id"
  out=$(pa_spawn "$id" 'omp --print hello' --scout --backend paseo-agent); rc=$?
  [ "$rc" -ne 0 ] || fail "a raw launch command must be refused"
  assert_contains "$out" "cannot run a raw launch command" "the raw-launch refusal names the reason"
  printf 'FOO\n' > "$CONFIG/launch-env-allowlist"
  out=$(pa_spawn "$id" omp --scout --backend paseo-agent); rc=$?
  [ "$rc" -ne 0 ] || fail "a launch-env allowlist must be refused"
  assert_contains "$out" "cannot apply config/launch-env-allowlist" "the allowlist refusal names the file"
  rm -f "$CONFIG/launch-env-allowlist"
  [ "$(pa_call_line '^(run|workspace create) ')" = 0 ] || fail "a refused spawn must create nothing in Paseo"
  [ "$(pa_call_line '^treehouse get')" = 0 ] || fail "a refused spawn must lease nothing"
  assert_absent "$STATE/$id.meta" "a refused spawn publishes no record"
  pass "fm-spawn.sh backend=paseo-agent: raw launch commands and launch-env allowlists are refused before any lease"
}

test_refused_agent_start_returns_lease_and_lost_start_keeps_it() {
  local id out rc
  id=$(pa_uid parefused)
  pa_task_case start-refused "$id"
  pa_set '.fail.run = "typed:PROVIDER_ERROR"'
  out=$(pa_spawn "$id" omp --scout --backend paseo-agent); rc=$?
  [ "$rc" -ne 0 ] || fail "a refused agent start must fail the spawn"$'\n'"$out"
  assert_equals true "$(pa_get '.workspaces[0].archived')" "a refused start archives the task workspace"
  [ "$(pa_call_line '^treehouse return')" -gt "$(pa_call_line '^workspace archive')" ] || fail "a refused start returns the slot after archiving the workspace"$'\n'"$out"
  assert_absent "$STATE/$id.meta" "a refused start publishes no record"
  id=$(pa_uid palost)
  pa_task_case start-lost "$id"
  pa_set '.fail.run = "lost"'
  out=$(pa_spawn "$id" omp --scout --backend paseo-agent); rc=$?
  [ "$rc" -ne 0 ] || fail "a start without Paseo's answer must fail the spawn"$'\n'"$out"
  assert_contains "$out" "did not report an outcome" "a lost start says so"
  [ "$(pa_call_line '^treehouse return')" = 0 ] || fail "a start that may have created an agent keeps the lease"
  assert_absent "$STATE/$id.meta" "a lost start publishes no record"
  pass "fm-spawn.sh backend=paseo-agent: a refused agent start returns the lease, a lost one keeps it"
}

fm_test_run \
  test_status_table_maps_every_paseo_row \
  test_model_selection_resolves_against_the_catalog \
  test_send_text_submit_verdicts_and_verbatim_text \
  test_kill_is_a_proven_idempotent_archive \
  test_native_interrupt_claims \
  test_workspace_state_and_retire \
  test_project_ensure_matches_realpath_or_registers \
  test_pending_permission_escalates_once \
  test_host_follow_selects_paseo_agent_only_inside_a_real_paseo_agent \
  test_host_follow_selects_orca_from_its_own_markers \
  test_busy_and_dispatch_read_paseo_native_state \
  test_spawn_leases_slot_opens_workspace_and_starts_agent_last \
  test_spawn_without_backend_follows_a_paseo_agent_host \
  test_control_lib_tables \
  test_control_interrupt_exit_and_relaunch \
  test_scout_teardown_archives_agent_and_workspace_before_slot_return \
  test_design_worker_keeps_the_plannotator_inbox \
  test_spawn_refuses_what_paseo_cannot_honor \
  test_refused_agent_start_returns_lease_and_lost_start_keeps_it
