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

- **E2E-2/E2E-4 race**: with `max_turns: 1` the worker frequently exits before
  the next 5-second reconcile tick, so the runtime `:terminal_state` /
  `:terminal_or_closed` reason is sometimes not observed. The orchestrator
  still removes the claim ("Issue no longer visible") and the next start-up
  terminal sweep cleans the workspace. Bump `max_turns: 5` or add a workspace
  delay hook for a deterministic observation of the runtime path.

- **E2E-8**: gpt-5.4-mini at minimal reasoning ignores in-prompt instructions
  ~always. Use `SYMPHONY_E2E_E2E8_MODEL=gpt-5.4 SYMPHONY_E2E_E2E8_REASON=low`
  (or stronger) to get a real verdict.

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
    └── e2e-9-rework-continuation.sh
```
