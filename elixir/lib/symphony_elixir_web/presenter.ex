defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Workspace}

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

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            completed: length(completed)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          completed: Enum.map(completed, &completed_session_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

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
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        completed = completed_sessions(issue_identifier, orchestrator, snapshot_timeout_ms)

        if is_nil(running) and is_nil(retry) and completed == [] do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, completed)}
        end

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

  defp issue_payload_body(issue_identifier, running, retry, completed) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, completed),
      status: issue_status(running, retry, completed),
      issue: issue_metadata(running, completed),
      links: links_payload(issue_identifier, running),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      completed: Enum.map(completed, &completed_session_payload/1),
      session: session_metadata(running, retry, completed),
      workpad: workpad_metadata(running, retry, completed),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      timeline: timeline_payload(running, retry, completed),
      timeline_gap: timeline_gap_payload(),
      last_error: retry && retry.error,
      tracked: %{}
    }
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

  defp issue_id_from_entries(running, retry, completed),
    do: (running && running.issue_id) || (retry && retry.issue_id) || completed_issue_id(completed)

  defp completed_issue_id([%{issue_id: issue_id} | _]), do: issue_id
  defp completed_issue_id(_completed), do: nil

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(nil, nil, [_ | _]), do: "completed"
  defp issue_status(_running, nil, _completed), do: "running"
  defp issue_status(nil, _retry, _completed), do: "retrying"
  defp issue_status(_running, _retry, _completed), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp completed_session_payload(record) do
    %{
      issue_id: Map.get(record, :issue_id),
      issue_identifier: Map.get(record, :identifier),
      thread_id: Map.get(record, :thread_id),
      attempt: Map.get(record, :attempt),
      dispatched_at: Map.get(record, :dispatched_at),
      completed_at: Map.get(record, :completed_at),
      duration_ms: Map.get(record, :duration_ms),
      model: Map.get(record, :model),
      tokens: %{
        input_tokens: Map.get(record, :codex_input_tokens, 0),
        output_tokens: Map.get(record, :codex_output_tokens, 0),
        total_tokens: Map.get(record, :codex_total_tokens, 0)
      },
      stop_reason: stringify_atom(Map.get(record, :stop_reason))
    }
  end

  defp issue_metadata(nil, []), do: %{}

  defp issue_metadata(running, _completed) when is_map(running) do
    %{
      kind: Map.get(running, :kind),
      title: Map.get(running, :title),
      content_id: Map.get(running, :content_id),
      state: Map.get(running, :state),
      number: Map.get(running, :number),
      repository: repository_payload(Map.get(running, :repository)),
      branch_name: Map.get(running, :branch_name),
      pr: pr_payload(Map.get(running, :pr))
    }
  end

  defp issue_metadata(_running, [%{} = completed | _]) do
    %{
      state: "completed",
      repository: nil,
      pr: nil,
      title: nil,
      kind: nil,
      number: nil,
      branch_name: nil,
      content_id: nil,
      issue_id: Map.get(completed, :issue_id),
      issue_identifier: Map.get(completed, :identifier)
    }
  end

  defp repository_payload(nil), do: nil

  defp repository_payload(repo) when is_map(repo) do
    %{
      owner: Map.get(repo, :owner),
      name: Map.get(repo, :name),
      name_with_owner: Map.get(repo, :name_with_owner),
      default_branch: Map.get(repo, :default_branch)
    }
  end

  defp pr_payload(nil), do: nil

  defp pr_payload(pr) when is_map(pr) do
    %{
      state: Map.get(pr, :state),
      merged: Map.get(pr, :merged),
      merged_at: Map.get(pr, :merged_at),
      closed_at: Map.get(pr, :closed_at),
      is_draft: Map.get(pr, :is_draft),
      base_ref_name: Map.get(pr, :base_ref_name)
    }
  end

  defp links_payload(issue_identifier, running) do
    github_url = (running && Map.get(running, :url)) || github_url_from_identifier(issue_identifier)
    github_kind = github_link_kind(running)

    %{
      github: github_url,
      github_label: github_link_label(github_kind),
      github_kind: github_kind,
      api: "/api/v1/#{URI.encode_www_form(issue_identifier)}"
    }
  end

  defp github_link_kind(%{kind: "pull_request"}), do: "pull_request"
  defp github_link_kind(_running), do: "issue"

  defp github_link_label("pull_request"), do: "GitHub PR"
  defp github_link_label(_kind), do: "GitHub issue"

  defp github_url_from_identifier(identifier) when is_binary(identifier) do
    case Regex.run(~r/^([^#]+)#(\d+)$/, identifier) do
      [_, repo, number] -> "https://github.com/#{repo}/issues/#{number}"
      _ -> nil
    end
  end

  defp session_metadata(running, retry, completed) do
    latest_completed = List.first(completed)
    sources = [running, retry, latest_completed]

    %{
      session_id: first_present(sources, :session_id),
      thread_id: first_present(sources, :thread_id),
      model: first_present(sources, :model),
      started_at: running_started_at(running),
      dispatched_at: first_present(sources, :dispatched_at),
      completed_at: latest_completed && Map.get(latest_completed, :completed_at),
      stop_reason: latest_completed_stop_reason(latest_completed),
      tokens: tokens_payload(sources)
    }
  end

  defp workpad_metadata(running, retry, completed) do
    latest_completed = List.first(completed)
    sources = [running, retry, latest_completed]

    %{
      prior_sessions: length(completed),
      current_attempt: first_present(sources, :retry_attempt) || first_present(sources, :attempt) || 0,
      latest_dispatched_at: first_present(sources, :dispatched_at),
      latest_thread_id: first_present(sources, :thread_id)
    }
  end

  defp timeline_payload(running, retry, completed) do
    (running_timeline(running) ++ retry_timeline(retry) ++ completed_timeline(completed))
    |> Enum.sort_by(&(&1.at || ""))
  end

  defp timeline_gap_payload do
    %{
      current_projection: "Runtime state retains dispatch, process start, latest Codex event, retry schedule, and completion records.",
      next_persistence_step: "Persist per-session event rows from Codex updates and orchestrator transitions, then project them by issue/session in timestamp order."
    }
  end

  defp first_present(sources, key) do
    Enum.find_value(sources, fn
      source when is_map(source) -> Map.get(source, key)
      _source -> nil
    end)
  end

  defp running_started_at(running) when is_map(running), do: iso8601(Map.get(running, :started_at))
  defp running_started_at(_running), do: nil

  defp latest_completed_stop_reason(nil), do: nil

  defp latest_completed_stop_reason(completed) when is_map(completed) do
    completed
    |> Map.get(:stop_reason)
    |> stringify_atom()
  end

  defp tokens_payload(sources) do
    %{
      input_tokens: first_present(sources, :codex_input_tokens) || 0,
      output_tokens: first_present(sources, :codex_output_tokens) || 0,
      total_tokens: first_present(sources, :codex_total_tokens) || 0
    }
  end

  defp running_timeline(nil), do: []

  defp running_timeline(running) when is_map(running) do
    []
    |> maybe_add_timeline_event(Map.get(running, :dispatched_at), "dispatched", "Agent dispatch recorded")
    |> maybe_add_timeline_event(iso8601(Map.get(running, :started_at)), "agent_started", "Agent process started")
    |> maybe_add_timeline_event(
      iso8601(Map.get(running, :last_codex_timestamp)),
      to_string(Map.get(running, :last_codex_event) || "codex_event"),
      summarize_message(Map.get(running, :last_codex_message))
    )
  end

  defp retry_timeline(nil), do: []

  defp retry_timeline(retry) when is_map(retry) do
    maybe_add_timeline_event(
      [],
      due_at_iso8601(Map.get(retry, :due_in_ms)),
      "retry_scheduled",
      Map.get(retry, :error)
    )
  end

  defp completed_timeline(completed) do
    Enum.reduce(completed, [], fn record, acc ->
      message =
        record
        |> Map.get(:stop_reason)
        |> stringify_atom()

      maybe_add_timeline_event(acc, Map.get(record, :completed_at), "completed", message)
    end)
  end

  defp maybe_add_timeline_event(events, at, event, message)
       when is_binary(at) and is_binary(event) do
    [%{at: at, event: event, message: message} | events]
  end

  defp maybe_add_timeline_event(events, _at, _event, _message), do: events

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, Workspace.workspace_key(issue_identifier))
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp stringify_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atom(value), do: value

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
