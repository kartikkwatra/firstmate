#!/usr/bin/env bash
# Opt-in credentialed live guard: an omp primary inside Orca's native chat
# receives a watcher wake while idle and runs it as a turn.
#
# Orca runs a chat agent as `omp acp`, and omp's ACP mode parks any turn the
# agent itself asks for until the client next prompts, so a plain follow-up
# wake waits for the captain to type. The watch extension therefore hands the
# wake to Orca (.pi/extensions/lib/fm-orca-chat-send.ts owns that contract).
# That contract is Orca-internal, so this guard is the re-verification after
# any Orca or omp update. It needs a running Orca, the `orca` CLI, and the
# captain's existing omp login, and it spends model tokens.
#
# It clones this working tree into a throwaway lab, registers the lab as an
# Orca folder workspace, opens an omp chat there, arms the lab's own watcher
# (the lab is its own Firstmate home, so nothing touches the captain's), lets
# the chat go idle, fires one actionable status line, and requires the chat's
# session log to show that wake as a user turn the model answered. Cleanup
# closes the chat, removes the workspace from Orca, reaps lab processes by
# path, and deletes the lab and its omp session logs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OMP_ORCA_CHAT_LIVE omp orca node git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL=${FM_OMP_ORCA_CHAT_LIVE_MODEL:-anthropic/claude-haiku-4-5}
OMP_VERSION=$(omp --version 2>/dev/null | head -1)
LAB=$(mktemp -d /tmp/fm-omp-orca-live.XXXXXX)
PROJECT="$LAB/project"
SESSIONS="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/sessions/$(printf '%s' "$PROJECT" | tr '/' '-')"
REPO_ID=
SESSION_ID=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

# One Orca runtime RPC through the same metadata the orca CLI reads.
orca_rpc() {  # <method> <params-json>
  ORCA_METHOD=$1 ORCA_PARAMS=$2 node --input-type=module <<'EOF'
import { createConnection } from "node:net";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
const dir = process.env.ORCA_USER_DATA_PATH || `${process.env.XDG_CONFIG_HOME || `${process.env.HOME}/.config`}/orca`;
const meta = JSON.parse(readFileSync(`${dir}/orca-runtime.json`, "utf8"));
const socket = createConnection(meta.transports.find((t) => t.kind === "unix").endpoint);
const id = randomUUID();
let buffered = "";
socket.setEncoding("utf8");
socket.on("data", (chunk) => {
  buffered += chunk;
  for (let i = buffered.indexOf("\n"); i >= 0; i = buffered.indexOf("\n")) {
    const frame = JSON.parse(buffered.slice(0, i));
    buffered = buffered.slice(i + 1);
    if (frame._keepalive) continue;
    process.stdout.write(`${JSON.stringify(frame)}\n`);
    socket.end();
  }
});
socket.on("connect", () => socket.write(`${JSON.stringify({ id, authToken: meta.authToken, method: process.env.ORCA_METHOD, params: JSON.parse(process.env.ORCA_PARAMS) })}\n`));
EOF
}

lab_pids() {
  ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'
}

