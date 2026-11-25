#!/usr/bin/env bash
# bin/backends/paseo-agent.sh - the native Paseo agent adapter (EXPERIMENTAL).
#
# Each ship or scout worker is an ordinary Paseo agent: the captain opens it,
# reads it, and types into it in Paseo's own chat UI, exactly like an agent
# Paseo started itself. Paseo owns the agent session (it launches the harness
# through its provider); Treehouse still owns the task worktree, which a
# per-task LOCAL Paseo workspace attached to the project points at. Nothing is
# typed into a terminal: a steer is `paseo send`, an interrupt is `paseo stop`,
# and the end of a worker is `paseo archive`. docs/paseo-agent-backend.md owns
# the contract; this header owns the mechanics.
#
# Target string shape: the Paseo agent id (a UUID) the daemon assigned when the
# worker was created. The task record keeps it as paseo_agent_id= and the
# per-task workspace as paseo_agent_workspace_id=; window= is the fm-<id> alias.
#
# Why Treehouse rather than a Paseo-managed worktree: archiving a Paseo-managed
# worktree workspace deletes its directory, uncommitted files included
# (verified on Paseo 0.17.4), so one click in the sidebar could discard
# unlanded work. A local workspace pointed at a Treehouse slot leaves the
# directory alone when archived (verified), and the slot keeps Firstmate's
# landed-work, freshen, and return machinery.
#
# Verified facts (Paseo 0.17.4 on Linux; docs/verification/runtime-backends.md
# "Paseo agents" owns the dated evidence):
#   1. `paseo run --no-wait --json --workspace <wks>` creates the agent in that
#      workspace's directory even when the caller is itself an agent, and
#      returns {agentId, status}. `--env K=V` reaches the agent's shell.
#   2. `paseo inspect <id> --json` reports Status (initializing, idle, running,
#      error, closed), Archived, and PendingPermissions; an unknown id exits 1
#      with error.code AGENT_NOT_FOUND in the JSON error it prints on stderr.
#   3. `paseo send <id> --behavior steer` starts an idle agent's turn and joins
#      a running one; `paseo stop <id>` ends a running turn and leaves the agent
#      idle; `paseo archive <id> --force` interrupts and archives it
#      (Status closed, Archived true).
#   4. The omp provider refuses GIT_CONFIG_* (and PATH, HOME, ...) in an
#      agent's environment, so the Git hook override other backends export
#      cannot ride this backend's environment channel.
#
# Requires: paseo (CLI; resolved by bin/backends/paseo.sh's fm_backend_paseo_bin,
# which also honours PASEO_CLI on a Linux AppImage install), jq, treehouse.

# shellcheck source=bin/backends/paseo.sh
declare -F fm_backend_paseo_bin >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/paseo.sh"

# Verified minimum: the release the live pass ran against.
FM_BACKEND_PASEO_AGENT_MIN_MAJOR=0
FM_BACKEND_PASEO_AGENT_MIN_MINOR=17

# The status word the probe reports for each row of the one status table
# (fm_backend_paseo_agent_state_row) is all any caller reads.
FM_BACKEND_PASEO_AGENT_INTERRUPT_WAIT="${FM_BACKEND_PASEO_AGENT_INTERRUPT_WAIT:-15}"

fm_backend_paseo_agent_tool_check() {
  fm_backend_paseo_bin >/dev/null 2>&1 || {
    echo "error: backend=paseo-agent selected but the 'paseo' CLI was not found (PATH, \$PASEO_CLI, or $FM_BACKEND_PASEO_BUNDLE_BIN); see docs/paseo-agent-backend.md" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=paseo-agent selected but 'jq' is not installed" >&2; return 1; }
  command -v treehouse >/dev/null 2>&1 || { echo "error: backend=paseo-agent selected but 'treehouse' is not installed" >&2; return 1; }
}

# fm_backend_paseo_agent_version_ok <version>: 0 when <version> is at or past
# the verified minimum.
fm_backend_paseo_agent_version_ok() {  # <version>
  local ver=$1 major rest minor
  case "$ver" in ''|*[!0-9.]*) return 1 ;; esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -gt "$FM_BACKEND_PASEO_AGENT_MIN_MAJOR" ] && return 0
  [ "$major" -eq "$FM_BACKEND_PASEO_AGENT_MIN_MAJOR" ] && [ "$minor" -ge "$FM_BACKEND_PASEO_AGENT_MIN_MINOR" ]
}

