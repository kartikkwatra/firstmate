---
name: design-worker
description: Load before dispatching a design worker, and whenever a design worker reports waiting on the captain or a settled topic.
user-invocable: false
metadata:
  internal: true
---

# Design workers

A design worker is the one worker that talks to the captain directly.
It works product decisions through with him in Plannotator Inbox questions and Lavish walk-throughs, and records each decision word for word as a numbered decision record in the project's own `docs/decisions/`.
A changed decision gets a new record that supersedes the old one, and only `Accepted` records are current; the brief's design contract owns the procedure, and `assets/` holds the record template and the folder README it copies in.
Scouts investigate and ships build; neither ever uses the Inbox.

## Dispatch

- Dispatch one when the captain's own calls are the deliverable, not an investigation (scout) or an implementation (ship).
- A design worker is a ship task: resolve its delivery mode, `yolo` posture, and branch prefix at intake exactly as for any ship, because its branch carries the decision records into the project.
- Scaffold with `bin/fm-brief.sh <id> <repo> --mode <mode> --design` and spawn with the same `--design`; the two scripts' headers own the design contract, the recorded role, and the refusals when brief and spawn disagree.
- Choose a harness on which this machine's Plannotator config turns the Inbox tool on, because the captain's Inbox reply is what wakes the worker.
- When this home publishes Lavish pages to the captain's phone over an https address, name it in the Firstmate spec so the worker can announce that link rather than a loopback one.

## Supervision

- `paused: waiting on captain: <topic>` is a declared wait on the captain, not a blocker.
  The question is already in his Inbox: never relay, re-ask, or summarize it, and in a captain-facing reply say only that the design worker is waiting on him and on which topic.
- `resolved: settled: <topic>` needs no action; the decision lives in the project's decision records on the worker's branch.
- Never copy decision content into the backlog, learnings, captain records, or any other Firstmate record; Firstmate keeps only workflow state.
- A `needs-decision` from a design worker is a call outside the captain's design questions, such as a destructive action or a delivery choice, and is handled like any worker's.
- If a scout or ship asks the captain through the Inbox anyway, steer it back to its status file; `bin/fm-spawn.sh` withholds the Inbox tool from them where the runtime allows, and their role contract forbids it everywhere.

## Completion

A design worker's `done:` is a ready branch like any ship's: load `ship-landing` and land it through the task's delivery path, which makes the project's decision records current.
