defmodule SymphonyElixir.Orchestrator.SessionHistory do
  @moduledoc """
  Builds and prunes completed-session history for orchestrator state.
  """

  @type session_record :: map()

  @spec record_completion(map(), String.t(), map(), atom() | nil, keyword()) :: map()
  def record_completion(completed, issue_id, running_entry, stop_reason, opts)
      when is_map(completed) and is_binary(issue_id) and is_map(running_entry) do
    completed_at = DateTime.utc_now() |> DateTime.to_iso8601()

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

  @spec build_record(map(), String.t(), atom() | nil) :: session_record()
  def build_record(running_entry, completed_at, stop_reason)
      when is_map(running_entry) and is_binary(completed_at) do
    %{
      thread_id: Map.get(running_entry, :thread_id),
      issue_id: Map.get(running_entry, :issue_id),
      attempt: Map.get(running_entry, :retry_attempt, 0),
      identifier: Map.get(running_entry, :identifier) || Map.get(running_entry, :issue_identifier),
      kind: issue_field(running_entry, :kind),
      title: issue_field(running_entry, :title),
      content_id: issue_field(running_entry, :content_id),
      state: issue_field(running_entry, :state),
      url: issue_field(running_entry, :url),
      number: issue_field(running_entry, :number),
      repository: issue_field(running_entry, :repository),
      branch_name: issue_field(running_entry, :branch_name),
      pr: issue_field(running_entry, :pr),
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

  defp issue_field(running_entry, field) do
    case Map.get(running_entry, :issue) do
      issue when is_map(issue) -> Map.get(issue, field)
      _ -> Map.get(running_entry, field)
    end
  end

  @spec head_completed_at(map(), String.t()) :: String.t() | nil
  def head_completed_at(completed, issue_id) when is_map(completed) and is_binary(issue_id) do
    case Map.get(completed, issue_id) do
      [%{completed_at: completed_at} | _] -> completed_at
      _ -> nil
    end
  end

  defp duration_ms_for(%{started_at: %DateTime{} = started_at}) do
    DateTime.utc_now() |> DateTime.diff(started_at, :millisecond) |> max(0)
  end

  defp duration_ms_for(_running_entry), do: 0
end