# fm_backend_paseo_agent_runtime_check: the CLI, its version, and a reachable
# daemon, before any spawn, control, or teardown mutation. The daemon is the
# desktop app's own, so it is never started from here.
fm_backend_paseo_agent_runtime_check() {
  local raw ver
  fm_backend_paseo_agent_tool_check || return 1
  raw=$(fm_backend_paseo_cli -v 2>/dev/null) || { echo "error: 'paseo -v' failed; is Paseo installed correctly?" >&2; return 1; }
  ver=$(printf '%s' "$raw" | awk 'NF { v = $1 } END { print v }')
  fm_backend_paseo_agent_version_ok "$ver" || {
    echo "error: paseo '${ver:-unknown}' is older than the verified minimum $FM_BACKEND_PASEO_AGENT_MIN_MAJOR.$FM_BACKEND_PASEO_AGENT_MIN_MINOR for backend=paseo-agent" >&2
    return 1
  }
  [ "$(fm_backend_paseo_daemon_state)" = ok ] || {
    echo "error: the Paseo daemon is not reachable ('paseo status'); open the Paseo app first (docs/paseo-agent-backend.md)" >&2
    return 1
  }
}

fm_backend_paseo_agent_validate_harness() {  # <harness>
  case "$1" in
    omp) return 0 ;;
    *) echo "error: backend=paseo-agent runs only the omp harness (verified through Paseo's omp provider), not '$1'" >&2; return 1 ;;
  esac
}

# fm_backend_paseo_agent_model_selection <harness> <model> <effort>: the
# `--provider` and `--thinking` values for `paseo run`, tab-separated, resolved
# against the provider's own catalog (`paseo provider models <harness>`). A
# model matches a catalog id exactly or, unprefixed, the one id whose last
# path segment it is; an effort must be one of that model's thinking options.
# default leaves either choice to the provider, which then checks an effort
# against its own default model when the agent starts.
fm_backend_paseo_agent_model_selection() {  # <harness> <model> <effort>
  local harness=$1 model=${2:-default} effort=${3:-default} list id matches options
  [ "$model" != default ] || model=
  [ "$effort" != default ] || effort=
  if [ -z "$model" ]; then
    printf '%s\t%s' "$harness" "$effort"
    return 0
  fi
  list=$(fm_backend_paseo_cli_json provider models "$harness" --json) || return 1
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    echo "error: 'paseo provider models $harness' returned no model list" >&2
    return 1
  }
  id=$(printf '%s' "$list" | jq -r --arg m "$model" '[.[] | select(.id == $m) | .id] | .[0] // empty')
  if [ -z "$id" ]; then
    matches=$(printf '%s' "$list" | jq -r --arg m "$model" '.[] | select((.id | split("/") | last) == $m) | .id')
    case "$(printf '%s' "$matches" | grep -c .)" in
      1) id=$matches ;;
      0)
        echo "error: Paseo's $harness provider lists no model '$model'; choose one of: $(printf '%s' "$list" | jq -r '[.[].id] | join(", ")')" >&2
        return 1
        ;;
      *)
        echo "error: model '$model' matches several of Paseo's $harness models ($(printf '%s' "$matches" | paste -sd, -)); pass the full id" >&2
        return 1
        ;;
    esac
  fi
  if [ -n "$effort" ]; then
    options=$(printf '%s' "$list" | jq -r --arg id "$id" '.[] | select(.id == $id) | (.thinkingOptionIds // []) | join(" ")')
    case " $options " in
      *" $effort "*) ;;
      *)
        echo "error: Paseo's $harness model $id has no thinking option '$effort'; it offers: ${options:-none}" >&2
        return 1
        ;;
    esac
  fi
  printf '%s/%s\t%s' "$harness" "$id" "$effort"
}

