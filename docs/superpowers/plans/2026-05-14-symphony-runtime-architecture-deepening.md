# Symphony Runtime Architecture Deepening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce Symphony's highest-risk architecture hotspots by extracting orchestration decisions, Codex telemetry normalization, and observability projection into deeper Modules without changing runtime behavior.

**Architecture:** Keep `SymphonyElixir.Orchestrator` as the GenServer runtime Adapter that owns process state and mailbox ordering. Move pure decisions behind small Interfaces so retry, reconciliation, dispatch, session history, and presentation logic can be tested without `:sys.replace_state/2`, direct process messages, or `_for_test` seams.

**Tech Stack:** Elixir 1.19 / OTP 28, Mix, ExUnit, Dialyzer, Credo, Phoenix LiveView, Codex app-server JSON-RPC, GitHub Projects v2 GraphQL.

---

## Scope

This is one PR-scoped architecture-deepening pass. It intentionally does not introduce new tracker behavior, new dashboard fields, new GitHub mutations, or new smoke cases. The work is behavior-preserving: existing tests should pass after each task, and the final dependency graph should have fewer cycles.

Success criteria:

- `SymphonyElixir.Orchestrator` stops owning pure dispatch/reconcile/session-history/token-accounting decisions directly.
- Terminal and web observability no longer need to share terminal formatting helpers.
- No runtime behavior changes in `WORKFLOW.md`, tracker writes, workpad protocol, GitHub mutation allowlist, or e2e smoke harness.
- `mix xref graph --format cycles` has no cycle involving `StatusDashboard -> Orchestrator -> StatusDashboard`.
- `mix lint`, `mix test_strict`, and `GITHUB_TOKEN=$(gh auth token) mise exec -- mix test --only live_github` pass before handoff.

## File Structure

Create these Modules:

- `elixir/lib/symphony_elixir/observability/notifications.ex`
  - Owns runtime observability update notifications for both terminal and Phoenix consumers.
- `elixir/lib/symphony_elixir/codex/telemetry.ex`
  - Owns normalized Codex protocol event interpretation: token usage, rate-limit snapshots, event labels, and human-readable message summaries.
- `elixir/lib/symphony_elixir/orchestrator/session_history.ex`
  - Owns building and pruning session-history records from running entries.
- `elixir/lib/symphony_elixir/orchestrator/dispatch_policy.ex`
  - Owns sorting, status eligibility, dependency gating, per-state concurrency gating, and worker-host selection decisions. It does not batch-dispatch issues.
- `elixir/lib/symphony_elixir/orchestrator/reconciliation.ex`
  - Owns refresh classification for running workers and stale dependency snapshots.
- `elixir/lib/symphony_elixir/observability/projection.ex`
  - Owns API/LiveView read-model projection from orchestrator snapshots and completed sessions.

Modify these Modules:

- `elixir/lib/symphony_elixir/orchestrator.ex`
  - Delegate pure decisions to the new orchestration Modules.
  - Keep GenServer callbacks, process monitoring, task spawning, logging side effects, and state mutation sequencing here.
- `elixir/lib/symphony_elixir/status_dashboard.ex`
  - Keep terminal rendering and GenServer refresh throttling here.
  - Use `Codex.Telemetry.humanize_message/1` for Codex message summaries.
  - Stop owning message-humanization helpers that web projection also needs.
- `elixir/lib/symphony_elixir_web/presenter.ex`
  - Become a thin Adapter over `SymphonyElixir.Observability.Projection`.
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
  - Delete tests that only exercise pure token/event/dispatch/session decisions after moving them to focused test files.
- `elixir/test/symphony_elixir/core_test.exs`
  - Delete or shrink tests that call `_for_test` orchestration seams once the new Modules have direct tests.
- `elixir/mix.exs`
  - Remove newly extracted pure Modules from any coverage ignore need. Do not add new ignores.

Create these tests:

- `elixir/test/symphony_elixir/codex/telemetry_test.exs`
- `elixir/test/symphony_elixir/orchestrator/session_history_test.exs`
- `elixir/test/symphony_elixir/orchestrator/dispatch_policy_test.exs`
- `elixir/test/symphony_elixir/orchestrator/reconciliation_test.exs`
- `elixir/test/symphony_elixir/observability/projection_test.exs`

## Task 1: Codex Telemetry Module

**Files:**
- Create: `elixir/lib/symphony_elixir/codex/telemetry.ex`
- Create: `elixir/test/symphony_elixir/codex/telemetry_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] **Step 1: Write focused telemetry tests**

Create `elixir/test/symphony_elixir/codex/telemetry_test.exs`:

```elixir
defmodule SymphonyElixir.Codex.TelemetryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Telemetry

  test "extract_token_delta prefers absolute thread totals and computes deltas from prior reported values" do
    running_entry = %{
      codex_last_reported_input_tokens: 10,
      codex_last_reported_output_tokens: 4,
      codex_last_reported_total_tokens: 14
    }

    update = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{
              "inputTokens" => 15,
              "outputTokens" => 6,
              "totalTokens" => 21
            }
          }
        }
      }
    }

    assert %{
             input_tokens: 5,
             output_tokens: 2,
             total_tokens: 7,
             reported_input_tokens: 15,
             reported_output_tokens: 6,
             reported_total_tokens: 21
           } = Telemetry.extract_token_delta(running_entry, update)
  end

  test "extract_rate_limits finds nested rate limit payloads" do
    update = %{
      payload: %{
        "params" => %{
          "result" => %{
            "rateLimit" => %{
              "remaining" => 42,
              "resetAt" => "2026-05-14T12:00:00Z"
            }
          }
        }
      }
    }

    assert %{"remaining" => 42, "resetAt" => "2026-05-14T12:00:00Z"} =
             Telemetry.extract_rate_limits(update)
  end

  test "humanize_message returns stable labels for known Codex notifications" do
    assert Telemetry.humanize_message(%{
             event: :notification,
             message: %{"method" => "codex/event/task_started"}
           }) == "task started"

    assert Telemetry.humanize_message(%{
             event: :turn_completed,
             message: %{"method" => "turn/completed"}
           }) == "turn completed"
  end
