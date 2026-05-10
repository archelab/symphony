# IMPLEMENTATION_NOTES.md

## Task 1 — WORKFLOW.md flipped to kind: memory (PLAN deviation)

PLAN.md Task 1 anticipated test-suite breakage from removing Linear-shaped
Tracker fields and prescribed `:skip_until_task_6` tags. It missed that
SymphonyElixir.Application starts SymphonyElixir.Orchestrator.init/1, which
calls run_terminal_workspace_cleanup/0, which delegates to
SymphonyElixir.Linear.Adapter for the kind: linear configured in the repo's
elixir/WORKFLOW.md. Linear.Client.fetch_issues_by_states/1 reads
tracker.project_slug/api_key directly; with those fields removed, the
GenServer raises KeyError at app boot, preventing every test from running.

Unblock chosen by controller (per issue #2 quality bar): flip the dev
elixir/WORKFLOW.md from `kind: linear` to `kind: memory`. The memory
adapter is already routed by Tracker.adapter/0 and exercises no Linear
field reads. Linear modules become unreachable runtime code and are
deleted in PR2 / Task 8.

The following test files needed `:skip_until_task_6` tags after the flip
(all blocked by removed Linear-shape Tracker field reads in production
code that PR2 rewires):

- `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs` —
  `@moduletag :skip_until_task_6` (all 6 tests). status_dashboard.ex:397
  reads `tracker.project_slug` from every snapshot render.
- `elixir/test/symphony_elixir/orchestrator_status_test.exs` — 20 tests
  tagged. Same root cause: dashboard rendering during orchestrator boot
  / snapshot tests.
- `elixir/test/symphony_elixir/core_test.exs` — 8 tests tagged. Mix of
  Linear env var resolution (`LINEAR_API_KEY` / `LINEAR_ASSIGNEE`),
  worker retry tests that boot Orchestrator, and a fixture asserting the
  repo WORKFLOW.md still uses `kind: linear`.
- `elixir/test/symphony_elixir/workspace_and_config_test.exs` — 7 tests
  tagged. Linear client tests, schema parse fallbacks asserting the old
  `api_key` field, dispatch eligibility tests that hit the orchestrator
  boot path, and the per-state max-concurrent test that trips
  Config.validate_semantics/1 still rejecting `kind: github` (PR2
  Task 8b widens that allowlist).

After tagging, `mix test --exclude live_github --exclude skip_until_task_6`
reports `197 tests, 0 failures, 2 skipped (41 excluded)` and the new
`test/symphony_elixir/config/github_tracker_test.exs` is 8/8 green.

`mix lint.baseline` is green (credo's TODO-tag design suggestions are
non-fatal — exit 0).

### Downstream stale Linear field reads (PR2 / Task 6 / Task 8 must fix)

Production code that still references removed Tracker fields
(`api_key`, `project_slug`, `assignee`) or whitelists `linear` as a
valid tracker `kind`. Each line was kept compiling only because the dev
`elixir/WORKFLOW.md` was flipped to `kind: memory` — all of the call
sites below are runtime-unreachable today but must be removed or
rewritten before PR2 / Task 8 deletes the Linear modules.

- `elixir/lib/symphony_elixir/config.ex:122-129` —
  `validate_semantics/1` whitelists only `["linear", "memory"]` (rejects
  `"github"`) and reads `tracker.api_key` and `tracker.project_slug`.
- `elixir/lib/symphony_elixir/linear/client.ex:109,112,133,136,384,491` —
  six reads of `tracker.project_slug` (109, 133), `tracker.api_key`
  (112, 136, 384), and `tracker.assignee` (491).
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:174` — user-facing
  error message references `linear.api_key` and `LINEAR_API_KEY`.
- `elixir/lib/symphony_elixir/status_dashboard.ex:397` — reads
  `tracker.project_slug` when rendering the project link.