# fm_backend_paseo_agent_labels: the label arguments every Firstmate worker
# carries, home-scoped so two homes on one daemon never claim each other's.
fm_backend_paseo_agent_label_args() {  # <id> <kind>
  printf '%s\n' --label "fm-home=$(fm_backend_hometag)" --label "fm-task=$1" --label "fm-kind=$2"
}

# --- projects and per-task workspaces -----------------------------------------

# fm_backend_paseo_agent_project_ensure <project-path>: the Paseo project id
# registered for <project-path> (matched by physical path), registering the
# directory when Paseo has none. An unreadable inventory refuses rather than
# registering a duplicate.
fm_backend_paseo_agent_project_ensure() {  # <project-path>
  local path=$1 real list id
  real=$(cd "$path" 2>/dev/null && pwd -P) || { echo "error: project path $path is not a directory" >&2; return 1; }
  list=$(fm_backend_paseo_cli_json project ls --json) || return 1
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "error: 'paseo project ls' returned no project list" >&2; return 1; }
  id=$(printf '%s' "$list" | jq -r --arg a "$path" --arg b "$real" '[.[] | select(.path == $a or .path == $b) | .projectId] | .[0] // empty')
  if [ -z "$id" ]; then
    id=$(fm_backend_paseo_cli_json project create "$real" --json | jq -r '.projectId // empty' 2>/dev/null)
  fi
  case "$id" in
    prj_*) printf '%s' "$id" ;;
    *) echo "error: Paseo did not report a project id for $real" >&2; return 1 ;;
  esac
}

# fm_backend_paseo_agent_workspace_create <project-id> <worktree> <title>: a
# LOCAL workspace on the leased worktree, attached to the project so it shows
# under it in Paseo's sidebar. Echoes the workspace id.
fm_backend_paseo_agent_workspace_create() {  # <project-id> <worktree> <title>
  local out id
  out=$(fm_backend_paseo_cli_json workspace create --isolation local --project "$1" --path "$2" --title "$3" --json) || return 1
  id=$(printf '%s' "$out" | jq -r '.workspaceId // empty' 2>/dev/null)
  case "$id" in
    wks_*) printf '%s' "$id" ;;
    *) echo "error: Paseo did not report a workspace id for $2" >&2; return 1 ;;
  esac
}

# fm_backend_paseo_agent_workspace_state <workspace-id> <worktree>: whether the
# task's own workspace is still active on its recorded worktree. Prints
# active, absent (archived or never known), or elsewhere (active on another
# directory); exit 1 when the inventory is unreadable.
fm_backend_paseo_agent_workspace_state() {  # <workspace-id> <worktree>
  local wks=$1 wt=$2 list cwd real
  list=$(fm_backend_paseo_cli_json workspace ls --background --json) || return 1
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  cwd=$(printf '%s' "$list" | jq -r --arg id "$wks" '.[] | select(.workspaceId == $id) | .cwd' | head -1)
  if [ -z "$cwd" ]; then
    printf absent
    return 0
  fi
  real=$(cd "$wt" 2>/dev/null && pwd -P) || real=$wt
  if [ "$cwd" = "$wt" ] || [ "$cwd" = "$real" ]; then
    printf active
  else
    printf elsewhere
  fi
}

# fm_backend_paseo_agent_workspace_retire <workspace-id> <worktree>: archive the
# task's own workspace once its agent is archived. Only a live workspace whose
# directory is the recorded worktree is archived; an absent one is already the
# end state. Archiving a local workspace never touches its directory.
fm_backend_paseo_agent_workspace_retire() {  # <workspace-id> <worktree>
  local wks=$1 wt=$2 state
  [ -n "$wks" ] || return 0
  state=$(fm_backend_paseo_agent_workspace_state "$wks" "$wt") || return 1
  case "$state" in
    absent) return 0 ;;
    elsewhere)
      echo "error: Paseo workspace $wks points at another directory, not the task worktree $wt; leaving it in place" >&2
      return 1
      ;;
  esac
  fm_backend_paseo_cli_json workspace archive "$wks" --json >/dev/null
}

# --- agent lifecycle ------------------------------------------------------------