end
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/codex/telemetry_test.exs
```

Expected: failure because `SymphonyElixir.Codex.Telemetry` does not exist.

- [ ] **Step 3: Create the telemetry Module**

Create `elixir/lib/symphony_elixir/codex/telemetry.ex` with this Interface:

```elixir
defmodule SymphonyElixir.Codex.Telemetry do
  @moduledoc """
  Normalizes Codex app-server telemetry events for orchestration and observability.
  """

  @type token_delta :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          reported_input_tokens: non_neg_integer(),
          reported_output_tokens: non_neg_integer(),
          reported_total_tokens: non_neg_integer()
        }

  @spec extract_token_delta(map(), map()) :: token_delta()
  def extract_token_delta(running_entry, update) when is_map(running_entry) and is_map(update) do
    case extract_token_usage(update) do
      nil ->
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          reported_input_tokens: Map.get(running_entry, :codex_last_reported_input_tokens, 0),
          reported_output_tokens: Map.get(running_entry, :codex_last_reported_output_tokens, 0),
          reported_total_tokens: Map.get(running_entry, :codex_last_reported_total_tokens, 0)
        }

      usage ->
        %{
          input_tokens: compute_delta(running_entry, :input, usage, :codex_last_reported_input_tokens),
          output_tokens: compute_delta(running_entry, :output, usage, :codex_last_reported_output_tokens),
          total_tokens: compute_delta(running_entry, :total, usage, :codex_last_reported_total_tokens),
          reported_input_tokens: get_token_usage(usage, :input) || Map.get(running_entry, :codex_last_reported_input_tokens, 0),
          reported_output_tokens: get_token_usage(usage, :output) || Map.get(running_entry, :codex_last_reported_output_tokens, 0),
          reported_total_tokens: get_token_usage(usage, :total) || Map.get(running_entry, :codex_last_reported_total_tokens, 0)
        }
    end
  end

  @spec extract_rate_limits(map()) :: map() | nil
  def extract_rate_limits(update) when is_map(update) do
    update
    |> Map.get(:payload)
    |> rate_limits_from_payload()
  end

  @spec humanize_message(map() | nil) :: String.t()
  def humanize_message(message), do: do_humanize_message(message)

  defp compute_delta(running_entry, token_key, usage, reported_key) do
    case get_token_usage(usage, token_key) do
      value when is_integer(value) ->
        max(0, value - Map.get(running_entry, reported_key, 0))

      _ ->
        0
    end
  end

  # Move the existing private token/rate-limit helper bodies from
  # SymphonyElixir.Orchestrator below this line without semantic changes.
end
```

Then paste these helper implementations from `SymphonyElixir.Orchestrator` below `compute_delta/4` and adapt private calls to the new public `extract_token_delta/2` contract. Do not change parsing behavior while moving code.

- `extract_token_usage/1`
- `absolute_token_usage_from_payload/1`
- `turn_completed_usage_from_payload/1`
- `rate_limits_from_payload/1`
- `rate_limit_payloads/1`
- `rate_limits_map?/1`
- `explicit_map_at_paths/2`
- `map_at_path/2`
- `integer_token_map?/1`
- `get_token_usage/2`
- `payload_get/2`
- `map_integer_value/2`
- `integer_like/1`

Keep those helpers private. The public test surface is `extract_token_delta/2`, `extract_rate_limits/1`, and `humanize_message/1`.

Then move the full existing `StatusDashboard.humanize_codex_message/1` helper family into this Module and expose it through `humanize_message/1`. Do not replace it with a smaller implementation. Include the existing private helper families for command execution, reasoning deltas, token-count wrappers, rate-limit updates, failure messages, and fallbacks.

- [ ] **Step 4: Wire orchestration and presentation to telemetry**

Modify `SymphonyElixir.Orchestrator.integrate_codex_update/2` and token helpers so the only remaining token call is:

```elixir
token_delta = SymphonyElixir.Codex.Telemetry.extract_token_delta(running_entry, update)
```

`extract_token_delta/2` must return a zero-delta map for non-token updates, preserving the current `Orchestrator` assumption that token accounting receives a map on every Codex update.

Modify rate-limit handling so it calls:

```elixir
case SymphonyElixir.Codex.Telemetry.extract_rate_limits(update) do
  nil -> state
  rate_limits -> %{state | codex_rate_limits: rate_limits}
end
```

Modify `SymphonyElixir.StatusDashboard` and `SymphonyElixirWeb.Presenter` so Codex message summaries call:

```elixir
SymphonyElixir.Codex.Telemetry.humanize_message(message)
```

Remove `StatusDashboard.humanize_codex_message/1` only after all callers have moved.

- [ ] **Step 5: Run telemetry and existing orchestration tests**

Run:

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/codex/telemetry_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/presenter_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/codex/telemetry.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/lib/symphony_elixir/status_dashboard.ex \
  elixir/lib/symphony_elixir_web/presenter.ex \
  elixir/test/symphony_elixir/codex/telemetry_test.exs \
  elixir/test/symphony_elixir/orchestrator_status_test.exs \
  elixir/test/symphony_elixir/presenter_test.exs
git commit -m "refactor: extract codex telemetry normalization"
```

## Task 2: Session History Module

