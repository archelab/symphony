defmodule SymphonyElixir.Orchestrator.DispatchPolicy do
  @moduledoc """
  Pure dispatch and worker-selection decisions for the orchestrator.
  """

  @type dispatch_state :: %{required(:claimed) => term(), required(:running) => term(), optional(atom()) => term()}
  @type slot_state :: %{
          required(:max_concurrent_agents) => number() | false | nil,
          required(:running) => map(),
          optional(atom()) => term()
        }

  @spec sort_issues_for_dispatch([term()]) :: [term()]
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, &dispatch_sort_key/1)
  end

  @spec dispatch_eligible?(map(), dispatch_state(), term(), term()) :: boolean()
  def dispatch_eligible?(issue, %{running: running, claimed: claimed} = state, tracker_settings, runtime_settings) do
    issue_id = Map.get(issue, :id)

    cond do
      !dispatchable?(issue, tracker_settings) -> false
      !is_binary(issue_id) -> false
      MapSet.member?(claimed, issue_id) -> false
      Map.has_key?(running, issue_id) -> false
      available_slots(state, runtime_settings) <= 0 -> false
      !state_slots_available?(issue, running, runtime_settings) -> false
      true -> worker_slots_available?(state, runtime_settings)
    end
  end

  @spec dispatch_slots_available?(map(), slot_state(), term()) :: boolean()
  def dispatch_slots_available?(issue, %{running: running} = state, runtime_settings) when is_map(issue) and is_map(running) do
    available_slots(state, runtime_settings) > 0 and state_slots_available?(issue, running, runtime_settings)
  end

  @spec dispatchable?(map(), term()) :: boolean()
  def dispatchable?(issue, tracker_settings) do
    state_lc = issue |> Map.get(:state) |> normalize_issue_state()

    status_eligible?(state_lc, tracker_settings) and
      kind_dispatchable?(issue, state_lc, tracker_settings)
  end

  @spec select_worker_host(slot_state(), String.t() | nil, term()) :: String.t() | nil | :no_worker_capacity
  def select_worker_host(%{} = state, preferred_worker_host, runtime_settings) do
    case worker_settings(runtime_settings).ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1, runtime_settings))

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

  @spec worker_slots_available?(slot_state(), term()) :: boolean()
  def worker_slots_available?(%{} = state, runtime_settings) do
    select_worker_host(state, nil, runtime_settings) != :no_worker_capacity
  end

  @spec worker_slots_available?(slot_state(), String.t() | nil, term()) :: boolean()
  def worker_slots_available?(%{} = state, preferred_worker_host, runtime_settings) do
    select_worker_host(state, preferred_worker_host, runtime_settings) != :no_worker_capacity
  end

  @spec available_slots(slot_state(), term()) :: number()
  def available_slots(%{} = state, runtime_settings) do
    configured_max = state.max_concurrent_agents || agent_settings(runtime_settings).max_concurrent_agents
    max(configured_max - map_size(state.running), 0)
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
    for blocker <- Map.get(issue, :blocked_by, []) || [],
        Map.get(blocker, :state) != "CLOSED",
        honor_blocker?(blocker, issue, tracker_settings),
        do: blocker
  end

  defp honor_blocker?(_blocker, _issue, %{cross_repo_blockers: true}), do: true

  defp honor_blocker?(%{identifier: identifier}, %{repository: %{name_with_owner: nwo}}, _settings)
       when is_binary(identifier) and is_binary(nwo) do
    case String.split(identifier, "#") do
      [blocker_repo, _number] -> String.downcase(blocker_repo) == String.downcase(nwo)
      _ -> false
    end
  end

  defp honor_blocker?(_blocker, _issue, _tracker_settings), do: false

  defp state_slots_available?(issue, running, runtime_settings) when is_map(issue) and is_map(running) do
    case Map.get(issue, :state) do
      issue_state when is_binary(issue_state) ->
        limit = max_concurrent_agents_for_state(issue_state, runtime_settings)
        used = running_issue_count_for_state(running, issue_state)
        limit > used

      _ ->
        false
    end
  end

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

  defp normalize_issue_state(_state_name), do: ""

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%{} = state, hosts) when is_list(hosts) do
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

  defp worker_host_slots_available?(%{} = state, worker_host, runtime_settings) when is_binary(worker_host) do
    case worker_settings(runtime_settings).max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp max_concurrent_agents_for_state(state_name, runtime_settings) when is_binary(state_name) do
    agent = agent_settings(runtime_settings)

    Map.get(
      agent.max_concurrent_agents_by_state,
      normalize_issue_state(state_name),
      agent.max_concurrent_agents
    )
  end

  defp agent_settings(%{agent: agent}), do: agent
  defp agent_settings(runtime_settings), do: runtime_settings

  defp worker_settings(%{worker: worker}), do: worker
  defp worker_settings(runtime_settings), do: runtime_settings
end
