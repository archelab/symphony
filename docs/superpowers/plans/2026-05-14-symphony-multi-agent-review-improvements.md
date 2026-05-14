# Symphony Multi-Agent Review — Improvement Plan

**Goal:** Act on the findings of a six-agent review of the Symphony Elixir orchestrator. Close the highest-risk runtime liveness gap, finish the architecture deepening that was started but stopped halfway, and make the test-coverage gate honest.

**Architecture:** Behavior-preserving where possible. The one functional change is moving graceful termination off the orchestrator's GenServer loop. Everything else is extraction of pure logic out of oversized modules, plus test and tooling work — no new tracker behavior, no new GitHub mutations, no new workpad semantics, no new smoke cases.

**Tech Stack:** Elixir 1.19 / OTP 28, Mix, ExUnit, Dialyzer, Credo, Phoenix LiveView, Codex app-server JSON-RPC, GitHub Projects v2 GraphQL.

---

## Methodology

Six Opus subagents reviewed `elixir/lib` + `elixir/test` at `main` (HEAD `094a4fc`), each with a different lens:

| Agent | Lens |
|---|---|
| `brooks-review` | PR-style code review, severity-grouped |
| `brooks-debt` | Tech-debt classification + roadmap |
| `brooks-test` | Test-suite quality, the 100%-coverage question |
| `brooks-audit` | Module dependency / layering audit |
| `improve-codebase-architecture` | Shallow-module deepening, testability |
| `requesting-code-review` | Code-vs-spec + hard-earned-rule compliance |

**Convergence is the prioritization signal.** Where N independent agents flagged the same thing, that count is shown as `[N agents]`. All six confirmed the codebase is in good shape overall: three gates green (`mix lint` exit 0, `mix test_strict` 554 tests / 100.00% / 0 failures), clean layering with no circular deps, zero Linear references, all 14 checkable hard-earned rules verified holding. The findings cluster around five files: `orchestrator.ex`, `app_server.ex`, `telemetry.ex`, `status_dashboard.ex`, `tracker.ex`.

This plan is the follow-on to `2026-05-14-symphony-runtime-architecture-deepening.md`: that pass extracted `DispatchPolicy` / `Reconciliation` / `SessionHistory` / `Projection` / `Notifications` / `Telemetry`, but the review found the extraction stopped before the imperative core of the Orchestrator, and surfaced one runtime-liveness bug the deepening did not touch.

## Success criteria

- The orchestrator GenServer never blocks on a non-GenServer `receive` during a poll tick.
- `orchestrator.ex` is under ~700 LOC and holds only `handle_info` / `handle_call` wiring + delegation.
- No production module exports `*_for_test` functions.
- `Tracker.fetch_issue_states_by_ids/1` has a single return shape; the `@callback` type is no longer a union.
- `mix.exs` `ignore_modules` is split into a `# plumbing` section and a `# TODO+issue` section, and is smaller than today (Orchestrator + AgentRunner removed at minimum).
- `mix lint`, `mix test_strict`, and `GITHUB_TOKEN=$(gh auth token) mise exec -- mix test --only live_github` pass before each handoff.

---

## Priority 1 — Critical

### P1.1 — Graceful termination blocks the whole orchestrator for up to N×30s per poll tick `[2 agents]`

**Symptom.** `orchestrator.ex:566-587` (`request_graceful_worker_stop/3`) does a bare blocking `receive ... after budget_ms` with `budget_ms` defaulting to 30000. It is called synchronously from `terminate_running_issue/4`, which runs inside `handle_info(:run_poll_cycle, …)` via `apply_reconcile_decision/4` and `restart_stalled_issue/5`. If one poll tick must terminate K workers — the exact stall-storm the feature exists for — the GenServer is frozen for up to K×30s. During that window `:snapshot` calls time out (dashboard shows errors), `:codex_worker_update` messages queue unbounded, `:request_refresh` is unresponsive.

