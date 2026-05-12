defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single GitHub Projects v2 issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Github.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      send_thread_id(codex_update_recipient, issue, session)
      # SPEC §11.8.5: thread_id MUST be captured before the first turn renders so
      # the workpad sessions row references the same id the orchestrator records.
      opts_with_thread = Keyword.put(opts, :thread_id, Map.get(session, :thread_id))

      try do
        case do_run_codex_turns(
               session,
               workspace,
               issue,
               codex_update_recipient,
               opts_with_thread,
               issue_state_fetcher,
               1,
               max_turns
             ) do
          {:wrap_up_requested, signal, wrap_issue} ->
            run_wrap_up_turn(session, workspace, wrap_issue, codex_update_recipient, signal)

          other ->
            other
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  # SPEC §11.8.5: surface the Codex thread id to the orchestrator immediately
  # after `AppServer.start_session/2` returns so the running entry can record
  # it before the first turn runs.
  defp send_thread_id(recipient, %Issue{id: issue_id}, %{thread_id: thread_id})
       when is_pid(recipient) and is_binary(issue_id) and is_binary(thread_id) do
    send(recipient, {:codex_thread_started, issue_id, thread_id})
    :ok
  end

  defp send_thread_id(_recipient, _issue, _session), do: :ok

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    case AppServer.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue)
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_codex_turns(
              app_session,
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, {:wrap_up_requested, signal}} ->
        {:wrap_up_requested, signal, issue}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_wrap_up_turn(app_session, workspace, issue, codex_update_recipient, signal) do
    prompt = wrap_up_prompt(signal)

    Logger.info("Starting graceful wrap-up turn for #{issue_context(issue)} reason=#{inspect(signal.reason)} budget_ms=#{signal.budget_ms}")

    case AppServer.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue)
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed graceful wrap-up turn for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace}")
        :ok

      {:error, reason} ->
        Logger.warning("Graceful wrap-up turn failed for #{issue_context(issue)}: #{inspect(reason)}")
        :ok
    end
  end

  defp wrap_up_prompt(%{reason: reason, budget_ms: budget_ms}) do
    """
    Symphony is terminating this worker.

    Reason: `#{reason}`
    Budget: #{budget_ms} ms

    Do not start new work. If you have not already done so:

    - For `inactive_state` or `dependencies_reopened`, post a `## Blocker report` comment.
    - For terminal-state stops, post `## Reviewer notes` only when useful.
    - Close any open workpad row with the best available stop reason.

    Exit immediately after that final status update.
    """
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [first | _]} ->
        # Accept both Memory's %Issue{} shape and the Github adapter's
        # refresh-result map shape (Tracker.refresh_result). We only need the
        # current Status field value for the continuation decision, but we
        # splice it back onto the ORIGINAL Issue struct so the next prompt
        # render and downstream callers see the latest state on a full Issue.
        refreshed_state = refresh_state(first)
        refreshed_issue = %Issue{issue | state: refreshed_state}

        if active_issue_state?(refreshed_state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp refresh_state(%Issue{state: state}), do: state
  defp refresh_state(%{state: state}) when is_binary(state), do: state

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