cleanup() {
  local pid
  [ -z "$SESSION_ID" ] || orca_rpc agentSession.close "{\"sessionId\":\"$SESSION_ID\"}" >/dev/null 2>&1 || true
  [ -z "$REPO_ID" ] || orca project setup-delete --setup "$REPO_ID" --force --json >/dev/null 2>&1 || true
  for pid in $(lab_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(lab_pids); do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$LAB" "$SESSIONS"
}
trap cleanup EXIT

# The lab chat's omp session log; the lab opens exactly one chat, so its
# session directory holds one log.
chat_log() {
  local file
  for file in "$SESSIONS"/*.jsonl; do
    [ -f "$file" ] && printf '%s\n' "$file"
    return 0
  done
}

# Every user and assistant message in the lab chat's omp session log, one JSON
# object per line: {role, stop, text}.
chat_messages() {
  local file
  file=$(chat_log)
  [ -n "$file" ] || return 0
  node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
for (const line of lines) {
  const entry = JSON.parse(line);
  if (entry.type !== "message") continue;
  const m = entry.message || {};
  const text = typeof m.content === "string" ? m.content : (m.content || []).map((p) => p.text || "").join("");
  console.log(JSON.stringify({ role: m.role, stop: m.stopReason || null, text }));
}' "$file"
}

wait_until() {  # <attempts> <command...>; half-second polls
  local attempts=$1 i=0
  shift
  while [ "$i" -lt "$attempts" ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# The chat has finished a turn and written nothing for ten seconds.
chat_idle() {
  local file last before
  file=$(chat_log)
  [ -n "$file" ] || return 1
  last=$(chat_messages | tail -1)
  case "$last" in *'"role":"assistant"'*) ;; *) return 1 ;; esac
  case "$last" in *'"stop":"toolUse"'*) return 1 ;; esac
  before=$(wc -c < "$file")
  sleep 10
  [ "$(wc -c < "$file")" = "$before" ]
}

# Send one user message into the lab chat through the adapter under test.
chat_send() {  # <text>
  ADAPTER="$PROJECT/.pi/extensions/lib/fm-orca-chat-send.ts" SESSION_ID="$SESSION_ID" TEXT=$1 node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { sendToOrcaChat, orcaChatTarget } = await import(pathToFileURL(process.env.ADAPTER).href);
const target = orcaChatTarget({ ...process.env, ORCA_STRUCTURED_SESSION: "1", ORCA_AGENT_SESSION_ID: process.env.SESSION_ID }, ["node", "lab", "acp"]);
process.stdout.write(`${await sendToOrcaChat(target, process.env.TEXT)}\n`);
EOF
}

watcher_alive() {
  local pid
  pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# The wake reached the chat as a user turn that still begins with the typed
# operational marker (away-mode gating and wake consumption key on it), and the
# model answered it.
wake_answered() {
  chat_messages | node -e '
const rows = require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
const at = rows.findIndex((r) => r.role === "user" && r.text.startsWith("\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal:"));
process.exit(at >= 0 && rows.slice(at + 1).some((r) => r.role === "assistant") ? 0 : 1);'
}

orca status --json >/dev/null 2>&1 || fail "Orca is not running or the orca CLI cannot reach it"

# --- lab: this working tree, its own home, and auto-approved tools ------------
git clone -q "$ROOT" "$PROJECT" || fail "could not clone the repository into the lab"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$ROOT/$path" ] || continue
  mkdir -p "$PROJECT/$(dirname "$path")"
  cp "$ROOT/$path" "$PROJECT/$path"
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data"
# An Orca chat asks the captain before every bash call unless omp approves it,
# and a lab turn must never wait on a card in the captain's Orca.
printf 'tools:\n  approvalMode: yolo\n' > "$PROJECT/.omp/config.yml"

REPO_ID=$(orca repo add --path "$PROJECT" --kind folder --json | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0, "utf8")).result.repo.id)') ||
  fail "could not register the lab as an Orca folder workspace"
SESSION_ID=$(cd "$PROJECT" && orca agent launch --agent omp --surface chat --worktree "path:$PROJECT" --model "$MODEL" --json |
  node -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); if (r.result?.outcome?.kind !== "structured") process.exit(1); process.stdout.write(r.result.outcome.sessionId)') ||
  fail "Orca did not open the lab as an omp chat"
wait_until 120 test -f "$PROJECT/state/.omp-watch-extension-loaded" || fail "the lab chat did not load the omp watch extension"
pass "Orca opened an omp chat ($OMP_VERSION) in the lab and it loaded the watch extension"

# --- arm the lab watcher, then let the chat go idle ---------------------------
outcome=$(chat_send "Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim and nothing else. Never run bin/fm-watch-arm.sh through bash.") ||
  fail "the adapter could not send the arm prompt into the lab chat"
[ "$outcome" = sent ] || [ "$outcome" = queued ] || fail "unexpected adapter outcome '$outcome'"
wait_until 360 watcher_alive || fail "no live lab watcher after the arm prompt"
wait_until 60 chat_idle || fail "the lab chat did not go idle after arming"
turns_before=$(chat_messages | grep -c '"role":"user"')
pass "the adapter's message started a chat turn that armed the lab watcher, and the chat is idle"

# --- one actionable status line while the chat is idle -------------------------
: > "$PROJECT/state/orca-e2e.meta"
fired_at=$(date +%s)
printf 'done: orca chat live e2e wake\n' > "$PROJECT/state/orca-e2e.status"
wait_until 480 wake_answered || fail "the idle Orca chat never ran the watcher wake as a turn (user turns before: $turns_before)"
printf '# wake answered %ss after the status line, with the chat idle beforehand\n' "$(($(date +%s) - fired_at))"
pass "an idle Orca chat received the watcher wake through Orca and ran it as a turn"