# fm_backend_paseo_agent_call <err-file> <args...>: one CLI call with stdout
# printed and stderr kept in <err-file>. The CLI prints its typed error object
# ({"error":{"code":...}}) on stderr, after any Electron warning lines.
fm_backend_paseo_agent_call() {  # <err-file> <paseo-args...>
  local err=$1
  shift
  fm_backend_paseo_cli "$@" 2>"$err"
}

# fm_backend_paseo_agent_error_code <err-file>: the typed error code Paseo
# reported, or empty.
fm_backend_paseo_agent_error_code() {  # <err-file>
  sed -n 's/.*"code": *"\([A-Z_][A-Z_]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# fm_backend_paseo_agent_create <workspace-id> <title> <provider> <thinking>
#   <id> <kind> <prompt-file> [NAME=VALUE...]: start the worker as a Paseo agent
# in the task's workspace with the launch brief as its first message, at the
# provider's full-access mode. <provider> and <thinking> come from
# fm_backend_paseo_agent_model_selection. Echoes the agent id. Exit 1 when
# Paseo refused before creating anything, 2 when the outcome is unknown (the
# call failed after it may have created the agent).
fm_backend_paseo_agent_create() {
  local wks=$1 title=$2 provider=$3 thinking=$4 id=$5 kind=$6 prompt_file=$7 out agent pair
  shift 7
  local -a args=(run --no-wait --json --workspace "$wks" --provider "$provider" --mode full --title "$title")
  [ -z "$thinking" ] || args+=(--thinking "$thinking")
  while IFS= read -r pair; do args+=("$pair"); done < <(fm_backend_paseo_agent_label_args "$id" "$kind")
  for pair in "$@"; do args+=(--env "$pair"); done
  [ -r "$prompt_file" ] || { echo "error: launch brief $prompt_file is not readable" >&2; return 1; }
  args+=("$(cat "$prompt_file")")
  local err rc=0
  err=$(mktemp "${TMPDIR:-/tmp}/fm-paseo-agent-err.XXXXXX") || return 1
  out=$(fm_backend_paseo_agent_call "$err" "${args[@]}") || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$err" >&2
    # A typed refusal is Paseo's answer before registration, which commits
    # creation; anything else (a lost connection) leaves the outcome unknown.
    if [ -n "$(fm_backend_paseo_agent_error_code "$err")" ]; then rc=1; else rc=2; fi
    rm -f "$err"
    return "$rc"
  fi
  rm -f "$err"
  agent=$(printf '%s' "$out" | jq -r '.agentId // empty' 2>/dev/null)
  case "$agent" in
    ''|*[!0-9a-fA-F-]*) echo "error: Paseo did not report an agent id for $title" >&2; return 2 ;;
  esac
  printf '%s' "$agent"
}

# fm_backend_paseo_agent_inspect <id>: the daemon's `inspect --json` object.
# Exit 3 on the daemon's own AGENT_NOT_FOUND, 1 on any other failure.
fm_backend_paseo_agent_inspect() {  # <agent-id>
  local out err rc=0 code
  case "$1" in ''|*[!0-9a-fA-F-]*) return 1 ;; esac
  err=$(mktemp "${TMPDIR:-/tmp}/fm-paseo-agent-err.XXXXXX") || return 1
  out=$(fm_backend_paseo_agent_call "$err" inspect "$1" --json) || rc=$?
  code=$(fm_backend_paseo_agent_error_code "$err")
  rm -f "$err"
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out"
    return 0
  fi
  [ "$code" = AGENT_NOT_FOUND ] && return 3
  return 1
}

