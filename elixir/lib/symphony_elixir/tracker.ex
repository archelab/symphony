defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads. Per spec §11.5 the orchestrator
  performs no writes; comments and Status updates are agent-driven via the
  github_graphql Codex tool.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: adapter().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: adapter().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: adapter().fetch_issue_states_by_ids(issue_ids)

  @spec adapter() :: module()
  def adapter, do: adapter_for(Config.settings!().tracker.kind)

  @doc false
  @spec adapter_for(String.t()) :: module()
  def adapter_for("memory"), do: SymphonyElixir.Tracker.Memory
  def adapter_for("github"), do: SymphonyElixir.Github.Adapter

  def adapter_for(other),
    do: raise(ArgumentError, "unsupported tracker kind: #{inspect(other)}")
end
