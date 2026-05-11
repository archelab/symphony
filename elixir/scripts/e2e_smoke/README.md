# Symphony orchestrator e2e smoke tests

End-to-end smoke tests for the Symphony orchestrator (Phase 1 / PR2) against a
real GitHub Projects v2 instance. Each case spins the orchestrator up against
the configured project, mutates real GitHub state, watches the orchestrator
logs, and asserts an expected behavior.

These are not unit tests — they exercise the live GitHub API, the
`mix run`-launched orchestrator, the Codex agent, and the workspace hooks. Run
them against a **dedicated smoke project**, not a production one.

## What it proves

| Case   | What it proves |
|--------|---------------|
| E2E-1  | A real Issue at Agent Ready is dispatched with identifier `<owner>/<repo>#N` (not `draft:*`); workspace gets created; prompt is rendered with `Kind: issue`. |
| E2E-2  | Flipping Status to a terminal value mid-run (Done) triggers a runtime reconcile stop (`:terminal_state` or `:terminal_or_closed`) and workspace cleanup. |
| E2E-3  | Flipping Status to an inactive value (Blocked) halts dispatch but preserves the workspace. |
| E2E-4  | Closing the underlying Issue mid-run is handled as terminal. Race-prone with `max_turns=1` — accepts PARTIAL. |
| E2E-5  | A CLOSED issue at Agent Ready is **never dispatched** (terminal-OR rule at the dispatch gate). |
| E2E-6  | A project item without a Status is **never dispatched**. |
| E2E-7  | A parent issue with an OPEN sub-issue child is gated. Closing the child unblocks the parent. **Currently failing** — see Notes below. |
| E2E-8  | The `github_graphql` Codex tool can be called by the agent to post an issue comment end-to-end. |
| E2E-9  | After a turn completes, flipping Status to Rework re-dispatches the item with the `## Continuation context` section rendered and `Prior session ended at <ts>`. |
| E2E-10 | Agent Workpad Protocol (SPEC §11.8) round-trips: with `agent.workpad.enabled: true` + a strong `codex.model`, the first dispatch posts a `<!-- symphony-workpad:v1 -->` comment via `addComment`; flipping Status → Done → Rework re-dispatches; the second prompt rolls out with `prior_sessions[0]` referencing the first session's `thread_id`. |

## Prerequisites

- `gh` CLI authenticated (`gh auth status`) with admin access to the smoke project + the repo's issues.
- `jq`, `curl`, `mise`, `bash >=4`.
- The Symphony Elixir app must be runnable via `mise exec -- mix run --no-halt` from `elixir/`.
- A dedicated GitHub Project v2 with:
  - A single-select **Status** field
  - Option names: `Agent Ready`, `In Progress`, `Rework`, `Blocked`, `Done` (some subset is fine — each case uses specific options)
- `GITHUB_TOKEN` available for the orchestrator (the harness re-uses `gh auth token`).

## Configuration

Environment variables (all optional with defaults):

| Var | Default | Meaning |
|-----|---------|---------|
| `SYMPHONY_E2E_PROJECT_OWNER` | `archelab` | GitHub organisation that owns the smoke Project |
| `SYMPHONY_E2E_PROJECT_NUMBER` | `1` | Project number |
| `SYMPHONY_E2E_REPO` | `symphony` | Repository where smoke issues are created |
| `SYMPHONY_E2E_TESTS` | `all` | Comma-separated case names (e.g. `e2e-5-terminal-or-at-dispatch,e2e-6-no-status`) |
| `SYMPHONY_E2E_REPORT` | `$E2E_LOG_DIR/REPORT.md` | Report file path |
| `E2E_LOG_DIR` | `/tmp/symphony-smoke-log` | Where run.log, orch.pid, REPORT.md land |
| `E2E_WORKSPACE_ROOT` | `/tmp/symphony-smoke-workspaces` | Workspace root (mirrored in `workflow.smoke.md`) |
| `SYMPHONY_E2E_E2E8_MODEL` | `gpt-5.4` | Stronger model for E2E-8 (which needs instruction-following) |
| `SYMPHONY_E2E_E2E8_REASON` | `low` | Reasoning effort for E2E-8 |
| `SYMPHONY_E2E_E2E10_MODEL` | `gpt-5.5` | Stronger model for E2E-10 (workpad round-trip needs instruction-following) |
| `SYMPHONY_E2E_E2E10_REASON` | `low` | Reasoning effort for E2E-10 |
| `SYMPHONY_E2E_E2E10_MAX_TURNS` | `2` | `agent.max_turns` override for E2E-10 |