# fm_backend_paseo_agent_probe <id>: one word naming the agent's row in the
# status table: running, starting (initializing), idle, blocked (a pending
# permission or question waits on a human), closed (the runtime was stopped,
# a send resumes it), error, archived, not-found, or unreadable.
fm_backend_paseo_agent_probe() {  # <agent-id>
  local out rc=0
  out=$(fm_backend_paseo_agent_inspect "$1") || rc=$?
  case "$rc" in
    0) ;;
    3) printf 'not-found'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  printf '%s' "$out" | jq -r '
    if (.Id // "") == "" then "unreadable"
    elif .Archived == true then "archived"
    elif ((.PendingPermissions // []) | length) > 0 then "blocked"
    else ({"running":"running","initializing":"starting","idle":"idle","closed":"closed","error":"error"}[.Status // ""] // "unreadable")
    end' 2>/dev/null || printf 'unreadable'
}

# The one status table: "<busy_state> <agent_state>" per probe row. An
# archived agent left its workspace and worktree behind, so the endpoint is
# there with no agent (dead), which is what licenses a relaunch into it.
fm_backend_paseo_agent_state_row() {  # <probe-row>
  case "$1" in
    running|starting) printf 'busy alive' ;;
    # A pending permission is not progress: it reads idle so the wedge
    # ladder never defers it as a running turn.
    blocked|idle|closed) printf 'idle alive' ;;
    error|archived) printf 'unknown dead' ;;
    not-found) printf 'unknown missing' ;;
    *) printf 'unknown unreadable' ;;
  esac
}

fm_backend_paseo_agent_busy_state() {  # <agent-id>
  local row
  row=$(fm_backend_paseo_agent_state_row "$(fm_backend_paseo_agent_probe "$1")")
  printf '%s' "${row%% *}"
}

fm_backend_paseo_agent_agent_state() {  # <agent-id>
  local row
  row=$(fm_backend_paseo_agent_state_row "$(fm_backend_paseo_agent_probe "$1")")
  printf '%s' "${row#* }"
}

fm_backend_paseo_agent_target_exists() {  # <agent-id>
  case "$(fm_backend_paseo_agent_agent_state "$1")" in
    alive|dead) return 0 ;;
  esac
  return 1
}

# A Paseo agent has no composer to clear, so a live one is ready for a steer.
fm_backend_paseo_agent_composer_state() {  # <agent-id> [expected-label] -> empty|unknown
  case "$(fm_backend_paseo_agent_probe "$1")" in
    archived|not-found|unreadable) printf 'unknown' ;;
    *) printf 'empty' ;;
  esac
}

# fm_backend_paseo_agent_capture: the agent's recent activity as Paseo's own
# transcript renders it, then one status line.
fm_backend_paseo_agent_capture() {  # <agent-id> <lines>
  local lines=${2:-40}
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  fm_backend_paseo_cli logs "$1" --tail "$lines" 2>/dev/null | tail -n "$lines" || return 1
  printf 'paseo-agent: status=%s\n' "$(fm_backend_paseo_agent_probe "$1")"
}

# fm_backend_paseo_agent_send_text_submit: one `paseo send` with steer
# behaviour, which starts an idle agent's turn or joins the running one. The
# text rides a private file, never argv, so option-shaped or long text is
# delivered verbatim. Echoes empty (Paseo reported it sent), send-failed
# (Paseo refused it with a typed error, or nothing was sent), or unconfirmed
# (the call failed without Paseo's answer, so it may have landed).
fm_backend_paseo_agent_send_text_submit() {  # <agent-id> <text> [retries enter-sleep settle label]
  local agent=$1 text=$2 file err out rc=0
  file=$(umask 077 && mktemp "${TMPDIR:-/tmp}/fm-paseo-agent-send.XXXXXX") || { printf 'send-failed'; return 0; }
  printf '%s' "$text" > "$file" || { rm -f "$file"; printf 'send-failed'; return 0; }
  err=$(mktemp "${TMPDIR:-/tmp}/fm-paseo-agent-err.XXXXXX") || { rm -f "$file"; printf 'send-failed'; return 0; }
  out=$(fm_backend_paseo_agent_call "$err" send "$agent" --prompt-file "$file" --behavior steer --no-wait --json) || rc=$?
  rm -f "$file"
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null)" = sent ]; then
    printf 'empty'
  elif [ "$rc" -ne 0 ] && [ -z "$(fm_backend_paseo_agent_error_code "$err")" ]; then
    cat "$err" >&2
    printf 'unconfirmed'
  else
    cat "$err" >&2
    printf 'send-failed'
  fi
  rm -f "$err"
}

