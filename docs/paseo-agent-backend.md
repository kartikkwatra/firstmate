# Paseo agent runtime backend

`paseo-agent` is an experimental backend in which each ship or scout worker is a native Paseo agent.
The worker appears in Paseo's own chat UI exactly like an agent Paseo started itself, so it can be opened, read, and typed into there.
Paseo owns the agent session and starts the harness through its provider, while Treehouse still owns the task worktree.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection order, accepted backends, and metadata semantics.
The terminal-tab adapter, which runs each task in a Paseo terminal tab instead, is a separate backend owned by [`paseo-backend.md`](paseo-backend.md).

## Setup

Pick `paseo-agent` when Firstmate itself runs as an omp agent inside the Paseo app and its workers belong beside it in Paseo's chat.

Prerequisites:

- The Paseo app running with its daemon reachable (`paseo status`); the adapter never starts the daemon, because it is the desktop app's own.
- Paseo 0.17 or newer, the verified minimum.
- Paseo's omp provider (the paseo-omp plugin) enabled, because only the omp harness runs on this backend.
- The `paseo` CLI on `PATH`, or the CLI the running app names in `$PASEO_CLI`.
- `jq` and `treehouse`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

The adapter resolves the CLI through `fm_backend_paseo_bin` in `bin/backends/paseo.sh`: `PATH` first, then `$PASEO_CLI`, then the macOS bundle path.
Every spawn, control action, and teardown first checks the CLI, its version, and daemon reachability, and refuses with an actionable message when any is missing.

### Linux

The adapter's live checks ran on Linux x64 with the Paseo desktop AppImage; the verification record names what they cover.
The AppImage mounts its bundle at a path that changes on every launch, so its CLI is not at a fixed location.
The app exports that path as `$PASEO_CLI` into every process it starts, including the Firstmate primary, so no `PATH` setup is needed there.
A `paseo` wrapper on `PATH` takes precedence when present.

## Host-follow