**Files:**
- Create: `elixir/lib/symphony_elixir/orchestrator/session_history.ex`
- Create: `elixir/test/symphony_elixir/orchestrator/session_history_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: Write session-history tests**

Create `elixir/test/symphony_elixir/orchestrator/session_history_test.exs`:

```elixir
defmodule SymphonyElixir.Orchestrator.SessionHistoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.SessionHistory

  test "build_record captures session metadata and stop reason" do
    started_at = DateTime.add(DateTime.utc_now(), -5, :second)
    completed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    running_entry = %{
      thread_id: "thread-1",
      issue_id: "PVTI_1",
      retry_attempt: 2,
      dispatched_at: "2026-05-14T10:00:00Z",
      identifier: "archelab/symphony#1",
      model: "gpt-5.5",
      codex_input_tokens: 10,
      codex_output_tokens: 5,
      codex_total_tokens: 15,
      started_at: started_at
    }

    record = SessionHistory.build_record(running_entry, completed_at, :agent_exit_normal)

    assert %{
             thread_id: "thread-1",
             issue_id: "PVTI_1",
             attempt: 2,
             dispatched_at: "2026-05-14T10:00:00Z",
             completed_at: ^completed_at,
             identifier: "archelab/symphony#1",
             model: "gpt-5.5",
             codex_input_tokens: 10,
             codex_output_tokens: 5,
             codex_total_tokens: 15,
             stop_reason: :agent_exit_normal
           } = record

    assert record.duration_ms >= 0
  end

  test "record_completion prepends and prunes by max session count" do
    completed = %{"PVTI_1" => [%{thread_id: "old-1"}, %{thread_id: "old-2"}]}

    running_entry = %{
      thread_id: "new",
      issue_id: "PVTI_1",
      retry_attempt: 1,
      dispatched_at: "2026-05-14T10:00:00Z",
      identifier: "archelab/symphony#1",
      model: "gpt-5.5",
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: DateTime.utc_now()
    }

    updated = SessionHistory.record_completion(completed, "PVTI_1", running_entry, :stall_restart, max_sessions: 2)

    assert [%{thread_id: "new", issue_id: "PVTI_1", stop_reason: :stall_restart}, %{thread_id: "old-1"}] = updated["PVTI_1"]
  end
end
```

- [ ] **Step 2: Run the new tests and verify they fail**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/orchestrator/session_history_test.exs
```

Expected: failure because `SessionHistory` does not exist.

- [ ] **Step 3: Create the session-history Module**

Create `elixir/lib/symphony_elixir/orchestrator/session_history.ex`:

```elixir
defmodule SymphonyElixir.Orchestrator.SessionHistory do
  @moduledoc """
  Builds and prunes completed-session history for orchestrator state.
  """

  @type session_record :: map()

  @spec record_completion(map(), String.t(), map(), atom(), keyword()) :: map()
  def record_completion(completed, issue_id, running_entry, stop_reason, opts \\ [])
      when is_map(completed) and is_binary(issue_id) and is_map(running_entry) and is_atom(stop_reason) do
    completed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    record =
      running_entry
      |> build_record(completed_at, stop_reason)
      |> Map.put(:issue_id, issue_id)
    max_sessions = Keyword.fetch!(opts, :max_sessions)

    Map.update(completed, issue_id, [record], fn records ->
      [record | records]
      |> Enum.take(max_sessions)
    end)
  end

  @spec build_record(map(), String.t(), atom()) :: session_record()
  def build_record(running_entry, completed_at, stop_reason)
      when is_map(running_entry) and is_binary(completed_at) and is_atom(stop_reason) do
    %{
      thread_id: Map.get(running_entry, :thread_id),
      issue_id: Map.get(running_entry, :issue_id),
      attempt: Map.get(running_entry, :retry_attempt, 0),
      dispatched_at: Map.get(running_entry, :dispatched_at),
      completed_at: completed_at,
      duration_ms: duration_ms_for(running_entry),
      identifier: Map.get(running_entry, :identifier),
      model: Map.get(running_entry, :model),
      codex_input_tokens: Map.get(running_entry, :codex_input_tokens, 0),
      codex_output_tokens: Map.get(running_entry, :codex_output_tokens, 0),
      codex_total_tokens: Map.get(running_entry, :codex_total_tokens, 0),
      stop_reason: stop_reason
    }
  end

  @spec head_completed_at(map(), String.t()) :: String.t() | nil
  def head_completed_at(completed, issue_id) when is_map(completed) and is_binary(issue_id) do
    case Map.get(completed, issue_id) do
      [%{completed_at: completed_at} | _] -> completed_at
      _ -> nil
    end
  end

  defp duration_ms_for(%{started_at: %DateTime{} = started_at}) do
    DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
    |> max(0)
  end

  defp duration_ms_for(_running_entry), do: 0
end
```

- [ ] **Step 4: Wire Orchestrator to SessionHistory**

In `SymphonyElixir.Orchestrator`, replace the body of `complete_issue/4` with delegation:

```elixir
defp complete_issue(%State{} = state, issue_id, running_entry, stop_reason)
     when is_binary(issue_id) and is_map(running_entry) do
  completed =
    SessionHistory.record_completion(state.completed, issue_id, running_entry, stop_reason,
      max_sessions: max_sessions()
    )

  %{state | completed: completed, retry_attempts: Map.delete(state.retry_attempts, issue_id)}
end
```

Add the alias:

```elixir
alias SymphonyElixir.Orchestrator.SessionHistory
```

Replace `head_completed_at/2` with:

```elixir
defp head_completed_at(completed, issue_id), do: SessionHistory.head_completed_at(completed, issue_id)
```

Delete `build_session_record/3`, `duration_ms_for/1`, and `prune_sessions/1` from `Orchestrator` after the tests pass.

- [ ] **Step 5: Run session-history and core orchestration tests**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/orchestrator/session_history_test.exs test/symphony_elixir/core_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator/session_history.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/test/symphony_elixir/orchestrator/session_history_test.exs \
  elixir/test/symphony_elixir/core_test.exs
git commit -m "refactor: extract orchestrator session history"
```

## Task 3: Dispatch Policy Module

**Files:**
- Create: `elixir/lib/symphony_elixir/orchestrator/dispatch_policy.ex`
- Create: `elixir/test/symphony_elixir/orchestrator/dispatch_policy_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

- [ ] **Step 1: Write dispatch-policy tests**

Create `elixir/test/symphony_elixir/orchestrator/dispatch_policy_test.exs`:

