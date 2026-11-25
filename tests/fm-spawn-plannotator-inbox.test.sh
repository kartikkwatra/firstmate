#!/usr/bin/env bash
# tests/fm-spawn-plannotator-inbox.test.sh - the design worker role and the
# Plannotator Inbox kill switch on the pane launch path.
#
# Every ship and scout must start its agent with PLANNOTATOR_INBOX_TOOL=0, the
# switch the Plannotator host plugins read at session start to withhold the
# `plannotator_inbox` tool, while a design worker (bin/fm-spawn.sh --design)
# keeps its ambient environment so it can ask the captain directly.
#
# Like tests/fm-spawn-compact-adviser-disable.test.sh, the assertions never read
# bin/fm-spawn.sh's source: they drive the real spawn against a fake pane and a
# real isolated git worktree, then EXECUTE the launch command the pane received
# under a synthetic pane environment, with the harness binary replaced by a
# probe that prints the variable it was started with. The Paseo agent channel is
# covered by tests/fm-backend-paseo-agent.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-plannotator-inbox)

# The pane's own value, which a ship or scout launch must override and a design
# launch must leave alone.
AMBIENT=1

# make_case <name> <id> [design]
# Sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG.
make_case() {
  local name=$1 id=$2 role=${3:-}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  if [ "$role" = design ]; then
    printf '\n# Design contract\nWorker role: design\nAsk the captain directly.\n' >> "$HOME_DIR/data/$id/brief.md"
  fi
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# What the agent process would see: replay the pane exports, then the launch
# command, under a pane that already carries AMBIENT.
launched_inbox_switch() {
  local launch preamble
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
printf '%s\n' "${PLANNOTATOR_INBOX_TOOL-unset}"
SH
  chmod +x "$FAKEBIN_DIR/codex"
  launch=$(cat "$LAUNCH_LOG")
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane PLANNOTATOR_INBOX_TOOL="$AMBIENT" \
    /bin/sh -c "$preamble
$launch"
}

meta_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$HOME_DIR/state/$1.meta" | tail -1
}

test_ship_and_scout_start_with_the_inbox_off() {
  local setting kind id out status seen
  for setting in absent enabled; do
    for kind in ship scout; do
      id="inbox-$kind-$setting-a1"
      make_case "$kind-$setting" "$id"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = ship ]; then
        out=$(run_case_spawn "$id" "$PROJ_DIR" --mode local-only --yolo off)
      else
        out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
      seen=$(launched_inbox_switch) || fail "$kind, allowlist $setting: the emitted launch failed to run"
      assert_equals 0 "$seen" \
        "a $kind launched with allowlist=$setting must start with the Plannotator Inbox tool off, overriding the pane's value"
      assert_contains "$(cat "$HOME_DIR/data/$id/launch-brief.md")" "Never use the Plannotator Inbox" \
        "a $kind's role contract must forbid the Inbox"
      assert_equals "" "$(meta_field "$id" role)" "a $kind records no worker role"
    done
  done
  pass "ships and scouts start with PLANNOTATOR_INBOX_TOOL=0 and a never-use-the-Inbox role, in both allowlist postures"
}

test_design_worker_keeps_the_inbox() {
  local id=inbox-design-a1 out status seen brief
  make_case design "$id" design
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode local-only --yolo off --design)
  status=$?
  expect_code 0 "$status" "design spawn should succeed: $out"
  assert_contains "$out" "kind=ship mode=local-only yolo=off" "a design worker is a ship with its delivery contract"
  assert_contains "$out" "role=design" "the spawn summary names the design role"
  assert_equals design "$(meta_field "$id" role)" "the task record keeps the design role"
  assert_equals ship "$(meta_field "$id" kind)" "a design worker is recorded as a ship"
  seen=$(launched_inbox_switch) || fail "design: the emitted launch failed to run"
  assert_equals "$AMBIENT" "$seen" "a design worker must keep the pane's Plannotator environment"
  brief=$(cat "$HOME_DIR/data/$id/launch-brief.md")
  assert_contains "$brief" "You are a design worker" "the design role contract leads the launch brief"
  assert_not_contains "$brief" "Never use the Plannotator Inbox" "the design worker is not told to avoid the Inbox"
  assert_not_contains "$brief" "address the captain." "the design worker is not told never to address the captain"
  pass "a design worker keeps the Inbox, records role=design, and gets the design role contract"
}

test_brief_and_spawn_must_agree_on_the_role() {
  local out status
  make_case mismatch-design design-plain-a1
  out=$(run_case_spawn design-plain-a1 "$PROJ_DIR" --mode local-only --yolo off --design)
  status=$?
  [ "$status" -ne 0 ] || fail "--design on a brief without the design contract must be refused"
  assert_contains "$out" "is not a design brief" "the refusal names the missing design contract"
  assert_absent "$HOME_DIR/state/design-plain-a1.meta" "a refused design spawn publishes no record"

  make_case mismatch-ship ship-design-a1 design
  out=$(run_case_spawn ship-design-a1 "$PROJ_DIR" --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship spawn of a design brief must be refused"
  assert_contains "$out" "declares a design worker; spawn it with --design" "the refusal names the flag"

  make_case mismatch-scout scout-design-a1 design
  out=$(run_case_spawn scout-design-a1 "$PROJ_DIR" --scout --design)
  status=$?
  [ "$status" -ne 0 ] || fail "--design with --scout must be refused"
  assert_contains "$out" "cannot combine with --scout or --secondmate" "the refusal names the conflicting kind"
  pass "brief and spawn must agree on the design role, and --design is ship-only"
}

test_ship_and_scout_start_with_the_inbox_off
test_design_worker_keeps_the_inbox
test_brief_and_spawn_must_agree_on_the_role