A Firstmate primary that runs inside a Paseo agent spawns its workers as Paseo agents, and one that runs inside Orca spawns Orca workers.
[`configuration.md`](configuration.md#backend-selection-order) owns where this host step sits in the selection order, its notice when it overrides `config/backend`, and the secondmate exemption.
Neither host backend runs secondmates, which is why a `--secondmate` spawn skips host detection.

`fm_backend_detect_host` in `bin/fm-backend.sh` decides whether the session has a host.
A session counts as a Paseo host only when every structural fact agrees:

- `PASEO_AGENT_ID` is set to a well-formed agent id.
- The current process descends from the daemon process that `paseo status --json` reports.
- The daemon reads that agent back unarchived, with its working directory equal to the Firstmate home.

Paseo stamps its markers into every descendant process, so a marker alone never qualifies.
A tmux server or other daemonised child started from a Paseo session is reparented away from the daemon and fails the ancestry check.
A Paseo terminal tab is not a host, because it descends from the desktop app's terminal worker rather than the daemon, and everything launched from that tab inherits its markers.
A worker agent is not a host for its own spawns either, because it runs in its worktree rather than the home.
A nested tmux, Herdr, zellij, Rex, cmux, tern, or hc marker means that multiplexer is the innermost layer, so neither host claims the session.

An Orca chat counts as an Orca host through `ORCA_STRUCTURED_SESSION=1` with `ORCA_AGENT_SESSION_ID`, and an Orca terminal through `ORCA_TERMINAL_HANDLE`.
Orca deletes inherited `ORCA_*` names before it sets its own, so those markers name the session's own Orca surface.

An explicit `--backend` that differs from the detected host still wins, and the spawn prints a notice naming the host it overrode.
The `backend_detect=` values a host-selected task records are listed under [task metadata](configuration.md#task-metadata).

## Task shape and metadata

Each task has one Treehouse slot, one local Paseo workspace on that slot, and one Paseo agent in that workspace.

```text
backend=paseo-agent
window=fm-<id>
paseo_agent_id=<agent uuid>
paseo_agent_workspace_id=<wks_ id>
worktree=<absolute Treehouse worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`paseo_agent_id=` is the routing authority, and `paseo_agent_workspace_id=` names the task's workspace for relaunch and teardown.
Every agent carries the labels `fm-home=<hometag>`, `fm-task=<id>`, and `fm-kind=<kind>`, so two homes on one daemon never claim each other's workers.

### Why Treehouse rather than a Paseo-managed worktree

Archiving a Paseo-managed worktree workspace deletes its directory, uncommitted files included, so one sidebar click could discard unlanded work.
Archiving a local workspace leaves its directory untouched.
The slot therefore stays a Treehouse lease, which keeps Firstmate's landed-work test, freshen, and return machinery, and a local workspace attached to the project points at it.
The workspace shows under its project in Paseo's sidebar.

## Worker lifecycle

Spawn ensures a Paseo project exists for the repository, leases a Treehouse slot durably, freshens its base, and creates the local workspace on it.
The agent starts last, once every fact its first message and session environment carry exists, because Paseo creates an agent only together with its first prompt.
That first prompt is the encoded launch brief.
The agent starts at the provider's full-access mode.

The requested model and effort are checked against the provider's own catalog (`paseo provider models omp`) before any slot or workspace exists.
A model matches a catalog id exactly, or, unprefixed, the one id whose last path segment it is.
An effort must be one of that model's thinking options.
An omitted model or effort leaves that choice to the provider.

The session environment carries the exports a pane would receive: `GOTMPDIR`, `COMPACT_ADVISER_DISABLE`, `FM_TASK_INBOX`, `FM_OMP_HARNESS`, `OMP_SKIP_SETUP`, `FM_TASK_ID`, and, when configured, `LAVISH_AXI_HOST` and `TRACEPARENT`.
A spawn that fails after the agent starts archives that agent, archives the workspace, and returns the slot only when it holds no uncommitted work.
A start whose outcome Paseo never reported touches nothing it may be working in, and the warning names the cleanup commands.

## Steering

A metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its doorbell reaches Paseo.
The doorbell is one `paseo send --behavior steer`, which starts an idle agent's turn or joins a running one.
Paseo's `sent` answer reads as delivered, a typed Paseo error reads as `send-failed`, and a call that failed without Paseo's answer reads as unconfirmed, which `fm-send.sh` reports with exit 3.

## Control

[`agent-control.md`](agent-control.md) owns the control verbs and their proof obligations.
An interrupt is `paseo stop`, confirmed when the agent no longer reads running.
`exit` is Paseo's archive of the agent, proven by the agent reading back archived; the workspace and worktree stay for a relaunch.
`relaunch` proves the previous agent archived, reopens the recorded workspace on the same worktree only if something archived it, and starts one new agent there.
The task record then rebinds `paseo_agent_id=` to the new agent.
Escape and Ctrl-C are both an interrupt, and Ctrl-U has nothing to clear, because a Paseo agent has no composer.

## Busy state and permission requests

Paseo's own status table is the busy truth for this backend, reported as `paseo-agent-native` by `bin/fm-busy-lib.sh`.
`bin/backends/paseo-agent.sh`'s `fm_backend_paseo_agent_state_row` owns the mapping from `paseo inspect --json` to busy and agent state.
Native uncertainty counts as busy, so a doorbell waits for proven idle.
A pending permission or question reads idle rather than busy, so the wedge ladder never defers it as a running turn.
The watcher surfaces each new set of pending requests once as a `blocked` wake naming `paseo permit ls`.
Workers run at full access, so a pending request is surfaced rather than answered automatically.

## Teardown

Teardown keeps every shared Firstmate safety check.
After those checks it archives the agent and proves the archive, then archives the task workspace, and only then returns the Treehouse slot.
The workspace is archived only when it still points at the recorded worktree.
Both steps are idempotent, so a re-run after a failed return converges.
A failed archive stops teardown with the record intact and names the manual step.

## Paseo-hosted primary wake delivery

This section applies to an omp primary that Paseo itself runs (`omp --mode rpc-ui` or `--mode rpc` with `PASEO_AGENT_ID`), whatever backend its workers use.
`.omp/extensions/fm-primary-omp-watch.ts` owns the mechanism.

Paseo's chat folds every turn to its last assistant message, with turn boundaries taken from the turn id.
A watcher wake queued as a follow-up while the primary was mid-run joined that run, so the wake's reply became the turn's last message and the primary's answer folded into the turn's tool summary.
omp's next-turn queue does not help, because omp starts the next run before the current run reports its end, and the provider merges the two.

The wake therefore travels as a hidden custom message (`customType: firstmate-watcher-wake`, `display: false`) that triggers a turn.
The model reads the full wake text, while Paseo's chat shows no bubble for it.
It is sent only while the primary is idle, so it always starts a run of its own.
A wake raised mid-run is parked in the extension, counted as delivered but not consumed, and sent shortly after the run ends or by a one-second idle poll.
Wakes parked together go as one message holding each full wake in order.
A wake is consumed when a custom message carrying its exact text starts.
A synchronous refusal from omp falls back to the visible follow-up with the error appended.

Two races remain.
A wake sent at idle in the same instant a prompt starts can still join that run.
The turn-end guard's continuation, which runs only when supervision is off, continues the same run by design, so a reply before it can still fold.

### Idle runtime cleanup

Paseo's daemon closes an agent runtime that stays idle for 60 minutes unless its provider vetoes, and this cleanup is on by default.
The primary's watcher is a child of its omp process, so a collected primary loses its watcher until the next prompt starts omp again.
Firstmate never edits Paseo's configuration.
Turning the cleanup off is the operator's own setting: `agents.idleRuntimeCleanup` set to `false` in `~/.paseo/config.json`, or the equivalent Paseo app setting.

## Active limits

Paseo's omp provider refuses `GIT_CONFIG_*`, `PATH`, `HOME`, and related names in an agent's session environment, and it starts the harness itself with its own account.
Those facts set most limits below.

- Only the omp harness runs.
- Secondmate spawns are unsupported.
- A raw launch command is refused, because Paseo starts the agent itself.
- `config/launch-env-allowlist` is refused, because Paseo starts the agent with its provider's environment.
- A worker account pin is refused, because Paseo's provider owns the account.
- A ship for a `forge=external` project is refused, because its push guard reaches the worker only through `GIT_CONFIG_*` variables.
- The AI-trailer strip hooks are not delivered for the same reason, and the spawn prints a warning saying so.
- No semantic busy source reaches the worker, because the provider takes no `-e` extension; Paseo's status table stands in.
- The away-mode supervisor does not yet support a Paseo-hosted primary as its injection target ([`configuration.md`](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target)).
- A CLI-created agent gets no Paseo finish notification, so the worker's own status line remains the done wake.

## Regression entry points

[`verification/runtime-backends.md`](verification/runtime-backends.md#paseo-agents) records the live adapter, selection, and wake-delivery evidence, and names what is not yet verified.
The portable suites run against a stateful fake `paseo` CLI and a fake omp extension API, so they need neither Paseo nor omp:

```sh
tests/fm-backend-paseo-agent.test.sh
tests/fm-omp-harness.test.sh
```

The first covers the adapter's status table, catalog model selection, send verdicts, proven archive, interrupt claims, workspaces, projects, permission escalation, host-follow for Paseo and Orca, native busy state, and the spawn, control, and teardown arms.
The second covers hidden wake delivery for a Paseo-hosted primary.
