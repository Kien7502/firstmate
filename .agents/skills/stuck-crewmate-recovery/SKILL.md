---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer, and whenever Claude reports a five-hour or session usage limit.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure, and parks a usage-limited worker for automatic resumption at the verified quota reset instead of relaunching it.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.
Use it as well whenever Claude reports a five-hour or session usage limit, for a direct report or for firstmate's own session.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Claude five-hour (session) usage limit

Check for this signature before treating any Claude-backed pane as wedged.
A pane that stopped on a Claude five-hour or session usage limit is a bounded external wait, not a wedge, so the interrupt-redirect-relaunch ladder below does not apply to it.
Relaunching cannot succeed while the window is exhausted; it only spends the crewmate's accumulated context on a restart that hits the same limit.

Record the wait with a `paused:` status rather than `blocked:`, then plan the resume once for the whole home:

```
bin/fm-quota-resume.sh schedule --task <id> [--task <id>]...
```

That reads current `quota-axi --json`, takes the Claude session window's own reset, and waits until that reset plus five minutes.
Run it again for each further worker that hits the same limit; it folds them into the one existing plan instead of arming a second wake.
Firstmate's own limited session needs no task argument: the plan still wakes this home when the window clears.
`bin/fm-quota-resume.sh --help` owns the exact subcommands, options, and exit statuses.

Two scheduling outcomes are not failures and need different handling.
When it reports that quota data is unavailable or malformed, nothing was scheduled, and the limit becomes an ordinary blocker to report rather than a reset time to guess.
When it reports the window has already reset, there is no wait left to schedule: resume the workers it names now, or run the resume below if it says a recorded plan is already due.

On the `check:` wake announcing that the resume is due, run:

```
bin/fm-quota-resume.sh resume
```

It refuses before the recorded time and before fresh quota data confirms the window actually rolled, steers only the workers the plan recorded, and then retires the plan, its footer entry, and the wake.
A refusal is a real result to report, never something to work around.
If it reports that some workers were not resumed, the plan narrows to exactly those, so run it again once their panes accept input or recover them through the live-endpoint escalation below.
Use `bin/fm-quota-resume.sh clear` only when the captain cancels the paused work outright.

These boundaries hold regardless of how much work is waiting:

- The session window's own reset is the only acceptable basis; the seven-day window's reset is never a substitute, and no resume happens before the recorded time.
- Never propose, arrange, or perform a plan upgrade as a way around the limit.
- Moving work to a different harness or model is an intake decision owned by `quota-array-dispatch`, not a recovery action for a task already under way; it needs the captain's word here.
- Report the wait to the captain in plain outcome language under `AGENTS.md` section 9: which work is waiting and when it picks up again, not the quota tool, the wake, or the plan file.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Escape`.
4. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.