# fm_backend_paseo_agent_native_interrupt <id>: stop the running turn and print
# the claim: confirmed (it was running and now is not), not-running, or
# unconfirmed.
fm_backend_paseo_agent_native_interrupt() {  # <agent-id>
  local agent=$1 before after i=0
  before=$(fm_backend_paseo_agent_probe "$agent")
  case "$before" in
    archived|not-found|unreadable) return 1 ;;
  esac
  fm_backend_paseo_cli_json stop "$agent" --json >/dev/null || return 1
  case "$before" in
    running|starting) ;;
    *) printf 'not-running'; return 0 ;;
  esac
  while [ "$i" -lt "$FM_BACKEND_PASEO_AGENT_INTERRUPT_WAIT" ]; do
    after=$(fm_backend_paseo_agent_probe "$agent")
    case "$after" in
      running|starting) ;;
      idle|blocked|closed) printf 'confirmed'; return 0 ;;
      *) printf 'unconfirmed'; return 0 ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  printf 'unconfirmed'
}

fm_backend_paseo_agent_send_key() {  # <agent-id> <key>
  case "$2" in
    Escape|escape|Esc|esc|C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_paseo_agent_native_interrupt "$1" >/dev/null
      ;;
    Enter|enter) return 0 ;;
    *)
      echo "error: unsupported Paseo agent key '$2'" >&2
      return 1
      ;;
  esac
}

# fm_backend_paseo_agent_kill <id>: interrupt and archive the agent, and succeed
# only on Paseo's read-back of an archived agent (or one the daemon no longer
# has). Archiving keeps the transcript in Paseo's archive. Idempotent.
fm_backend_paseo_agent_kill() {  # <agent-id>
  local agent=$1
  case "$(fm_backend_paseo_agent_probe "$agent")" in
    archived|not-found) return 0 ;;
    unreadable) return 1 ;;
  esac
  fm_backend_paseo_cli_json archive "$agent" --force --json >/dev/null || return 1
  case "$(fm_backend_paseo_agent_probe "$agent")" in
    archived|not-found) return 0 ;;
  esac
  return 1
}

# fm_backend_paseo_agent_native_exit: the control plane's `exit` - the same
# proven archive, which leaves the workspace and worktree for a relaunch.
fm_backend_paseo_agent_native_exit() {  # <agent-id>
  fm_backend_paseo_agent_kill "$1"
}

# There is no pane: bin/fm-spawn.sh's launch-time typing helpers land here.
fm_backend_paseo_agent_send_literal() {
  echo "error: backend=paseo-agent has no pane to type into" >&2
  return 1
}

# --- native event wait ----------------------------------------------------------
#
# A pending permission or question is the actionable `blocked` edge: the
# worker waits on a human. bin/fm-watch.sh's push splice calls these through
# bin/fm-backend.sh; one `paseo permit ls` per check covers every recorded
# worker, and each set of request ids is escalated once.

FM_BACKEND_PASEO_AGENT_ESCALATED_PREFIX=.paseo-agent-escalated-
FM_BACKEND_PASEO_AGENT_WAIT_STEP="${FM_BACKEND_PASEO_AGENT_WAIT_STEP:-5}"

fm_backend_paseo_agent_escalation_marker() {  # <state_dir> <agent-id>
  printf '%s/%s%s' "$1" "$FM_BACKEND_PASEO_AGENT_ESCALATED_PREFIX" "$2"
}

fm_backend_paseo_agent_events_capable() {  # <session>
  fm_backend_paseo_bin >/dev/null 2>&1 && [ "$(fm_backend_paseo_daemon_state)" = ok ]
}