**Why it matters.** This is the only finding that can wedge the entire system in normal operation. §13.1 mandates the graceful wrap-up, but executing it in-line on the GenServer process trades whole-orchestrator liveness for one worker's clean exit.

**How.** Move the wrap-up wait off the GenServer process. Send the `{:symphony_wrap_up, …}` signal, register a per-issue `graceful_deadline` timer via `Process.send_after`, and let the existing `{:DOWN, …}` handler complete the termination + §13.1 log + `complete_issue/4` when the worker exits. On the timer message, force-kill and log with the original reason + `graceful=false`. This converts a 30s synchronous freeze into an async state transition and removes the only place the loop blocks on a non-GenServer message. Preserve the §13.1 contract: clean wrap-up exits still log `:agent_exit_normal final_intent=<original_reason>`; timeouts keep the original reason.

**Verify.** New test: a poll tick that terminates 3 workers must return promptly and still produce 3 §13.1 log lines. `mix test_strict` + `live_github` green.

---

## Priority 2 — High: the spine refactor

P2.1–P2.5 are interlocked. Doing P2.1 well, after P2.2, largely delivers P2.3, P2.4 and most of P2.5. Sequence: P2.2 → P2.5 → P2.1 → (P2.3, P2.4 fall out).

### P2.1 — `Orchestrator` is a 1,575-line god module `[6 agents — unanimous]`

**Symptom.** Most-churned file in the repo (13 commits). The pure-decision extraction started but stopped: the imperative retry subsystem (`schedule_issue_retry`, `pop_retry_attempt_state`, `handle_retry_issue*`, `retry_delay`, `pick_retry_*` — ~200 LOC), dispatch+spawn+revalidate (`dispatch_issue` → `do_dispatch_issue` → `spawn_issue_on_worker_host` → `revalidate_issue_for_dispatch` — ~139 LOC), termination/§13.1 logging, and codex-update integration all still live in `handle_info` clauses. None can be unit-tested without `:sys.replace_state`.

**How.** Continue the established pattern (pure module + thin process shell):
- Extract `Orchestrator.RetryQueue` — pure functions over `{retry_queue, claimed}`.
- Extract `Orchestrator.Dispatcher` — spawn + revalidate; takes `state` + `issue`, returns new `state` + side-effect descriptors.
- Extract `Orchestrator.Cycle` (or `Transitions`) — `State.t() × event → State.t() × [effect]`, where `effect` is a data description (`{:spawn_agent, …}`, `{:schedule_retry, …}`, `{:log_stop, …}`, `{:cleanup_workspace, …}`). The GenServer becomes: receive message → `Cycle.apply/2` → interpret the effect list.
- Promote `running_entry` (28-field bare map, ~85 untyped `Map.*` mutations) to an `Orchestrator.RunningEntry` struct with a constructor, so dialyzer catches field drift.

Target: `orchestrator.ex` under ~700 LOC, only wiring + delegation. Each extracted module is unit-testable and comes off `ignore_modules`.

**Verify.** Extracted modules at 100% coverage; `Orchestrator` removed from `ignore_modules`; `mix xref graph --format cycles` clean; behavior unchanged (existing tests pass per task).

### P2.2 — `Config.settings!()` is an ambient global `[3 agents]`

**Symptom.** Called 19× in `orchestrator.ex`, 8× in `app_server.ex`, 5× in `status_dashboard.ex`. Two problems: (a) **correctness** — a single poll tick can observe different config snapshots at different points; if `WORKFLOW.md` hot-reloads mid-tick, dispatch / retry / termination disagree about what config is in effect; (b) **cost** — every call re-runs the Ecto `Schema.parse` changeset behind a serialized `GenServer.call(WorkflowStore, :current)`.