```elixir
defmodule SymphonyElixir.Orchestrator.DispatchPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.DispatchPolicy

  test "sort_issues_for_dispatch orders by priority, created_at, and identifier" do
    issues = [
      %Issue{id: "2", identifier: "B", priority: nil, created_at: "2026-05-14T10:00:00Z"},
      %Issue{id: "1", identifier: "A", priority: 1, created_at: "2026-05-14T11:00:00Z"},
      %Issue{id: "3", identifier: "C", priority: 1, created_at: "2026-05-14T09:00:00Z"}
    ]

    assert Enum.map(DispatchPolicy.sort_issues_for_dispatch(issues), & &1.identifier) == ["C", "A", "B"]
  end

  test "dispatchable rejects no-status items and open blockers in gated states" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_dependency_gating_states: ["Agent Ready"],
      tracker_cross_repo_blockers: false
    )

    tracker = Config.settings!().tracker

    no_status = %Issue{id: "1", identifier: "A", state: "<no status>", kind: "issue", issue_state: "OPEN"}

    blocked = %Issue{
      id: "2",
      identifier: "archelab/symphony#2",
      state: "Agent Ready",
      kind: "issue",
      issue_state: "OPEN",
      repository: %Issue.Repository{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
      blocked_by: [
        %Issue.Blocker{id: "b1", identifier: "archelab/symphony#1", state: "OPEN"}
      ]
    }

    refute DispatchPolicy.dispatchable?(no_status, tracker)
    refute DispatchPolicy.dispatchable?(blocked, tracker)
  end

  test "dispatch_eligible blocks running and claimed issue ids" do
    issue = %Issue{id: "PVTI_1", identifier: "archelab/symphony#1", state: "Agent Ready", kind: "issue", issue_state: "OPEN"}
    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(["PVTI_1"])}

    refute DispatchPolicy.dispatch_eligible?(issue, state, Config.settings!().tracker, Config.settings!().worker)
  end
end
```

- [ ] **Step 2: Run the new tests and verify they fail**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/orchestrator/dispatch_policy_test.exs
```

Expected: failure because `DispatchPolicy` does not exist.

- [ ] **Step 3: Create DispatchPolicy by moving pure functions**

Create `elixir/lib/symphony_elixir/orchestrator/dispatch_policy.ex` with this public Interface:

```elixir
defmodule SymphonyElixir.Orchestrator.DispatchPolicy do
  @moduledoc """
  Pure dispatch and worker-selection decisions for the orchestrator.
  """

  alias SymphonyElixir.Orchestrator.State

  @spec sort_issues_for_dispatch([term()]) :: [term()]
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, &dispatch_sort_key/1)
  end

  @spec dispatch_eligible?(term(), State.t(), term(), term()) :: boolean()
  def dispatch_eligible?(issue, %State{running: running, claimed: claimed} = state, tracker_settings, worker_settings) do
    id = Map.get(issue, :id)

    is_binary(id) and
      not Map.has_key?(running, id) and
      not MapSet.member?(claimed, id) and
      worker_slots_available?(state, worker_settings) and
      state_slots_available?(issue, running) and
      dispatchable?(issue, tracker_settings)
  end

  @spec dispatchable?(term(), term()) :: boolean()
  def dispatchable?(issue, tracker_settings) do
    state_lc = issue |> Map.get(:state) |> normalize_issue_state()

    status_eligible?(state_lc, tracker_settings) and
      kind_dispatchable?(issue, state_lc, tracker_settings) and
      open_for_dispatch?(issue, state_lc, tracker_settings) and
      not blocked_for_state?(issue, state_lc, tracker_settings)
  end

  @spec select_worker_host(State.t(), String.t() | nil, term()) :: String.t() | nil | :no_worker_capacity
  def select_worker_host(%State{} = state, preferred_worker_host, worker_settings) do
    case Map.get(worker_settings, :ssh_hosts, []) do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1, worker_settings))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end
end
```

Paste the existing `select_worker_host/2` body from `SymphonyElixir.Orchestrator` into `DispatchPolicy.select_worker_host/3`, replacing `Config.settings!().worker` reads with the passed `worker_settings`. Then paste these existing private helper bodies below the public Interface without changing behavior:

- `dispatch_sort_key/1`
- `priority_rank/1`
- `issue_created_at_sort_key/1`
- `status_eligible?/2`
- `kind_dispatchable?/3`
- `open_for_dispatch?/3`
- `blocked_for_state?/3`
- `open_blockers/2`
- `honor_blocker?/3`
- `state_slots_available?/2`
- `running_issue_count_for_state/2`
- `normalize_issue_state/1`
- `available_slots/1`
- `preferred_worker_host_available?/2`
- `least_loaded_worker_host/2`
- `running_worker_host_count/2`
- `worker_slots_available?/2`
- `worker_slots_available?/3`
- `worker_host_slots_available?/3`

The resulting module must compile before wiring `Orchestrator` to it. This Module should not call `Config.settings!/0`; pass tracker and worker settings from `Orchestrator`.

- [ ] **Step 4: Wire Orchestrator to DispatchPolicy**

Add:

```elixir
alias SymphonyElixir.Orchestrator.DispatchPolicy
```

Keep the sequential `Enum.reduce/3` in `Orchestrator.choose_issues/2` so each selected issue sees the `state` returned after the previous dispatch. Replace only the pure predicates and sorting calls with `DispatchPolicy` calls:

```elixir
defp choose_issues(issues, state) do
  tracker_settings = Config.settings!().tracker
  worker_settings = Config.settings!().worker

  issues
  |> DispatchPolicy.sort_issues_for_dispatch()
  |> Enum.reduce(state, fn issue, state_acc ->
    if DispatchPolicy.dispatch_eligible?(issue, state_acc, tracker_settings, worker_settings) do
      dispatch_issue(state_acc, issue)
    else
      state_acc
    end
  end)
end
```

Replace `dispatchable?/2`, `select_worker_host/2`, and their `_for_test` wrappers with calls to `DispatchPolicy`.

Keep compatibility wrappers only if existing public tests still call them:

```elixir
@doc false
@spec sort_issues_for_dispatch_for_test([term()]) :: [term()]
def sort_issues_for_dispatch_for_test(issues), do: DispatchPolicy.sort_issues_for_dispatch(issues)

@doc false
@spec dispatch_eligible_for_test(term(), State.t(), term()) :: boolean()
def dispatch_eligible_for_test(issue, %State{} = state, tracker_settings),
  do: DispatchPolicy.dispatch_eligible?(issue, state, tracker_settings, Config.settings!().worker)
