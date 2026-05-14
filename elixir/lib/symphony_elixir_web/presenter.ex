defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.Observability.Projection

  @type state_payload :: %{
          required(:generated_at) => binary(),
          optional(:counts) => %{
            running: non_neg_integer(),
            retrying: non_neg_integer(),
            completed: non_neg_integer()
          },
          optional(:running) => [map()],
          optional(:retrying) => [map()],
          optional(:completed) => [map()],
          optional(:codex_totals) => term(),
          optional(:rate_limits) => term(),
          optional(:error) => %{code: binary(), message: binary()}
        }

  @spec state_payload(atom(), timeout()) :: state_payload()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        completed = completed_sessions(orchestrator, snapshot_timeout_ms)

        Projection.state_payload(snapshot, completed, generated_at)

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @type issue_body :: %{
          :attempts => map(),
          :issue_id => term(),
          :issue_identifier => binary(),
          :issue => map(),
          :last_error => term(),
          :links => map(),
          :logs => map(),
          :completed => [map()],
          :recent_events => nil | [map()],
          :retry => nil | map(),
          :running => nil | map(),
          :session => map(),
          :status => binary(),
          :timeline => [map()],
          :timeline_gap => map(),
          :tracked => map(),
          :workpad => map(),
          :workspace => map()
        }

  @spec issue_payload(String.t(), atom(), timeout()) ::
          {:ok, issue_body()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        completed = completed_sessions(issue_identifier, orchestrator, snapshot_timeout_ms)

        Projection.issue_payload(issue_identifier, snapshot.running, snapshot.retrying, completed, workspace_root: Config.settings!().workspace.root)

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp completed_sessions(orchestrator, timeout_ms) do
    case Orchestrator.completed_sessions(orchestrator, timeout_ms) do
      sessions when is_list(sessions) -> sessions
      _ -> []
    end
  end

  defp completed_sessions(issue_identifier, orchestrator, timeout_ms) do
    case Orchestrator.completed_sessions_for(issue_identifier, orchestrator, timeout_ms) do
      sessions when is_list(sessions) -> sessions
      _ -> []
    end
  end
end