**How.** Snapshot `Config.settings!()` once at the top of each `handle_info(:run_poll_cycle, …)` and `handle_info({:DOWN, …})`, and thread the struct through (the pure modules `DispatchPolicy` / `Reconciliation` already take it as a parameter — extend that discipline to the rest). Cache the parsed `Schema.t()` in `WorkflowStore` state as `{workflow, parsed_settings}`, invalidated on reload, so `Config.settings!/0` is a cheap read. Drop `max_concurrent_agents` and `poll_interval_ms` from `State` (they cache config values already cheap to read) and delete `refresh_runtime_config/1`.

**Why this is the prerequisite.** As long as pure helpers call `Config.settings!()` mid-computation they are not actually pure — no clean extraction (P2.1) is possible until config is an explicit input. Do this first.

**Verify.** `rg -c 'Config.settings!' lib/symphony_elixir/orchestrator.ex` drops to ≤2; `mix test_strict` green.

### P2.3 — `*_for_test` backdoors leak through the public API `[3 agents]`

**Symptom.** 12 `*_for_test` functions exported from `Orchestrator` (`orchestrator.ex:461-509`) and `StatusDashboard`. The `Orchestrator` ones merely delegate to `DispatchPolicy` / `Reconciliation`, which are *already public*.

**How.** Delete the `Orchestrator.*_for_test` functions; point those tests at `DispatchPolicy` / `Reconciliation` / `SessionHistory` directly. For `StatusDashboard`, the functions become legitimately public once extracted into `StatusDashboard.Render` (see P3.3). Largely falls out of P2.1.

**Verify.** `rg '_for_test' lib/` returns zero hits.

### P2.4 — Coverage illusion: ~half the codebase is excluded from the 100% gate `[5 agents]`

**Symptom.** `mix.exs` `ignore_modules` excludes 21 of 53 modules (~6,350 LOC / 49%), including the runtime spine: `Orchestrator`, `AgentRunner`, `Codex.AppServer`, `StatusDashboard`, `Workspace`, all of `SymphonyElixirWeb.*`. A line added to `Orchestrator.handle_info` ships with zero tests and the gate stays green; the list has only grown.

**How.**
- Split `ignore_modules` into two labelled sections: `# untestable plumbing` (Endpoint, Router, ErrorHTML, Layouts — legitimate) and `# TODO: needs real tests` with a one-line issue/plan reference per entry.
- Emit a second, non-gated coverage report run *without* `ignore_modules`, printed for visibility so the real number (~55–70%) is always visible next to the headline 100%.
- Add a CI check that forbids net-additions to `ignore_modules` (count check).
- As P2.1 and P2.5 land, remove `Orchestrator`, `AgentRunner`, `StatusDashboard`, and the extracted Codex modules from the list.

**Verify.** `ignore_modules` is smaller than today and labelled; CI count-check present.

### P2.5 — `AgentRunner` (the dispatch executor) has no dedicated test file `[3 agents]`

**Symptom.** ~6 happy-path tests inside `core_test.exs`. Missing: codex crash mid-turn, workspace-creation failure, hook (`after_create` / `before_run`) failure, graceful-budget timeout, the `continue_with_issue?/2` dual-shape branch. It is in `ignore_modules` so the gaps are invisible. 289 LOC, zero dedicated tests — it ships on faith.

**How.** Extract `AgentRunner.TurnPlan` — a pure decision function `(issue, turn_number, max_turns, refresh_result) → :run_turn | {:continue, refreshed_issue} | :done | {:wrap_up, signal}`. Move the `send`-based progress reporting behind an injected `reporter` function (same pattern `AppServer` already uses for `on_message`). Then write `agent_runner_test.exs` covering the failure paths above, and remove `AgentRunner` from `ignore_modules`.

**Verify.** `agent_runner_test.exs` exists with failure-path coverage; `AgentRunner` off `ignore_modules` at 100%.

---

## Priority 3 — Medium

### P3.1 — `seconds_running` is double-accounted `[1 agent]`