```

After moving tests to `dispatch_policy_test.exs`, delete wrappers that no longer have callers.

- [ ] **Step 5: Run dispatch and core tests**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/orchestrator/dispatch_policy_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator/dispatch_policy.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/test/symphony_elixir/orchestrator/dispatch_policy_test.exs \
  elixir/test/symphony_elixir/core_test.exs \
  elixir/test/symphony_elixir/workspace_and_config_test.exs
git commit -m "refactor: extract orchestrator dispatch policy"
```

## Task 4: Running-Reconciliation Module

**Files:**
- Create: `elixir/lib/symphony_elixir/orchestrator/reconciliation.ex`
- Create: `elixir/test/symphony_elixir/orchestrator/reconciliation_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: Write reconciliation tests**

Create `elixir/test/symphony_elixir/orchestrator/reconciliation_test.exs`:

```elixir
defmodule SymphonyElixir.Orchestrator.ReconciliationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.Reconciliation

  test "classify_refresh stops missing and terminal issues" do
    tracker = Config.settings!().tracker
    running = %{blocked_by_snapshot: []}

    assert Reconciliation.classify_refresh(nil, running, tracker) ==
             {:stop, :reconciled_missing, false}

    assert Reconciliation.classify_refresh(%{state: "<closed>", blocked_by: []}, running, tracker) ==
             {:stop, :terminal_or_closed, true}

    assert Reconciliation.classify_refresh(%{state: "<merged>", blocked_by: []}, running, tracker) ==
             {:stop, :terminal_or_merged, true}
  end

  test "classify_refresh keeps active refresh and updates blocker snapshot" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Agent Ready", "In Progress"],
      tracker_dependency_gating_states: ["Agent Ready"]
    )

    tracker = Config.settings!().tracker
    running = %{blocked_by_snapshot: []}
    refresh = %{id: "PVTI_1", state: "In Progress", blocked_by: [%{id: "b1", state: "CLOSED"}]}

    assert {:keep, ^refresh} = Reconciliation.classify_refresh(refresh, running, tracker)
  end

  test "classify_refresh stops when a previously closed blocker reopens" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Agent Ready", "In Progress"],
      tracker_dependency_gating_states: ["In Progress"],
      tracker_gate_running_on_dependencies: true
    )

    tracker = Config.settings!().tracker

    running = %{
      blocked_by_snapshot: [%{id: "b1", identifier: "archelab/symphony#1", state: "CLOSED"}]
    }

    refresh = %{id: "PVTI_1", state: "In Progress", blocked_by: [%{id: "b1", identifier: "archelab/symphony#1", state: "OPEN"}]}

    assert Reconciliation.classify_refresh(refresh, running, tracker) ==
             {:stop, :dependencies_reopened, false}
  end
end
```

- [ ] **Step 2: Run the new tests and verify they fail**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/orchestrator/reconciliation_test.exs
```

Expected: failure because `Reconciliation` does not exist.

- [ ] **Step 3: Create Reconciliation by moving pure helpers**

Create `elixir/lib/symphony_elixir/orchestrator/reconciliation.ex` with this public Interface:

```elixir
defmodule SymphonyElixir.Orchestrator.Reconciliation do
  @moduledoc """
  Classifies tracker refresh results for currently running issues.
  """

  @spec classify_refresh(map() | nil, map(), term()) ::
          :keep | {:keep, map()} | {:stop, atom(), boolean()}
  def classify_refresh(nil, _running_entry, _settings), do: {:stop, :reconciled_missing, false}
  def classify_refresh(%{state: "<no status>"}, _running_entry, _settings), do: :keep
  def classify_refresh(%{state: "<closed>"}, _running_entry, _settings), do: {:stop, :terminal_or_closed, true}
  def classify_refresh(%{state: "<merged>"}, _running_entry, _settings), do: {:stop, :terminal_or_merged, true}
end
```

Paste the remaining existing `classify_refresh/3` clauses from `SymphonyElixir.Orchestrator` below the four clauses shown above, preserving their order:

- `classify_refresh(%{state: state} = result, running_entry, settings)`
- `classify_refresh(_other, _running_entry, _settings)`

Then paste these existing helper bodies from `SymphonyElixir.Orchestrator` below the public clauses without changing behavior:

- `any_blockers_reopened?/2`
- `refresh_id/1`
- `normalize_issue_state/1`

Keep this Module pure. Do not call `Workspace`, `AgentRunner`, `Tracker`, or `StatusDashboard` from it. Before moving to Step 4, run `mise exec -- mix compile --warnings-as-errors`; every public clause must have the moved production body.

Preserve exact existing stop-reason atoms. In particular, keep `:terminal_or_closed`, `:terminal_or_merged`, `:terminal_state`, `:inactive_state`, `:dependencies_reopened`, and `:reconciled_missing` unchanged because structured logs and tests depend on this vocabulary.

- [ ] **Step 4: Wire Orchestrator to Reconciliation**

In `Orchestrator.reconcile_running/4`, replace direct classification with:

```elixir
case Reconciliation.classify_refresh(refresh_result, running_entry, tracker_settings) do
  decision -> apply_reconcile_decision(decision, state, issue_id, running_entry)
end
```

Add:

```elixir
alias SymphonyElixir.Orchestrator.Reconciliation
```

Keep `apply_reconcile_decision/4`, `terminate_running_issue/4`, workspace cleanup, logging, and dashboard notification in `Orchestrator`.

- [ ] **Step 5: Run reconciliation and core tests**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/orchestrator/reconciliation_test.exs test/symphony_elixir/core_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator/reconciliation.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/test/symphony_elixir/orchestrator/reconciliation_test.exs \
  elixir/test/symphony_elixir/core_test.exs
