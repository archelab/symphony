defmodule SymphonyElixir.PresenterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.Presenter

  defmodule PresenterOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:completed_sessions, _from, state) do
      completed =
        state
        |> Keyword.fetch!(:completed)
        |> Map.values()
        |> List.flatten()

      {:reply, completed, state}
    end

    def handle_call({:completed_sessions_for, identifier}, _from, state) do
      {:reply, state |> Keyword.fetch!(:completed) |> Map.get(identifier, []), state}
    end
  end

  test "state_payload projects recent completed sessions" do
    orchestrator_name = Module.concat(__MODULE__, :StatePayloadOrchestrator)

    start_presenter_orchestrator!(orchestrator_name)

    payload = Presenter.state_payload(orchestrator_name, 50)

    assert payload.counts == %{running: 1, retrying: 1, completed: 1}

    assert [
             %{
               issue_identifier: "archelab/symphony#125",
               issue_id: "issue-125",
               thread_id: "thread-125",
               attempt: 2,
               model: "gpt-5.5",
               stop_reason: "agent_exit_normal",
               tokens: %{input_tokens: 10, output_tokens: 20, total_tokens: 30}
             }
           ] = payload.completed
  end

  test "issue_payload projects detail metadata and timeline" do
    orchestrator_name = Module.concat(__MODULE__, :IssuePayloadOrchestrator)

    start_presenter_orchestrator!(orchestrator_name)

    assert {:ok, payload} =
             Presenter.issue_payload("archelab/symphony#125", orchestrator_name, 50)

    assert payload.status == "running"
    assert payload.issue.title == "Observability UI phase 1"
    assert payload.links.github == "https://github.com/archelab/symphony/issues/125"
    assert payload.links.github_label == "GitHub issue"
    assert payload.links.github_kind == "issue"
    assert payload.session.session_id == "session-125"
    assert payload.session.thread_id == "thread-running"
    assert payload.session.tokens.total_tokens == 3
    assert payload.workpad.current_attempt == 1
    assert payload.timeline_gap.current_projection =~ "latest Codex event"
    assert payload.timeline_gap.next_persistence_step =~ "per-session event rows"

    assert Enum.map(payload.timeline, & &1.event) == [
             "completed",
             "dispatched",
             "agent_started",
             "agent_message"
           ]
  end

  test "issue_payload keeps retry attempt metadata for retry-only issues" do
    orchestrator_name = Module.concat(__MODULE__, :RetryOnlyIssuePayloadOrchestrator)

    start_presenter_orchestrator!(orchestrator_name)

    assert {:ok, payload} =
             Presenter.issue_payload("archelab/symphony#126", orchestrator_name, 50)

    assert payload.status == "retrying"
    assert payload.workpad.current_attempt == 2
    assert payload.attempts.current_retry_attempt == 2
    assert payload.session.dispatched_at == nil
    assert [%{event: "retry_scheduled", message: "boom"}] = payload.timeline
  end

  defp start_presenter_orchestrator!(orchestrator_name) do
    opts = [
      name: orchestrator_name,
      snapshot: snapshot(),
      completed: completed_sessions()
    ]

    start_supervised!({PresenterOrchestrator, opts})
  end

  defp snapshot do
    started_at = ~U[2026-05-13 16:26:00Z]
    last_event_at = ~U[2026-05-13 16:27:00Z]

    %{
      running: [
        %{
          issue_id: "issue-125",
          identifier: "archelab/symphony#125",
          state: "In Progress",
          kind: "issue",
          title: "Observability UI phase 1",
          url: "https://github.com/archelab/symphony/issues/125",
          number: 125,
          repository: %{
            owner: "archelab",
            name: "symphony",
            name_with_owner: "archelab/symphony",
            default_branch: "main"
          },
          branch_name: "observability-ui-phase-1-125",
          pr: nil,
          worker_host: nil,
          workspace_path: "/tmp/workspace",
          session_id: "session-125",
          thread_id: "thread-running",
          model: "gpt-5.5",
          retry_attempt: 1,
          turn_count: 1,
          dispatched_at: "2026-05-13T16:25:53Z",
          started_at: started_at,
          last_codex_timestamp: last_event_at,
          last_codex_event: :agent_message,
          last_codex_message: "working",
          codex_input_tokens: 1,
          codex_output_tokens: 2,
          codex_total_tokens: 3
        }
      ],
      retrying: [
        %{
          issue_id: "issue-126",
          identifier: "archelab/symphony#126",
          attempt: 2,
          due_in_ms: 1_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 4},
      rate_limits: nil
    }
  end

  defp completed_sessions do
    %{
      "archelab/symphony#125" => [
        %{
          issue_id: "issue-125",
          identifier: "archelab/symphony#125",
          thread_id: "thread-125",
          attempt: 2,
          dispatched_at: "2026-05-13T16:20:00Z",
          completed_at: "2026-05-13T16:24:00Z",
          duration_ms: 240_000,
          model: "gpt-5.5",
          codex_input_tokens: 10,
          codex_output_tokens: 20,
          codex_total_tokens: 30,
          stop_reason: :agent_exit_normal
        }
      ]
    }
  end
end