`orchestrator.ex` feeds `codex_totals.seconds_running` from both per-update telemetry deltas (`apply_token_delta/2`) *and* a one-shot wall-clock dump at termination (`record_session_completion_totals/2`). The dashboard's "total seconds running" is a meaningless mixed number. **How:** pick one source — accumulate only from telemetry deltas, or compute on demand in `handle_call(:snapshot, …)` by summing `running_seconds/2` over live entries plus stored per-session durations. Drop the `record_session_completion_totals` mutation of the aggregate.

### P3.2 — Hand-rolled GraphQL parser gates a security boundary `[1 agent]`

`github_graphql_tool.ex:96-230` is a ~140-line charlist-walking partial GraphQL parser (`isolate_mutation_body`, `walk_fields`, `skip_parens`, …) deciding which mutations pass the allowlist. A parsing edge case — aliased fields (`safe: dangerousMutation(...)`), fragment-spread mutations, `mutation @skip(...)`, field names split across newlines — is an allowlist *bypass*. **How:** replace with a real GraphQL parser (`Absinthe.Lexer` / `Absinthe.Phase.Parse` gives an unambiguous AST). If pulling Absinthe is too heavy, at minimum add adversarial tests for aliases, fragment spreads, and directives before trusting the current code.

### P3.3 — `Codex.Telemetry` (1,144 LOC), `Codex.AppServer` (1,192 LOC), `StatusDashboard` (1,130 LOC) are oversized mixed-concern modules `[3 agents combined]`

- **Telemetry:** mixes metric-extraction with a ~700-line `humanize_*` rendering tree. Extract `Codex.MessageHumanizer` (pure, table-testable); keep `Codex.Telemetry` as the `extract_*` metric functions.
- **AppServer:** mixes JSON-line transport, the turn state machine, and the security-relevant approval / `requestUserInput` auto-answer logic (6 `maybe_handle_approval_request` clauses + ~12 `tool_request_user_input_*` helpers). Extract `Codex.ApprovalPolicy` (or `Codex.Protocol`) — pure `(payload, policy) → decision`. `AppServer` keeps only port I/O + the `receive` loop.
- **StatusDashboard:** ~900 lines of pure formatting trapped in a GenServer; reaches sideways into `HttpServer.bound_port`; its only test signal is 10 byte-exact ANSI snapshot fixtures that churn on cosmetic changes. Extract `Observability.TerminalView` + a shared `Observability.Format` module (duration / number / `started_at→seconds` formatting — currently triplicated across `StatusDashboard`, `DashboardLive`, `Projection`). Break the `HttpServer` dependency by publishing the bound port via `Notifications` / app-env. Keep 1–2 snapshots as characterization tests; move substantive assertions onto structured render data.

### P3.4 — `Tracker.fetch_issue_states_by_ids/1` returns two different shapes `[6 agents — unanimous]`

Memory returns `[%Github.Issue{}]`; Github returns `[%{id, identifier, state, blocked_by}]` refresh-maps. The union `@callback` return type means **dialyzer cannot catch a consumer that handles only one shape** — directly undercutting hard-earned rule #4. Every consumer (`AgentRunner.continue_with_issue?/2`, `Reconciliation.classify_refresh/3`, the orchestrator reconcile path) carries permanent dual-shape handling. **How:** make `Tracker.Memory.fetch_issue_states_by_ids/1` project its fixture `%Issue{}` structs into `refresh_result()` maps at the boundary (~10-line `Enum.map`; the fixture *input* can stay struct-shaped). Tighten the `@callback` type to `{:ok, [refresh_result()]}`, delete the dual-shape clauses in `AgentRunner` and `Reconciliation`. Add a contract test that runs the same assertions against both adapters. Hard-earned rule #6 warns the cascade is wide — re-measure; the agents' assessment is that the cascade is mostly the missing test coverage, not production code.

### P3.5 — `/api/v1/<id>` returns 404 for a slow or down orchestrator `[1 agent]`