git commit -m "refactor: extract running reconciliation policy"
```

## Task 5: Observability Projection Module

**Files:**
- Create: `elixir/lib/symphony_elixir/observability/projection.ex`
- Create: `elixir/test/symphony_elixir/observability/projection_test.exs`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify: `elixir/test/symphony_elixir/presenter_test.exs`

- [ ] **Step 1: Write projection tests**

Create `elixir/test/symphony_elixir/observability/projection_test.exs`:

```elixir
defmodule SymphonyElixir.Observability.ProjectionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Observability.Projection

  test "state_payload projects counts and running entries from snapshot and completed sessions" do
    generated_at = "2026-05-14T12:00:00Z"

    snapshot = %{
      running: [
        %{
          issue_id: "PVTI_1",
          identifier: "archelab/symphony#1",
          state: "In Progress",
          session_id: "thread-turn",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: %{event: :notification, message: %{"method" => "codex/event/task_started"}},
          last_codex_timestamp: DateTime.utc_now(),
          started_at: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 5,
          codex_total_tokens: 15
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 10, output_tokens: 5, total_tokens: 15, seconds_running: 1},
      rate_limits: nil
    }

    completed = []

    payload = Projection.state_payload(snapshot, completed, generated_at)

    assert payload.counts == %{running: 1, retrying: 0, completed: 0}
    assert [%{issue_identifier: "archelab/symphony#1", last_message: "task started"}] = payload.running
  end

  test "issue_payload returns completed status when only completed sessions exist" do
    completed = [
      %{
        issue_id: "PVTI_1",
        identifier: "archelab/symphony#1",
        thread_id: "thread",
        attempt: 1,
        dispatched_at: "2026-05-14T10:00:00Z",
        completed_at: "2026-05-14T10:01:00Z",
        duration_ms: 60_000,
        model: "gpt-5.5",
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        stop_reason: :agent_exit_normal
      }
    ]

    assert {:ok, payload} =
             Projection.issue_payload("archelab/symphony#1", [], [], completed)

    assert payload.status == "completed"
    assert payload.issue_id == "PVTI_1"
  end
end
```

- [ ] **Step 2: Run the new tests and verify they fail**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/observability/projection_test.exs
```

Expected: failure because `Projection` does not exist.

- [ ] **Step 3: Create Projection from Presenter pure code**

Create `elixir/lib/symphony_elixir/observability/projection.ex` with this public Interface:

```elixir
defmodule SymphonyElixir.Observability.Projection do
  @moduledoc """
  Projects orchestrator runtime state into observability read models.
  """

  alias SymphonyElixir.Codex.Telemetry
  alias SymphonyElixir.Workspace

  @spec state_payload(map(), [map()], String.t()) :: map()
  def state_payload(%{} = snapshot, completed, generated_at) when is_list(completed) and is_binary(generated_at) do
    %{
      generated_at: generated_at,
      counts: %{
        running: length(snapshot.running),
        retrying: length(snapshot.retrying),
        completed: length(completed)
      },
      running: Enum.map(snapshot.running, &running_entry_payload/1),
      retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
      completed: Enum.map(completed, &completed_session_payload/1),
      codex_totals: snapshot.codex_totals,
      rate_limits: snapshot.rate_limits
    }
  end

  @spec issue_payload(String.t(), [map()], [map()], [map()], keyword()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, running_entries, retry_entries, completed, opts)
      when is_binary(issue_identifier) and is_list(running_entries) and is_list(retry_entries) and is_list(completed) and is_list(opts) do
    running = Enum.find(running_entries, &(&1.identifier == issue_identifier))
    retry = Enum.find(retry_entries, &(&1.identifier == issue_identifier))

    if is_nil(running) and is_nil(retry) and completed == [] do
      {:error, :issue_not_found}
    else
      {:ok, issue_payload_body(issue_identifier, running, retry, completed, opts)}
    end
  end

  defp summarize_message(message), do: Telemetry.humanize_message(message)
end
```

Move these helper bodies from `SymphonyElixirWeb.Presenter` into `Projection`:

- `running_entry_payload/1`
- `retry_entry_payload/1`
- `completed_session_payload/1`
- `issue_payload_body/4`
- `issue_id_from_entries/3`
- `restart_count/1`
- `retry_attempt/1`
- `issue_status/3`
- `running_issue_payload/1`
- `retry_issue_payload/1`
- `issue_metadata/2`
- `repository_payload/1`
- `pr_payload/1`
- `links_payload/2`
- `session_metadata/3`
- `workpad_metadata/3`
- `timeline_payload/3`
- `timeline_gap_payload/0`
- `tokens_payload/1`
- `running_timeline/1`
- `retry_timeline/1`
- `completed_timeline/1`
- `workspace_path/3`
- `workspace_host/2`
- formatting helpers that are pure and only serve the API/LiveView read model.

Do not move `Orchestrator.snapshot/2`, `Orchestrator.completed_sessions/2`, `Orchestrator.completed_sessions_for/3`, `Config.settings!/0`, or workspace-root reads into `Projection`. Those calls stay in `Presenter`, which is the Adapter that talks to the running process and current config. Pass `workspace_root: Config.settings!().workspace.root` into `Projection.issue_payload/5` when workspace paths are needed.

- [ ] **Step 4: Thin Presenter to fetch data and call Projection**

Keep `SymphonyElixirWeb.Presenter` responsible for:

- calling `Orchestrator.snapshot/2`
- calling `Orchestrator.completed_sessions/2`
- calling `Orchestrator.completed_sessions_for/3`
- mapping timeout/unavailable errors

Change successful state projection to:

```elixir
Projection.state_payload(snapshot, completed, generated_at)
```

Change successful issue projection to:

```elixir
Projection.issue_payload(issue_identifier, snapshot.running, snapshot.retrying, completed,
  workspace_root: Config.settings!().workspace.root
)
```

- [ ] **Step 5: Run projection and presenter tests**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix test test/symphony_elixir/observability/projection_test.exs test/symphony_elixir/presenter_test.exs test/symphony_elixir/extensions_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/observability/projection.ex \
  elixir/lib/symphony_elixir_web/presenter.ex \
  elixir/lib/symphony_elixir/status_dashboard.ex \
  elixir/test/symphony_elixir/observability/projection_test.exs \
  elixir/test/symphony_elixir/presenter_test.exs
git commit -m "refactor: extract observability projection"
```

## Task 6: Runtime Notifications, Cycle, and Coverage Cleanup

**Files:**
- Create: `elixir/lib/symphony_elixir/observability/notifications.ex`
- Create: `elixir/test/symphony_elixir/observability/notifications_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify: `elixir/lib/symphony_elixir/workflow_store.ex`
- Modify: `elixir/lib/symphony_elixir/github/adapter.ex`
- Modify: `elixir/lib/symphony_elixir_web/observability_pubsub.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/issue_live.ex`
- Modify: `elixir/mix.exs`
- Modify: `elixir/test/symphony_elixir/github/adapter_test.exs`

- [ ] **Step 1: Run xref cycle check**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix xref graph --format cycles
```

Expected before cleanup: the old graph may still include cycles around observability or workflow/tracker. Record the exact output in the PR notes.

- [ ] **Step 2: Create a core runtime notification Module**

Create `elixir/lib/symphony_elixir/observability/notifications.ex`:

```elixir
defmodule SymphonyElixir.Observability.Notifications do
  @moduledoc """
  Runtime observability notifications shared by terminal and web observers.
  """

  @default_pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated

  @spec subscribe(atom()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(pubsub \\ @default_pubsub) do
    Phoenix.PubSub.subscribe(pubsub, @topic)
  end

  @spec broadcast_update(atom()) :: :ok | {:error, term()}
  def broadcast_update(pubsub \\ @default_pubsub) do
    case Process.whereis(pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end
end
```

Create `elixir/test/symphony_elixir/observability/notifications_test.exs`:

```elixir
defmodule SymphonyElixir.Observability.NotificationsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Observability.Notifications

  test "broadcast_update notifies subscribers when pubsub is running" do
    assert :ok = Notifications.subscribe()
    assert :ok = Notifications.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    assert :ok = Notifications.broadcast_update(Module.concat(__MODULE__, MissingPubSub))
  end
end
```

- [ ] **Step 3: Break the observability cycle**

If `StatusDashboard -> Orchestrator -> StatusDashboard` remains, remove direct dependencies in this order:

1. Keep `Orchestrator.notify_dashboard/0` as a local side-effect wrapper.
2. Change the wrapper to call `SymphonyElixir.Observability.Notifications.broadcast_update/0`.
3. Change `StatusDashboard.init/1` to subscribe to `Notifications` when enabled.
4. Change `StatusDashboard.handle_info(:observability_updated, state)` to reuse the same immediate render path as `:refresh`.
5. Keep `StatusDashboard.notify_update/1` only if tests or external callers still use it, but implement it through `Notifications.broadcast_update/0`.

The Orchestrator call site should look like:

```elixir
defp notify_dashboard do
  _ = SymphonyElixir.Observability.Notifications.broadcast_update()
  :ok
end
```

Do not call `StatusDashboard` from `Orchestrator`. Do not make core runtime depend on `SymphonyElixirWeb.*`.

Replace `SymphonyElixirWeb.ObservabilityPubSub` with a compatibility wrapper:

```elixir
defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  Compatibility wrapper for observability dashboard updates.
  """

  alias SymphonyElixir.Observability.Notifications

  @spec subscribe(atom()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(pubsub \\ SymphonyElixir.PubSub), do: Notifications.subscribe(pubsub)

  @spec broadcast_update(atom()) :: :ok | {:error, term()}
  def broadcast_update(pubsub \\ SymphonyElixir.PubSub), do: Notifications.broadcast_update(pubsub)
end
```

Then update LiveViews to alias `SymphonyElixir.Observability.Notifications` directly, leaving the wrapper only for compatibility tests.

- [ ] **Step 4: Remove redundant workflow reload adapter invalidation**

If `WorkflowStore -> GithubAdapter -> Tracker -> Config -> Workflow -> WorkflowStore` remains, remove the direct `GithubAdapter` dependency from `WorkflowStore`.

Rationale: `Github.Adapter.ensure_resolved/0` already computes a cache key from effective tracker settings:

```elixir
{tracker.endpoint, tracker.api_token, tracker.owner, tracker.owner_type, tracker.project_id, tracker.project_number, tracker.status_field}
```

That means a `WORKFLOW.md` edit that changes project identity naturally misses the old cache. The explicit reload hook is redundant for config-changing reloads and creates structural coupling.

In `elixir/lib/symphony_elixir/workflow_store.ex`, delete:

```elixir
alias SymphonyElixir.Github.Adapter, as: GithubAdapter
```

Replace `after_reload/2` with:

```elixir
defp after_reload(_old, _new), do: :ok
```

Keep `Github.Adapter.invalidate_cache/0` as `@doc false` for tests or future explicit operator use. Do not introduce a `Tracker.workflow_reloaded/0` callback; that would keep `WorkflowStore -> Tracker -> Config -> WorkflowStore` coupled through the generic Interface.

- [ ] **Step 4a: Add a regression test for config-keyed GitHub cache**

In `elixir/test/symphony_elixir/github/adapter_test.exs`, add a test proving a changed tracker project causes a new resolver call without explicit invalidation:

```elixir
test "resolved project cache misses when tracker project config changes" do
  Adapter.invalidate_cache()
  parent = self()

  Application.put_env(:symphony_elixir, :github_client, fn query, variables, _opts ->
    send(parent, {:graphql, query, variables})
    {:ok, project_payload("PVT_first")}
  end)

  write_github_workflow_file!(Workflow.workflow_file_path(), tracker_project_number: 1)
  assert {:ok, []} = Adapter.fetch_candidate_issues()

  Application.put_env(:symphony_elixir, :github_client, fn query, variables, _opts ->
    send(parent, {:graphql_after_change, query, variables})
    {:ok, project_payload("PVT_second")}
  end)

  write_github_workflow_file!(Workflow.workflow_file_path(), tracker_project_number: 2)
  assert {:ok, []} = Adapter.fetch_candidate_issues()

  :ok
end
```

Use the existing payload helper style in `adapter_test.exs`; if there is no compatible helper, define a local private helper in the test file that returns a minimal ProjectV2 payload with no items.

- [ ] **Step 5: Remove obsolete coverage ignores only for extracted pure Modules**

Open `elixir/mix.exs`. Do not add any new ignored Modules. Ensure these newly-created pure Modules are not listed in `ignore_modules`:

```elixir
SymphonyElixir.Codex.Telemetry
SymphonyElixir.Orchestrator.SessionHistory
SymphonyElixir.Orchestrator.DispatchPolicy
SymphonyElixir.Orchestrator.Reconciliation
SymphonyElixir.Observability.Projection
```

Keep existing ignores for GenServer plumbing unless a moved test makes a removal obviously safe.

- [ ] **Step 6: Run xref and focused suites**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix xref graph --format cycles
mise exec -- mix test test/symphony_elixir/codex/telemetry_test.exs \
  test/symphony_elixir/orchestrator/session_history_test.exs \
  test/symphony_elixir/orchestrator/dispatch_policy_test.exs \
  test/symphony_elixir/orchestrator/reconciliation_test.exs \
  test/symphony_elixir/observability/projection_test.exs \
  test/symphony_elixir/observability/notifications_test.exs \
  test/symphony_elixir/core_test.exs \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/presenter_test.exs
```

Expected: no observability cycle, and all focused tests pass.

- [ ] **Step 7: Commit**

```bash
git add elixir/lib/symphony_elixir/observability/notifications.ex \
  elixir/test/symphony_elixir/observability/notifications_test.exs
git add elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/lib/symphony_elixir/status_dashboard.ex \
  elixir/lib/symphony_elixir/workflow_store.ex \
  elixir/lib/symphony_elixir/github/adapter.ex \
  elixir/lib/symphony_elixir_web/observability_pubsub.ex \
  elixir/lib/symphony_elixir_web/live/dashboard_live.ex \
  elixir/lib/symphony_elixir_web/live/issue_live.ex \
  elixir/mix.exs \
  elixir/test/symphony_elixir/github/adapter_test.exs
git commit -m "refactor: reduce runtime dependency cycles"
```

## Task 7: Documentation and Final Gates

**Files:**
- Modify: `elixir/README.md`
- Modify: `elixir/docs/token_accounting.md`
- Modify: `elixir/docs/logging.md`
- Modify: `elixir/scripts/e2e_smoke/README.md`

The smoke README update is opportunistic verified drift cleanup discovered during the architecture audit. Keep it in this PR only if the architecture refactor already touches final docs; otherwise split this step into a separate docs-only PR.

- [ ] **Step 1: Update architecture docs only where behavior-facing concepts moved**

In `elixir/docs/token_accounting.md`, add a short section after "Recommended Accounting Strategy For Symphony":

```markdown
## Implementation Location

`SymphonyElixir.Codex.Telemetry` is the single source of truth for Codex token
usage extraction, rate-limit extraction, and user-facing event summaries.
`SymphonyElixir.Codex.AppServer` remains the protocol Adapter; it should emit
raw messages and let `Codex.Telemetry` normalize accounting semantics.
```

In `elixir/docs/logging.md`, add a short note under "Scope Guidance":

```markdown
Pure orchestration decisions live outside the GenServer where possible. Keep
side-effecting lifecycle logs in `SymphonyElixir.Orchestrator`, and keep
decision Modules free of Logger calls unless a future interface explicitly
returns structured log events.
```

- [ ] **Step 2: Fix smoke README drift**

In `elixir/scripts/e2e_smoke/README.md`:

1. Update the case table so E2E-11 and E2E-12 appear.
2. Remove or rewrite the stale note that says E2E-7 currently fails because `subIssues` is missing.
3. State the current dependency-gating expectation:

```markdown
| E2E-11 | A blocked item must post a separate `## Blocker report` before moving to Blocked. |
| E2E-12 | Spawned agents inherit GitHub auth without needing to source `~/.zshrc`. |
```

Replace the stale E2E-7 note with:

```markdown
- **E2E-7 (dependency gating)**: the GitHub adapter reads native `blockedBy`,
  legacy `trackedIssues`, and GitHub sub-issue `subIssues`, then merges them
  into the normalized `blocked_by` list. A failure here is a regression in
  dependency discovery or status gating, not an expected harness limitation.
```

- [ ] **Step 3: Run full local gates**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix lint
mise exec -- mix test_strict
GITHUB_TOKEN=$(gh auth token) mise exec -- mix test --only live_github
```

Expected:

- `mix lint` exits 0.
- `mix test_strict` exits 0 with 100.00% coverage.
- live GitHub tests exit 0.

- [ ] **Step 4: Run xref report for PR notes**

```bash
source ~/.zshrc
cd /Users/pedrocunha/repos/symphony/elixir
mise exec -- mix xref graph --format cycles
mise exec -- mix xref graph --label runtime --format stats
```

Expected: cycle output is improved versus the baseline. If any cycle remains, document why it remains and which follow-up should own it.

- [ ] **Step 5: Commit docs and final cleanup**

```bash
git add elixir/README.md \
  elixir/docs/token_accounting.md \
  elixir/docs/logging.md \
  elixir/scripts/e2e_smoke/README.md
git commit -m "docs: document runtime architecture seams"
```

## Final Review Checklist

- [ ] `rg "TODO|TBD|implement later|similar to" docs/superpowers/plans/2026-05-14-symphony-runtime-architecture-deepening.md` returns no matches outside this checklist.
- [ ] `rg "Linear|linear_graphql|linear_project_url" elixir/lib elixir/test elixir/mix.exs elixir/.credo.exs .github` returns no matches, except the existing allowed README migration callout if searched repo-wide.
- [ ] `mise exec -- mix specs.check` passes.
- [ ] `mise exec -- mix lint` passes.
- [ ] `mise exec -- mix test_strict` passes with 100.00% coverage.
- [ ] `GITHUB_TOKEN=$(gh auth token) mise exec -- mix test --only live_github` passes.
- [ ] PR body follows `../.github/pull_request_template.md` and validates with `mix pr_body.check --file /path/to/pr_body.md`.

## Execution Recommendation

Use subagent-driven implementation with one fresh worker per task. After each task, run the task's focused tests and inspect the diff before dispatching the next worker. Do not parallelize tasks 1-6 because each touches `Orchestrator`, observability, or shared tests and would create avoidable merge conflicts.
