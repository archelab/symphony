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

  def classify_refresh(%{state: state} = result, running_entry, settings) do
    state_lc = normalize_issue_state(state)

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

  def classify_refresh(_other, _running_entry, _settings), do: :keep

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

  defp refresh_id(%{id: id}), do: id
  defp refresh_id(_), do: nil

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp normalize_issue_state(_state_name), do: ""
end