`presenter.ex:66-74` collapses `Orchestrator.snapshot/2` returning `:timeout` / `:unavailable` into `{:error, :issue_not_found}` → HTTP 404. An operator hitting the endpoint while the orchestrator is slow is told the issue does not exist — wrong diagnosis. The sibling `state_payload/2` already distinguishes these correctly. **How:** match `:timeout` / `:unavailable` explicitly in `issue_payload/3`, return distinct error atoms, map to 503/504 in the controller.

---

## Priority 4 — Low / cleanup

- **`interrupt_turn` race** (`agent_runner.ex` + `app_server.ex`): the wrap-up turn issues a fresh `turn/run` on the same port without awaiting `turn/cancelled`; late events from the cancelled turn can interleave. Drain until `turn/cancelled` (or short timeout) before reusing the port.
- **Monolithic test files** `[2 agents]`: `core_test.exs` (2,870 LOC) and `orchestrator_status_test.exs` (1,966 LOC) are grab-bags with ~250 lines of duplicated git-repo / fake-codex bootstrap. Split by subject as the modules they cover get extracted; move `setup_template_repo!/1` and `write_fake_codex!/2` into `test_support.exs`. Collapse the redundant `reconcile_running/4` integration cases now that `reconciliation_test.exs` covers classification purely.
- **`Process.sleep` × 35 + sync-only suite** `[1 agent]`: latent CI-flake class. Replace `Process.sleep` + `:sys.get_state` polling with `assert_receive` or `:sys.get_state`-as-barrier. Move the `:github_client` seam from `Application` env to process-scoped state (or the already-installed-but-unused `Mox`) so `adapter_test.exs` and the orchestrator tests can run `async: true`.
- **Unused `mox` dependency** `[1 agent]`: declared in `mix.exs`, zero usages. Delete it, or adopt it for the `:github_client` injection seam.
- **`retry_attempt` accounting** (`orchestrator.ex:1159-1164`): continuation-dispatched workers reset `retry_attempt` to 0, so crash-retry backoff and the §11.8.5 session `attempt` field understate real work done. Track a monotonic dispatch counter distinct from `retry_attempt`, or seed it from prior sessions.
- **`fetch_issues_by_states/1` naming** (`adapter.ex:135-163`): non-terminal-aware semantics are a footgun for any future caller passing active states. Rename to signal it (e.g. `fetch_issues_by_status_field_name/1`).
- **Duplicated draft-identifier slicing** `[1 agent]`: `String.slice(id, -8, 8)` lives independently in `Github.Normalize.identifier_for/4` and `Github.Adapter.identifier_from_refresh/1`; hard-earned rule #7 says they must stay aligned. Extract one `Github.Normalize.draft_identifier/1` called by both.
- **`Reconciliation.any_blockers_reopened?/2`** takes a single-element list then `Enum.find`s the element back out — vestige of an older multi-result API. Pass the map directly.

---

## Sequencing

1. **P1.1** — async graceful termination. Standalone, stops the system-wedge, ship first.
2. **P2.2** — config snapshot + `WorkflowStore` cache. Lowest-risk, unblocks the spine refactor.
3. **P3.4 + draft-identifier dedup** — both touch `Github.Normalize`; kills a dialyzer blind spot; contained.
4. **P2.1** — the spine refactor (`RetryQueue`, `Dispatcher`, `Cycle`, `RunningEntry` struct). Incremental, one sub-module extraction per PR. **P2.3** (`*_for_test` removal) and most of **P2.4** (`ignore_modules` shrink) fall out of this. Split the monolithic test files as the modules they cover get extracted.
5. **P2.5** — `AgentRunner.TurnPlan` + failure-path tests.
6. **P3.2, P3.3** — security-boundary parser; Codex / StatusDashboard module splits. Independent; schedule after the spine work.
7. **P3.1, P3.5, P4.\*** — fold into whichever PR touches the relevant file.

## Out of scope

No new tracker behavior, no new GitHub mutations, no new workpad semantics, no new dashboard fields, no new e2e smoke cases. `WORKFLOW.md`, the mutation allowlist, the workpad protocol, and the smoke harness are unchanged. This plan is maintenance and hardening, not feature work.
