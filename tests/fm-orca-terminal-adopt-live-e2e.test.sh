#!/usr/bin/env bash
# Real-Orca drift guard for the vendor fact the Orca backend's terminal adoption
# depends on.
#
# The verdict comes from what Orca itself emits, so a fake CLI can only confirm
# the assumption already written into the fake: `orca worktree create` opens
# exactly one terminal in the new worktree and returns no handle for it in its
# own plain-create JSON, so the handle has to be recovered by listing that
# worktree's terminals. If a future runtime starts returning the handle,
# adoption still has to produce the SAME terminal and still must not add a
# second one.
#
# Opt-in rather than default-on, unusually for a guard that spends no model
# tokens: Orca has no `repo rm`, so a run leaves one registration behind in the
# operator's Orca for the scratch repository below. The path is stable, so
# repeated runs reuse that single registration rather than adding one each time;
# remove it from the Orca app when it is no longer wanted.
#
# It creates and removes exactly the one worktree it created, identified by the
# id Orca returned for it, and never touches any other worktree or terminal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/orca.sh"

fm_live_gate opt-in FM_LIVE_ORCA orca node git

if ! fm_backend_orca_runtime_check >/dev/null 2>&1; then
  case "${FM_LIVE_ORCA:-${FM_LIVE:-}}" in
    1) fail "FM_LIVE_ORCA=1 but the Orca runtime is not ready" ;;
    *) printf 'skip: live: orca runtime not ready\n'; exit 0 ;;
  esac
fi

REPO="${TMPDIR:-/tmp}/fm-orca-live-guard-repo"
NAME="fm-orca-live-guard-$$"
CREATED_WORKTREE_ID=

cleanup() {
  # Remove only the worktree this run created, proven by the id Orca returned.
  [ -n "$CREATED_WORKTREE_ID" ] || return 0
  case "$CREATED_WORKTREE_ID" in
    *"/$NAME") fm_backend_orca_remove_worktree "$CREATED_WORKTREE_ID" >/dev/null 2>&1 || true ;;
    *) printf 'not ok - refusing to remove unexpected worktree id %s\n' "$CREATED_WORKTREE_ID" >&2 ;;
  esac
  CREATED_WORKTREE_ID=
}
trap cleanup EXIT

if [ ! -d "$REPO/.git" ]; then
  rm -rf -- "$REPO"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email 'orca-live-guard@example.invalid'
  git -C "$REPO" config user.name 'orca live guard'
  printf 'Orca live guard scratch repository.\n' > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" -c commit.gpgsign=false commit -qm 'fixture: initialize the Orca live guard repository'
fi

RAW=$(fm_backend_orca_worktree_create "$REPO" "$NAME") \
  || fail "orca worktree create failed for the live guard worktree"
WT_ID=${RAW%%$'\t'*}
REST=${RAW#*$'\t'}
WT_PATH=${REST%%$'\t'*}
if [ "$REST" = "$WT_PATH" ]; then TERM_HANDLE=; else TERM_HANDLE=${REST#*$'\t'}; fi
CREATED_WORKTREE_ID=$WT_ID

[ -n "$WT_ID" ] || fail "orca worktree create returned no worktree id"
[ -d "$WT_PATH" ] || fail "orca worktree create reported a path that does not exist: $WT_PATH"

[ -n "$TERM_HANDLE" ] \
  || fail "orca $(orca --version 2>/dev/null): the backend produced no terminal handle for a freshly created worktree, so every spawn would open a second terminal"

LISTED=$(orca terminal list --worktree "id:$WT_ID" --json) \
  || fail "orca terminal list failed for the live guard worktree"
COUNT=$(printf '%s' "$LISTED" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const list = (data.result && data.result.terminals) || [];
process.stdout.write(String(list.length));
')
[ "$COUNT" = 1 ] \
  || fail "orca $(orca --version 2>/dev/null): a freshly created worktree holds $COUNT terminals, expected exactly Orca's own one"

FIRST=$(printf '%s' "$LISTED" | fm_backend_orca_json_get first-terminal-handle) \
  || fail "could not read the worktree's terminal handle from orca terminal list"
[ "$TERM_HANDLE" = "$FIRST" ] \
  || fail "the adapter adopted '$TERM_HANDLE' but the worktree's only terminal is '$FIRST'"
pass "orca worktree create: its own single terminal is adopted, never duplicated"

cleanup
pass "orca worktree rm: the guard's own worktree is released"
