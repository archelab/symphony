defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured tracker (GitHub Projects v2 in production, the in-memory
  adapter for tests) and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Github.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    @typedoc """
    Per-issue running-worker record. Fields documented inline by the dispatch
    site `spawn_issue_on_worker_host/4`; codex_* fields are written by
    `integrate_codex_update/2`.

    SPEC §11.8.5 fields: `:thread_id`, `:dispatched_at`, `:model` capture
    workpad-relevant metadata at dispatch time so they survive into the
    `session_record` history that `complete_issue/3` writes.
    """
    @type running_entry :: %{
            required(:pid) => pid() | nil,
            required(:ref) => reference() | nil,
            required(:issue_id) => String.t(),
            required(:issue_identifier) => String.t(),
            required(:identifier) => String.t(),
            required(:issue) => SymphonyElixir.Github.Issue.t() | map(),
            required(:worker_host) => String.t() | nil,
            required(:workspace_path) => String.t() | nil,
            required(:session_id) => String.t() | nil,
            required(:last_codex_message) => map() | nil,
            required(:last_codex_timestamp) => DateTime.t() | nil,
            required(:last_codex_event) => atom() | nil,
            required(:codex_app_server_pid) => String.t() | nil,
            required(:codex_input_tokens) => non_neg_integer(),
            required(:codex_output_tokens) => non_neg_integer(),
            required(:codex_total_tokens) => non_neg_integer(),
            required(:codex_last_reported_input_tokens) => non_neg_integer(),
            required(:codex_last_reported_output_tokens) => non_neg_integer(),
            required(:codex_last_reported_total_tokens) => non_neg_integer(),
            required(:turn_count) => non_neg_integer(),
            required(:retry_attempt) => non_neg_integer(),
            required(:blocked_by_snapshot) => [map()],
            required(:started_at) => DateTime.t(),
            required(:dispatched_at) => String.t(),
            required(:thread_id) => String.t() | nil,
            required(:model) => String.t() | nil,
            optional(:last_refresh_state) => String.t() | nil
          }

    @typedoc """
    SPEC §11.8.5: one session-history row captured when a running worker
    terminates. The orchestrator stores most-recent-first lists keyed by
    issue id under `State.completed`.
    """
    @type session_record :: %{
            required(:thread_id) => String.t() | nil,
            required(:issue_id) => String.t(),
            required(:attempt) => non_neg_integer(),
            required(:dispatched_at) => String.t(),
            required(:completed_at) => String.t(),
            required(:duration_ms) => non_neg_integer(),
            required(:identifier) => String.t() | nil,
            required(:model) => String.t() | nil,
            required(:codex_input_tokens) => non_neg_integer(),
            required(:codex_output_tokens) => non_neg_integer(),
            required(:codex_total_tokens) => non_neg_integer(),
            required(:stop_reason) => atom() | nil
          }

    @typedoc """
    SPEC §11.8.5 completed map: per-issue history of session records, head
    is the most recent. Pruned to `agent.workpad.max_sessions_visible`.
    """
    @type completed_map :: %{optional(String.t()) => [session_record()]}

    @typedoc """
    Per-issue retry record. `timer_ref` and `retry_token` are paired so a stale
    timer (cancelled retry) cannot reactivate a different attempt.
    """
    @type retry_entry :: %{
            required(:attempt) => pos_integer(),
            required(:timer_ref) => reference(),
            required(:retry_token) => reference(),
            required(:due_at_ms) => integer(),
            required(:identifier) => String.t() | nil,
            required(:error) => String.t() | nil,
            required(:worker_host) => String.t() | nil,
            required(:workspace_path) => String.t() | nil
          }

    @typedoc """
    Aggregate codex token + runtime counters surfaced via `:snapshot`.
    """
    @type codex_totals :: %{
            required(:input_tokens) => non_neg_integer(),
            required(:output_tokens) => non_neg_integer(),
            required(:total_tokens) => non_neg_integer(),
            required(:seconds_running) => non_neg_integer()
          }

    @type t :: %__MODULE__{
            poll_interval_ms: pos_integer() | nil,
            max_concurrent_agents: non_neg_integer() | nil,
            next_poll_due_at_ms: integer() | nil,
            poll_check_in_progress: boolean() | nil,
            tick_timer_ref: reference() | nil,
            tick_token: reference() | nil,
            running: %{optional(String.t()) => running_entry()},
            completed: completed_map(),
            claimed: MapSet.t(String.t()),
            retry_attempts: %{optional(String.t()) => retry_entry()},
            codex_totals: codex_totals() | nil,
            codex_rate_limits: map() | nil
          }

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      # SPEC §4.1.8 + §11.8.5: `completed` is now a map issue_id → [session_record, ...]
      # (most-recent-first list) so the prompt builder can both derive
      # `last_run_completed_at` (head record) and surface `prior_sessions` to
      # the agent workpad. Pruned to `agent.workpad.max_sessions_visible`.
      completed: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        stop_reason = if reason == :normal, do: :agent_exit_normal, else: :agent_exit_crashed

        # §13.1 structured-log site for agent-process exits. The worker is
        # already dead (we got :DOWN), so we skip the demonitor + terminate
        # branch of terminate_running_issue/4 and call log_worker_stop/2 here
        # directly to avoid the double-cleanup risk.
        log_worker_stop(running_entry, stop_reason)

        # SPEC §11.8.3 + §11.8.5: record EVERY session — normal AND abnormal —
        # so the next dispatched session can patch the prior row's Ended /
        # Duration / Stop reason via `prior_sessions[0]`. Crashes that go
        # unrecorded would leave a permanent "—" row in the workpad table.
        state = complete_issue(state, issue_id, running_entry, stop_reason)

        state =
          case reason do
            :normal ->
              schedule_issue_retry(state, issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })

            _ ->
              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })
          end

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  # SPEC §11.8.5: capture the agent's Codex thread id into the running entry
  # as soon as `AppServer.start_session/2` returns it. The id is then forwarded
  # into the eventual `session_record` written by `complete_issue/4`.
  def handle_info({:codex_thread_started, issue_id, thread_id}, %{running: running} = state)
      when is_binary(issue_id) and is_binary(thread_id) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated = Map.put(running_entry, :thread_id, thread_id)
        {:noreply, %{state | running: Map.put(running, issue_id, updated)}}
    end
  end

  def handle_info({:codex_thread_started, _issue_id, _thread_id}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_tracker_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      # Spec §11.4 canonical tracker errors — operator-actionable messages
      # so the dashboard log surfaces the fix without diving into the source.
      {:error, {:tracker_project_not_found, ctx}} ->
        Logger.warning(
          "Tracker project not found — check tracker.owner / tracker.project_number in WORKFLOW.md",
          owner: get_ctx(ctx, :owner),
          project_number: get_ctx(ctx, :project_number),
          reason: :tracker_project_not_found
        )

        state

      {:error, {:tracker_status_field_missing, ctx}} ->
        Logger.warning(
          "Tracker Status field missing on the project — verify the Project has a single-select field named '#{get_ctx(ctx, :status_field) || "Status"}'",
          project_id: get_ctx(ctx, :project_id),
          status_field: get_ctx(ctx, :status_field),
          reason: :tracker_status_field_missing
        )

        state

      {:error, {:tracker_permission_denied, ctx}} ->
        Logger.warning(
          "GitHub returned permission denied — check GITHUB_TOKEN scopes (need `project` + `repo`)",
          reason: :tracker_permission_denied,
          context: inspect(ctx)
        )

        state

      {:error, {:github_rate_limited, ctx}} ->
        Logger.info(
          "GitHub GraphQL rate-limited; polling will retry after the rate-limit window",
          retry_after_seconds: get_ctx(ctx, :retry_after_seconds),
          reason: :github_rate_limited
        )

        state

      {:error, reason} ->
        Logger.error("Failed to fetch from tracker: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp get_ctx(ctx, key) when is_map(ctx), do: Map.get(ctx, key) || Map.get(ctx, to_string(key))
  defp get_ctx(_ctx, _key), do: nil

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, refresh_results} ->
          apply_reconcile_running(state, refresh_results)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp apply_reconcile_running(%State{} = state, refresh_results) do
    tracker_settings = Config.settings!().tracker

    Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
      reconcile_running({issue_id, running_entry}, refresh_results, tracker_settings, state_acc)
    end)
  end

  @doc false
  # Test seam: drives `apply_reconcile_running/2` end-to-end so a refactor
  # cannot drift the production `reconcile_running_issues/1 ->
  # apply_reconcile_running/2 -> reconcile_running/4` call path silently.
  @spec apply_reconcile_running_for_test(State.t(), [map()]) :: State.t()
  def apply_reconcile_running_for_test(%State{} = state, refresh_results)
      when is_list(refresh_results) do
    apply_reconcile_running(state, refresh_results)
  end

  @doc false
  # Test seam for the stall-detection path. Drives the same code path the
  # poll tick uses so a refactor cannot drift `reconcile_stalled_running_issues`
  # silently — and exercises §11.8.3's "record every session" requirement for
  # :stall_restart.
  @spec apply_reconcile_stalled_runs_for_test(State.t()) :: State.t()
  def apply_reconcile_stalled_runs_for_test(%State{} = state) do
    reconcile_stalled_running_issues(state)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([term()]) :: [term()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  # Test seam for `dispatch_eligible?/3`. Public so the SPEC §4.1.8 invariant
  # ("state.completed is bookkeeping only, not a dispatch gate") has a direct
  # regression test — a future change that re-introduces a `completed`-keyed
  # gate would shut out Rework re-dispatch (§11.8.3) silently.
  @spec dispatch_eligible_for_test(term(), State.t(), term()) :: boolean()
  def dispatch_eligible_for_test(issue, %State{} = state, tracker_settings) do
    dispatch_eligible?(issue, state, tracker_settings)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  # §13.1 single termination + structured-log site. EVERY worker stop —
  # reconcile, missing, stall, agent-exit cleanup — funnels through
  # `log_worker_stop/2` so the reason vocabulary lives in ONE place. The full
  # vocabulary actually used in the codebase today:
  #   :terminal_or_closed, :terminal_or_merged, :terminal_state,
  #   :inactive_state, :reconciled_missing, :dependencies_reopened,
  #   :stall_restart, :agent_exit_normal, :agent_exit_crashed.
  defp terminate_running_issue(state, issue_id, cleanup_workspace, reason)

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, reason)
       when is_atom(reason) do
    case Map.get(state.running, issue_id) do
      nil ->
        log_worker_stop(%{issue_id: issue_id}, reason)
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        graceful_result = request_graceful_worker_stop(pid, ref, reason)
        logged_reason = logged_stop_reason(reason, graceful_result)
        log_worker_stop(running_entry, logged_reason, stop_log_fields(reason, graceful_result))
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if graceful_result == :timeout and is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        # SPEC §11.8.3 + §11.8.5: capture EVERY terminated session — including
        # stall_restart — into the workpad history before the running entry is
        # dropped. Stall restart re-dispatches under a NEW Codex thread id,
        # producing a distinct workpad row keyed by thread (not attempt), so
        # recording it does not double-count the run.
        state = complete_issue(state, issue_id, running_entry, logged_reason)

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        log_worker_stop(%{issue_id: issue_id}, reason)
        release_issue_claim(state, issue_id)
    end
  end

  # Reason and identifiers are baked into the message text so capture_log/1
  # (which strips metadata by default) still surfaces them in tests; the same
  # fields are also emitted as Logger metadata for structured backends.
  #
  # Level dispatch: crash and stall reasons are operator-actionable error
  # conditions and log at :warning. All other reasons (clean orchestrator
  # decisions, terminal-state moves, dependency reopens, normal exits) log at
  # :info so quiet operation stays quiet.
  defp request_graceful_worker_stop(pid, ref, reason)
       when is_pid(pid) and is_reference(ref) and is_atom(reason) do
    budget_ms = Config.settings!().agent.graceful_termination_budget_ms

    cond do
      budget_ms <= 0 ->
        :timeout

      !Process.alive?(pid) ->
        :already_exited

      true ->
        send(pid, {:symphony_wrap_up, %{reason: reason, budget_ms: budget_ms}})

        receive do
          {:DOWN, ^ref, :process, ^pid, down_reason} -> {:exited, down_reason}
        after
          budget_ms -> :timeout
        end
    end
  end

  defp request_graceful_worker_stop(_pid, _ref, _reason), do: :timeout

  defp logged_stop_reason(_original_reason, {:exited, :normal}), do: :agent_exit_normal
  defp logged_stop_reason(_original_reason, {:exited, _reason}), do: :agent_exit_crashed
  defp logged_stop_reason(_original_reason, :already_exited), do: :agent_exit_normal
  defp logged_stop_reason(original_reason, :timeout), do: original_reason

  defp stop_log_fields(original_reason, {:exited, _down_reason}), do: [final_intent: original_reason]
  defp stop_log_fields(original_reason, :already_exited), do: [final_intent: original_reason]
  defp stop_log_fields(_original_reason, :timeout), do: [graceful: false]

  defp log_worker_stop(running_entry, reason, extra_fields \\ []) when is_map(running_entry) and is_atom(reason) do
    issue_id = Map.get(running_entry, :issue_id) || Map.get(running_entry, :id)

    issue_identifier =
      Map.get(running_entry, :issue_identifier) || Map.get(running_entry, :identifier)

    session_id = Map.get(running_entry, :session_id)
    extra_message = Enum.map_join(extra_fields, "", fn {key, value} -> " #{key}=#{inspect(value)}" end)

    Logger.log(
      log_level_for_stop_reason(reason),
      "worker stop reason=#{inspect(reason)} issue_id=#{inspect(issue_id)} " <>
        "issue_identifier=#{inspect(issue_identifier)} session_id=#{inspect(session_id)}" <> extra_message,
      Keyword.merge(
        [
          issue_id: issue_id,
          issue_identifier: issue_identifier,
          session_id: session_id,
          reason: reason
        ],
        extra_fields
      )
    )

    :ok
  end

  defp log_level_for_stop_reason(reason) when reason in [:agent_exit_crashed, :stall_restart],
    do: :warning

  defp log_level_for_stop_reason(_reason), do: :info

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false, :stall_restart)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    tracker_settings = Config.settings!().tracker

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if dispatch_eligible?(issue, state_acc, tracker_settings) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  # Live dispatch gate: spec semantics (§11.2.1 terminal-OR + §8.2.1 gating) AND
  # local capacity guards (claim, running, per-state cap, ssh worker cap).
  # `dispatchable?/2` is the spec predicate; everything else is orchestrator-
  # local bookkeeping.
  #
  # SPEC §4.1.8: `state.completed` is bookkeeping only, NOT a dispatch gate.
  # `state.claimed` is the actual concurrency-of-dispatch signal — it stays
  # set across continuation retries and is only released by the retry timer
  # when the issue leaves Active/terminal. Gating on `completed` here would
  # permanently shut out an issue after a crash whose retry chain was torn
  # down (e.g., crash → status moved out of Active mid-retry → release_issue_
  # claim cleared `claimed` → user moves status back to Active to re-trigger).
  # The Rework re-dispatch flow (§11.8.3) relies on this gate being claim-only.
  defp dispatch_eligible?(issue, %State{running: running, claimed: claimed} = state, tracker_settings) do
    issue_id = Map.get(issue, :id)

    dispatchable?(issue, tracker_settings) and
      is_binary(issue_id) and
      !MapSet.member?(claimed, issue_id) and
      !Map.has_key?(running, issue_id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, &dispatch_sort_key/1)
  end

  defp dispatch_sort_key(issue) when is_map(issue) do
    priority = Map.get(issue, :priority)
    identifier = Map.get(issue, :identifier) || Map.get(issue, :id) || ""
    {priority_rank(priority), issue_created_at_sort_key(issue), identifier}
  end

  defp dispatch_sort_key(_), do: {priority_rank(nil), issue_created_at_sort_key(nil), ""}

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(issue) when is_map(issue) do
    case Map.get(issue, :created_at) do
      %DateTime{} = created_at -> DateTime.to_unix(created_at, :microsecond)
      _ -> 9_223_372_036_854_775_807
    end
  end

  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  @doc false
  # SPEC §11.2.1 terminal-OR + §8.2 eligibility + §8.2.1 dependency gating.
  # `tracker_settings` is the validated `Config.settings!().tracker` struct.
  @spec dispatchable?(map(), map()) :: boolean()
  def dispatchable?(issue, tracker_settings) do
    state_lc = String.downcase(Map.get(issue, :state) || "")

    if status_eligible?(state_lc, tracker_settings) do
      kind_dispatchable?(issue, state_lc, tracker_settings)
    else
      false
    end
  end

  defp status_eligible?("<no status>", _settings), do: false

  defp status_eligible?(state_lc, settings) do
    active = Enum.map(settings.active_states || [], &String.downcase/1)
    terminal = Enum.map(settings.terminal_states || [], &String.downcase/1)
    state_lc not in terminal and state_lc in active
  end

  defp kind_dispatchable?(issue, state_lc, settings) do
    case Map.get(issue, :kind) do
      "draft_issue" -> not blocked_for_state?(issue, state_lc, settings)
      _ -> open_for_dispatch?(issue, state_lc, settings)
    end
  end

  defp open_for_dispatch?(issue, state_lc, settings) do
    Map.get(issue, :issue_state) == "OPEN" and not blocked_for_state?(issue, state_lc, settings)
  end

  defp blocked_for_state?(issue, state_lc, tracker_settings) do
    gating =
      Enum.map(Map.get(tracker_settings, :dependency_gating_states, []) || [], &String.downcase/1)

    cond do
      gating == [] -> false
      state_lc not in gating -> false
      Enum.empty?(open_blockers(issue, tracker_settings)) -> false
      true -> true
    end
  end

  defp open_blockers(issue, tracker_settings) do
    # SPEC §8.2.1: a blocker is resolved iff state == CLOSED. Anything else
    # (OPEN, nil, future enum) keeps it unresolved — fail loud, not soft.
    for b <- Map.get(issue, :blocked_by, []) || [],
        Map.get(b, :state) != "CLOSED",
        honor_blocker?(b, issue, tracker_settings),
        do: b
  end

  defp honor_blocker?(_blocker, _issue, %{cross_repo_blockers: true}), do: true

  defp honor_blocker?(%{identifier: identifier}, %{repository: %{name_with_owner: nwo}}, _settings)
       when is_binary(identifier) and is_binary(nwo) do
    case String.split(identifier, "#") do
      [b_repo, _num] -> String.downcase(b_repo) == String.downcase(nwo)
      # Draft blocker (`draft:<short>`) or malformed: cannot prove same-repo,
      # so DROP under cross_repo_blockers: false.
      _ -> false
    end
  end

  defp honor_blocker?(_blocker, _issue, _tracker_settings), do: false

  @doc false
  # SPEC §11.2.1 + §8.5 Part B reconciliation. Refresh results carry sentinel
  # state values `<no status>` / `<closed>` / `<merged>` emitted by the GitHub
  # Project v2 adapter when the Status field has no value or the underlying
  # issue/PR is terminal.
  #
  # Returns the updated orchestrator state. Termination (when warranted) goes
  # through `terminate_running_issue/4`, which is the single §13.1 worker-stop
  # log site.
  @spec reconcile_running({String.t(), map()}, [map()], map(), State.t()) :: State.t()
  def reconcile_running({issue_id, running_entry}, refresh_results, tracker_settings, %State{} = state) do
    refresh_results
    |> Enum.find(&(refresh_id(&1) == issue_id))
    |> classify_refresh(running_entry, tracker_settings)
    |> apply_reconcile_decision(state, issue_id, running_entry)
  end

  defp classify_refresh(nil, _running_entry, _settings), do: {:stop, :reconciled_missing, false}

  defp classify_refresh(%{state: "<no status>"}, _running_entry, _settings), do: :keep

  defp classify_refresh(%{state: "<closed>"}, _running_entry, _settings),
    do: {:stop, :terminal_or_closed, true}

  defp classify_refresh(%{state: "<merged>"}, _running_entry, _settings),
    do: {:stop, :terminal_or_merged, true}

  defp classify_refresh(%{state: state} = result, running_entry, settings) do
    state_lc = String.downcase(state || "")

    cond do
      state_lc in Enum.map(settings.terminal_states || [], &String.downcase/1) ->
        {:stop, :terminal_state, true}

      state_lc not in Enum.map(settings.active_states || [], &String.downcase/1) ->
        {:stop, :inactive_state, false}

      Map.get(settings, :gate_running_on_dependencies, false) and
          any_blockers_reopened?(running_entry, [result]) ->
        {:stop, :dependencies_reopened, false}

      true ->
        {:keep, result}
    end
  end

  defp classify_refresh(_other, _running_entry, _settings), do: :keep

  defp apply_reconcile_decision(:keep, %State{} = state, _issue_id, _running_entry), do: state

  defp apply_reconcile_decision({:keep, refresh_result}, %State{} = state, issue_id, _running_entry),
    do: refresh_running_entry(state, issue_id, refresh_result)

  defp apply_reconcile_decision({:stop, reason, cleanup_workspace}, %State{} = state, issue_id, _running_entry),
    do: terminate_running_issue(state, issue_id, cleanup_workspace, reason)

  # Sync the running entry's snapshot fields with the latest refresh data so a
  # subsequent reconcile tick can detect blocker transitions correctly.
  defp refresh_running_entry(%State{} = state, issue_id, %{} = refresh_result) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      running_entry ->
        updated =
          running_entry
          |> maybe_put_runtime_value(:last_refresh_state, Map.get(refresh_result, :state))
          |> maybe_refresh_blocked_by_snapshot(Map.get(refresh_result, :blocked_by))

        %{state | running: Map.put(state.running, issue_id, updated)}
    end
  end

  defp maybe_refresh_blocked_by_snapshot(running_entry, nil), do: running_entry

  defp maybe_refresh_blocked_by_snapshot(running_entry, blocked_by) when is_list(blocked_by) do
    Map.put(running_entry, :blocked_by_snapshot, blocked_by)
  end

  defp refresh_id(%{id: id}), do: id
  defp refresh_id(_), do: nil

  defp any_blockers_reopened?(running_entry, refresh_results) do
    case Enum.find(refresh_results, &(refresh_id(&1) == Map.get(running_entry, :issue_id))) do
      %{blocked_by: current} when is_list(current) ->
        snapshot = Map.get(running_entry, :blocked_by_snapshot, []) || []
        previously_all_closed? = Enum.all?(snapshot, &(Map.get(&1, :state) == "CLOSED"))
        now_any_open? = Enum.any?(current, &(Map.get(&1, :state) != "CLOSED"))
        previously_all_closed? and now_any_open?

      _ ->
        false
    end
  end

  defp state_slots_available?(issue, running) when is_map(issue) and is_map(running) do
    case Map.get(issue, :state) do
      issue_state when is_binary(issue_state) ->
        limit = Config.max_concurrent_agents_for_state(issue_state)
        used = running_issue_count_for_state(running, issue_state)
        limit > used

      _ ->
        false
    end
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %{state: state_name}}} when is_binary(state_name) ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    tracker_settings = Config.settings!().tracker

    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           tracker_settings
         ) do
      {:ok, refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %{state: refresh_state}} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(issue)} refresh_state=#{inspect(refresh_state)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    last_run_completed_at = head_completed_at(state.completed, issue.id)
    started_at = DateTime.utc_now()
    dispatched_at = DateTime.to_iso8601(started_at)
    model = codex_model_snapshot()
    # Belt-and-braces: `prune_sessions/1` already caps at `max_sessions/0` on
    # every write, but a future write path that bypassed pruning would let
    # the agent's prompt grow unbounded. Apply the same cap on read.
    prior_sessions = state.completed |> Map.get(issue.id, []) |> Enum.take(max_sessions())

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             last_run_completed_at: last_run_completed_at,
             prior_sessions: prior_sessions,
             dispatched_at: dispatched_at,
             model: model
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            blocked_by_snapshot: Map.get(issue, :blocked_by, []) || [],
            started_at: started_at,
            dispatched_at: dispatched_at,
            thread_id: nil,
            model: model
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  # `issue` here is the full Issue struct that came from the candidate poll;
  # the fetcher returns refresh-result maps (`%{id, identifier, state,
  # blocked_by}`) emitted by Tracker.fetch_issue_states_by_ids/1.
  #
  # We classify the refresh result through the same `classify_refresh/3` lens
  # `reconcile_running/4` uses — if the refresh says the item is still active,
  # dispatch the original Issue struct; otherwise skip.
  defp revalidate_issue_for_dispatch(issue, issue_fetcher, tracker_settings)
       when is_map(issue) and is_function(issue_fetcher, 1) do
    case Map.get(issue, :id) do
      issue_id when is_binary(issue_id) ->
        do_revalidate_issue_for_dispatch(issue, issue_id, issue_fetcher, tracker_settings)

      _ ->
        {:ok, issue}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _tracker_settings), do: {:ok, issue}

  defp do_revalidate_issue_for_dispatch(issue, issue_id, issue_fetcher, tracker_settings) do
    case issue_fetcher.([issue_id]) do
      {:ok, []} ->
        {:skip, :missing}

      {:ok, results} when is_list(results) ->
        classify_revalidation(results, issue, tracker_settings)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_revalidation(results, issue, tracker_settings) do
    issue_id = Map.get(issue, :id)
    refresh = Enum.find(results, &(refresh_id(&1) == issue_id))

    case classify_refresh(refresh, issue, tracker_settings) do
      :keep -> {:ok, issue}
      {:keep, _result} -> {:ok, issue}
      {:stop, _reason, _cleanup} -> {:skip, refresh || %{state: nil}}
    end
  end

  # SPEC §11.8.5: append the latest session record to the per-issue list
  # (most-recent-first), prune to `max_sessions/0`, and drop any pending retry.
  # The running entry carries the fields we need to back-fill `dispatched_at`,
  # `thread_id`, `model`, and the dispatch attempt; `Map.get/3` shields against
  # legacy callers that built running entries without the §11.8.5 keys.
  @spec complete_issue(State.t(), String.t(), State.running_entry(), atom() | nil) :: State.t()
  defp complete_issue(%State{} = state, issue_id, running_entry, stop_reason)
       when is_binary(issue_id) and is_map(running_entry) do
    completed_at = DateTime.utc_now() |> DateTime.to_iso8601()
    record = running_entry |> build_session_record(completed_at, stop_reason) |> Map.put(:issue_id, issue_id)
    prior = Map.get(state.completed, issue_id, [])
    pruned = prune_sessions([record | prior])

    %{
      state
      | completed: Map.put(state.completed, issue_id, pruned),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp build_session_record(running_entry, completed_at, stop_reason)
       when is_map(running_entry) do
    %{
      thread_id: Map.get(running_entry, :thread_id),
      attempt: Map.get(running_entry, :retry_attempt, 0),
      identifier: Map.get(running_entry, :identifier) || Map.get(running_entry, :issue_identifier),
      dispatched_at: Map.get(running_entry, :dispatched_at, completed_at),
      completed_at: completed_at,
      duration_ms: duration_ms_for(running_entry),
      model: Map.get(running_entry, :model),
      codex_input_tokens: Map.get(running_entry, :codex_input_tokens, 0),
      codex_output_tokens: Map.get(running_entry, :codex_output_tokens, 0),
      codex_total_tokens: Map.get(running_entry, :codex_total_tokens, 0),
      stop_reason: stop_reason
    }
  end

  defp duration_ms_for(%{started_at: %DateTime{} = started_at}) do
    DateTime.utc_now() |> DateTime.diff(started_at, :millisecond) |> max(0)
  end

  defp duration_ms_for(_), do: 0

  defp prune_sessions(records) when is_list(records), do: Enum.take(records, max_sessions())

  defp max_sessions, do: Config.settings!().agent.workpad.max_sessions_visible

  # Returns the head (most-recent) `:completed_at` for the issue, or nil if
  # no prior session exists. Replaces the old `get_in/2` on a single-record
  # map shape — same observable result for back-compat with PromptBuilder.
  defp head_completed_at(completed, issue_id) when is_map(completed) and is_binary(issue_id) do
    case Map.get(completed, issue_id) do
      [%{completed_at: ts} | _] -> ts
      _ -> nil
    end
  end

  # Snapshot the codex model setting at dispatch time. `codex.model` is
  # OPTIONAL (SPEC §11.8.5); operators SHOULD set it explicitly when running
  # under §11.8 so the workpad sessions table records the same identifier
  # the agent self-reports. Returns nil when unset.
  defp codex_model_snapshot, do: Config.settings!().codex.model

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    _ =
      if is_reference(old_timer) do
        Process.cancel_timer(old_timer)
      end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    tracker_settings = Config.settings!().tracker
    terminal = Enum.map(tracker_settings.terminal_states || [], &String.downcase/1)
    state_lc = String.downcase(Map.get(issue, :state) || "")

    cond do
      state_lc in terminal or Map.get(issue, :issue_state) in ["CLOSED", "MERGED"] ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      dispatchable?(issue, tracker_settings) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    tracker_settings = Config.settings!().tracker

    if dispatchable?(issue, tracker_settings) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

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

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  defp server_available?(server) when is_atom(server), do: Process.whereis(server)
  defp server_available?(server) when is_pid(server), do: Process.alive?(server)
  defp server_available?(_server), do: false

  @spec completed_sessions_for(String.t()) :: [State.session_record()] | :timeout | :unavailable
  def completed_sessions_for(identifier), do: completed_sessions_for(identifier, __MODULE__, 5_000)

  @spec completed_sessions_for(String.t(), GenServer.server(), timeout()) ::
          [State.session_record()] | :timeout | :unavailable
  def completed_sessions_for(identifier, server, timeout \\ 5_000) when is_binary(identifier) do
    if server_available?(server) do
      try do
        GenServer.call(server, {:completed_sessions_for, identifier}, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @spec completed_sessions() :: [State.session_record()] | :timeout | :unavailable
  def completed_sessions, do: completed_sessions(__MODULE__, 5_000)

  @spec completed_sessions(GenServer.server(), timeout()) ::
          [State.session_record()] | :timeout | :unavailable
  def completed_sessions(server, timeout \\ 5_000) do
    if server_available?(server) do
      try do
        GenServer.call(server, :completed_sessions, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          kind: Map.get(metadata.issue, :kind),
          title: Map.get(metadata.issue, :title),
          content_id: Map.get(metadata.issue, :content_id),
          url: Map.get(metadata.issue, :url),
          number: Map.get(metadata.issue, :number),
          repository: Map.get(metadata.issue, :repository),
          branch_name: Map.get(metadata.issue, :branch_name),
          pr: Map.get(metadata.issue, :pr),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          dispatched_at: Map.get(metadata, :dispatched_at),
          thread_id: Map.get(metadata, :thread_id),
          model: Map.get(metadata, :model),
          retry_attempt: Map.get(metadata, :retry_attempt),
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:completed_sessions, _from, %State{} = state) do
    sessions =
      state.completed
      |> Map.values()
      |> List.flatten()
      |> Enum.sort_by(&Map.get(&1, :completed_at, ""), :desc)
      |> Enum.take(max_sessions())

    {:reply, sessions, state}
  end

  def handle_call({:completed_sessions_for, identifier}, _from, %State{} = state)
      when is_binary(identifier) do
    sessions =
      state.completed
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(Map.get(&1, :identifier) == identifier))
      |> Enum.sort_by(&Map.get(&1, :completed_at, ""), :desc)
      |> Enum.take(max_sessions())

    {:reply, sessions, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    _ =
      if is_reference(state.tick_timer_ref) do
        Process.cancel_timer(state.tick_timer_ref)
      end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    _ = :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp dispatch_slots_available?(issue, %State{} = state) when is_map(issue) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    input = compute_token_delta(running_entry, :input, usage, :codex_last_reported_input_tokens)
    output = compute_token_delta(running_entry, :output, usage, :codex_last_reported_output_tokens)
    total = compute_token_delta(running_entry, :total, usage, :codex_last_reported_total_tokens)

    %{
      input_tokens: input.delta,
      output_tokens: output.delta,
      total_tokens: total.delta,
      input_reported: input.reported,
      output_reported: output.reported,
      total_reported: total.reported
    }
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