## Running

```bash
cd elixir/scripts/e2e_smoke
./run.sh                          # all cases
SYMPHONY_E2E_TESTS=e2e-1-real-issue-dispatch ./run.sh

# Or via Make:
make -C elixir/scripts/e2e_smoke e2e-fast    # only the no-codex negative tests
make -C elixir/scripts/e2e_smoke e2e         # all
make -C elixir/scripts/e2e_smoke e2e-clean   # delete smoke items + workspaces
```

The driver:
1. Resolves Project node id + Status field id + option ids dynamically (don't hardcode!).
2. Swaps `elixir/WORKFLOW.md` to `workflow.smoke.md` (the original is preserved in `.e2e_orig` and restored on exit, including Ctrl-C).
3. Cleans any lingering `[smoke] *` items in the Project from prior runs.
4. Runs each requested case sequentially. Each case prints `PASS` / `FAIL: <reason>` / `SKIP: <reason>` / `PARTIAL: <reason>` on its last line.
5. Writes evidence + verdicts to `REPORT.md`.
6. On exit (or Ctrl-C): stops the orchestrator, deletes all `[smoke] *` items, and restores `WORKFLOW.md`.

## Reading a verdict

- **PASS**: assertion held end-to-end.
- **PARTIAL**: expected behavior was approximated but the exact log line / timing
  could not be observed. Common cause: `max_turns: 1` makes the worker exit
  faster than the polling reconcile tick can run, so the orchestrator handles
  the transition via the dispatch-gate filter instead. End behavior is correct.
- **SKIP**: an environmental dependency was missing (e.g. sub-issues API on
  E2E-7 is unavailable in the repo).
- **FAIL**: a real regression.

## Notes / known issues

- **E2E-7 (dependency gating)**: this case currently FAILs against
  `archelab/symphony` because the GitHub adapter
  (`lib/symphony_elixir/github/adapter.ex`) queries the `trackedIssues` field
  for blockers, but the newer GitHub sub-issues hierarchy populates the
  `subIssues` field instead. The two are different relations and a sub-issue
  link does not appear in `trackedIssues`. Fix path: extend the candidate
  query to also include `subIssues { nodes { number state } }` and merge into
  the same `blocked_by` list in `blocked_by_from_refresh/1`.

- **E2E-8**: gpt-5.4-mini at minimal reasoning ignores in-prompt instructions
  ~always. Use `SYMPHONY_E2E_E2E8_MODEL=gpt-5.4 SYMPHONY_E2E_E2E8_REASON=low`
  (or stronger) to get a real verdict.

## Known smoke-test artifacts

The following PARTIAL verdicts are expected artifacts of the smoke harness
running at `agent.max_turns: 1`. They are **not** orchestrator bugs and they
do not violate SPEC.md §13.1. End behavior matches the spec in all cases.

### E2E-2 / E2E-3 / E2E-4: `:DOWN`-before-reconcile race

With `max_turns: 1` and the smoke prompt body ("Print 'ack smoke' and end the
turn"), each codex worker finishes in 1–3 seconds — well under the configured
5-second poll interval. The sequence of orchestrator events is then:

1. Worker exits cleanly → `{:DOWN, ref, :process, _pid, :normal}` is delivered
   to the orchestrator GenServer.
2. The `:DOWN` handler
   (`lib/symphony_elixir/orchestrator.ex` ~lines 179–224) pops the running
   entry, logs `worker stop reason=:agent_exit_normal …` via the §13.1
   single-site `log_worker_stop/2`, and schedules a continuation retry.
3. On the next 5-second poll tick, `reconcile_running_issues/1` runs against
   an empty `state.running` for that item — so `classify_refresh/3` never sees
   the flipped Status / closed Issue. The reconcile-driven tokens
   `:inactive_state` (E2E-3) and `:terminal_or_closed` (E2E-2 / E2E-4) are
   therefore not emitted.
4. The candidate-fetch path (SPEC §8.2) filters the now-inactive / terminal
   item out on the next poll. The orchestrator emits
   `Issue no longer visible, removing claim issue_id=…` and drops the claim.
5. For closed Issues (E2E-4), the workspace is cleaned by the next startup
   terminal sweep (SPEC §8.6 / `before_remove` hook). For inactive Status
   (E2E-3), the workspace is intentionally preserved (inactive ≠ terminal).

### Why this is not a spec violation

§13.1 prescribes the **reason vocabulary** for worker stops; it does not
guarantee that any specific token will fire for every state transition. The
canonical reading of the spec across these sections is:

- §8.5 Part B (active run reconciliation) operates on workers still in
  `state.running`. If the worker has already exited naturally, there is no
  running entry to reconcile — and `:agent_exit_normal` is itself a documented
  stop reason (orchestrator.ex:423–429).
- §8.2 (candidate selection) is the spec-mandated filter for the next poll. A
  flipped-to-inactive or closed-mid-run item is correctly dropped here.
- §8.6 (startup terminal sweep) is the spec-mandated safety net for any
  terminal workspace that survived a clean exit.

Together, these three paths fully cover the transition. The `:DOWN` handler
intentionally acts as a **natural-exit accountant**, not a worker-stop in the
§8.5 Part B sense, and does not consult the tracker on the hot exit path
(adding a network call there would deadlock if GitHub were slow).

### Verifying the reconcile path under realistic settings

To observe `:inactive_state` / `:terminal_or_closed` from the reconcile path
directly (PASS, not PARTIAL):

1. Edit `workflow.smoke.md` locally: set `agent.max_turns: 5` and add a
   `sleep 25` instruction (or any in-prompt delay) so each turn lasts longer
   than `polling.interval_ms: 5000`.
2. Run `SYMPHONY_E2E_TESTS=e2e-3-inactive-status-reconcile,e2e-4-close-mid-run ./run.sh`.
3. Grep `log/symphony.log.*` for `worker stop reason=:inactive_state` and
   `worker stop reason=:terminal_or_closed` matching the test issue id.

Do **not** commit those edits to `workflow.smoke.md` — fast-mode is the
default for CI throughput. The reconcile vocabulary itself is pinned by unit
tests in `test/symphony_elixir/core_test.exs` under the
`"reconcile_running/3 (SPEC §8.5 Part B + §13.1 stop-reason vocab)"`
describe block, which exercise `classify_refresh/3` directly and do not
depend on worker timing.

## Files

```
elixir/scripts/e2e_smoke/
├── README.md                                ← this file
├── Makefile                                 ← convenience targets
├── run.sh                                   ← top-level driver
├── lib.sh                                   ← bash helpers
├── workflow.smoke.md                        ← WORKFLOW.md swapped in during runs
└── cases/
    ├── e2e-1-real-issue-dispatch.sh
    ├── e2e-2-terminal-status-reconcile.sh
    ├── e2e-3-inactive-status-reconcile.sh
    ├── e2e-4-close-mid-run.sh
    ├── e2e-5-terminal-or-at-dispatch.sh
    ├── e2e-6-no-status.sh
    ├── e2e-7-dependency-gating.sh
    ├── e2e-8-agent-comment-via-tool.sh
    ├── e2e-9-rework-continuation.sh
    └── e2e-10-workpad-roundtrip.sh
```