# fm_backend_paseo_agent_pending_signatures: "<agent-id>\t<request ids>" per
# agent with pending requests, from one `paseo permit ls --json`.
fm_backend_paseo_agent_pending_signatures() {
  local out
  out=$(fm_backend_paseo_cli permit ls --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '
    if type != "array" then error("not a list") else . end
    | group_by(.agentId)[]
    | "\(.[0].agentId)\t\([.[] | .requestId // .id] | sort | join(","))"' 2>/dev/null
}

# fm_backend_paseo_agent_wait_transition: 0 with a normalized `blocked` record
# (pane_id = agent id, workspace_id = request ids) on a fresh pending request;
# 1 when the budget passed; 2 when the daemon could not be read.
fm_backend_paseo_agent_wait_transition() {  # <session> <timeout_secs> <state_dir> <agent...>
  local timeout=$2 state=$3 waited=0 sigs agent ids marker want step
  shift 3
  step=$FM_BACKEND_PASEO_AGENT_WAIT_STEP
  while :; do
    sigs=$(fm_backend_paseo_agent_pending_signatures) || return 2
    for want in "$@"; do
      marker=$(fm_backend_paseo_agent_escalation_marker "$state" "$want")
      ids=$(printf '%s\n' "$sigs" | awk -F '\t' -v a="$want" '$1 == a { print $2; exit }')
      if [ -z "$ids" ]; then
        rm -f "$marker"
        continue
      fi
      [ -f "$marker" ] && [ "$(cat "$marker")" = "$ids" ] && continue
      fm_transition_record "$want" "$ids" "" blocked paseo-agent
      return 0
    done
    awk -v w="$waited" -v t="$timeout" 'BEGIN { exit !(w < t) }' || return 1
    sleep "$step"
    waited=$(awk -v w="$waited" -v s="$step" 'BEGIN { print w + s }')
  done
}

fm_backend_paseo_agent_commit_transition() {  # <state_dir> <session> <record>
  local agent ids
  agent=$(fm_transition_pane_id "$3")
  ids=$(fm_transition_workspace_id "$3")
  [ -n "$agent" ] || return 1
  printf '%s' "$ids" > "$(fm_backend_paseo_agent_escalation_marker "$1" "$agent")"
}

fm_backend_paseo_agent_clear_transition() {  # <state_dir> <agent-id>
  [ -n "$2" ] || return 0
  rm -f "$(fm_backend_paseo_agent_escalation_marker "$1" "$2")"
}

fm_backend_paseo_agent_transition_note() {  # <record>
  printf 'Paseo permission request(s) %s pending - read them with paseo permit ls; answer in Paseo or with paseo permit allow|deny' "$(fm_transition_workspace_id "$1")"
}

# --- primary host verification --------------------------------------------------

# fm_backend_paseo_agent_host_agent: the Paseo agent id of the Firstmate
# session this process runs inside, printed only when every structural fact
# agrees: PASEO_AGENT_ID is set, this process descends from the daemon process
# `paseo status --json` reports (pid or workerPid), and the daemon reads that
# agent back unarchived with its working directory equal to this home. An
# inherited marker alone never qualifies: a tmux server or other daemonised
# child is reparented away from the daemon, and a worker agent runs in its
# worktree, not the home.
fm_backend_paseo_agent_host_agent() {
  local agent=${PASEO_AGENT_ID:-} status pids pid hops=0 found=0 out cwd home_real cwd_real
  [ -n "$agent" ] || return 1
  case "$agent" in *[!0-9a-fA-F-]*) return 1 ;; esac
  fm_backend_paseo_bin >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  status=$(fm_backend_paseo_cli status --json 2>/dev/null) || return 1
  pids=" $(printf '%s' "$status" | jq -r '[.pid, .workerPid] | map(select(type == "number")) | map(tostring) | join(" ")' 2>/dev/null) "
  [ "$pids" != "  " ] || return 1
  pid=$$
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
    case "$pids" in *" $pid "*) found=1; break ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    hops=$((hops + 1))
  done
  [ "$found" = 1 ] || return 1
  out=$(fm_backend_paseo_agent_inspect "$agent") || return 1
  [ "$(printf '%s' "$out" | jq -r '.Archived // false' 2>/dev/null)" = false ] || return 1
  cwd=$(printf '%s' "$out" | jq -r '.Cwd // empty' 2>/dev/null)
  [ -n "$cwd" ] || return 1
  home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  cwd_real=$(cd "$cwd" 2>/dev/null && pwd -P) || return 1
  [ "$cwd_real" = "$home_real" ] || return 1
  printf '%s' "$agent"
}
