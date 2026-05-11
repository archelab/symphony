defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads. Per spec §11.5 the orchestrator
  performs no writes; comments and Status updates are agent-driven via the
  github_graphql Codex tool.
  """

  alias SymphonyElixir.Config

  @typedoc """
  One blocker in a refresh-result `:blocked_by` list.
  """
  @type blocker :: %{
          id: String.t(),
          identifier: String.t(),
          state: String.t()
        }

  @typedoc """
  Canonical refresh-result shape emitted by `SymphonyElixir.Github.Adapter`
  from `fetch_issue_states_by_ids/1`. The orchestrator's `classify_refresh/3`
  consumes this shape directly.

  NOTE: `SymphonyElixir.Tracker.Memory` currently returns
  `SymphonyElixir.Github.Issue` structs from this callback instead of refresh
  maps. Issue structs carry the same `:id`, `:identifier`, `:state`, and
  `:blocked_by` keys the orchestrator reads, so the dual shape is accepted
  end-to-end — but agent-runner's continuation logic only round-trips Issue
  structs cleanly. Unifying Memory onto this map shape is a follow-up.
  """
  @type refresh_result :: %{
          id: String.t(),
          identifier: String.t(),
          state: String.t(),
          blocked_by: [blocker()]
        }

  @callback fetch_candidate_issues() ::
              {:ok, [SymphonyElixir.Github.Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) ::
              {:ok, [SymphonyElixir.Github.Issue.t()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) ::
              {:ok, [refresh_result() | SymphonyElixir.Github.Issue.t()]} | {:error, term()}

  @spec fetch_candidate_issues() ::
          {:ok, [SymphonyElixir.Github.Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: adapter().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) ::
          {:ok, [SymphonyElixir.Github.Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: adapter().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) ::
          {:ok, [refresh_result() | SymphonyElixir.Github.Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: adapter().fetch_issue_states_by_ids(issue_ids)

  @type adapter_module :: SymphonyElixir.Github.Adapter | SymphonyElixir.Tracker.Memory

  @spec adapter() :: adapter_module()
  def adapter, do: adapter_for(Config.settings!().tracker.kind)

  @doc false
  @spec adapter_for(String.t()) :: adapter_module() | no_return()
  def adapter_for("memory"), do: SymphonyElixir.Tracker.Memory
  def adapter_for("github"), do: SymphonyElixir.Github.Adapter

  def adapter_for(other),
    do: raise(ArgumentError, "unsupported tracker kind: #{inspect(other)}")
end
