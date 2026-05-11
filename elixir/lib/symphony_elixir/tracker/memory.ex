defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.

  Emits `SymphonyElixir.Github.Issue` structs so the predicate pipeline gets
  exactly the same shape it sees in production from the GitHub Projects v2
  adapter. SPEC §11.2.1 terminal-OR is honored here so a CLOSED/MERGED issue
  is ineligible regardless of its Project Status field.
  """

  alias SymphonyElixir.Github.Issue

  @behaviour SymphonyElixir.Tracker

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, Enum.filter(issue_entries(), &candidate?/1)}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  # SPEC §11.2.1: CLOSED/MERGED issue_state ⇒ terminal-OR even if Status active.
  defp candidate?(%Issue{issue_state: issue_state}) when issue_state in ["CLOSED", "MERGED"],
    do: false

  defp candidate?(%Issue{}), do: true

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
