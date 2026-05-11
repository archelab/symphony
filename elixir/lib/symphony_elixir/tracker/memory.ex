defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.

  Backed by a tiny local `Issue` struct rather than `SymphonyElixir.Linear.Issue`
  so PR2 / Task 8b can delete the Linear modules without breaking the memory
  adapter or its tests.
  """

  @behaviour SymphonyElixir.Tracker

  defmodule Issue do
    @moduledoc """
    Minimal in-memory issue record. Field set is intentionally narrow — only
    what the orchestrator-side memory tests assert on (`id`, `identifier`,
    `state`, plus a few common metadata fields). Keep this struct independent
    from `Github.Issue` and `Linear.Issue` so it stays a stable test fixture.
    """

    defstruct [:id, :identifier, :title, :description, :priority, :state]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            identifier: String.t() | nil,
            title: String.t() | nil,
            description: String.t() | nil,
            priority: integer() | nil,
            state: String.t() | nil
          }
  end

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
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

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
