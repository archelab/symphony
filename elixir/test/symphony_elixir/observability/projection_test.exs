defmodule SymphonyElixir.Observability.ProjectionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Observability.Projection

  test "state_payload projects counts and running entries from snapshot and completed sessions" do
    generated_at = "2026-05-14T12:00:00Z"

    snapshot = %{
      running: [
        %{
          issue_id: "PVTI_1",
          identifier: "archelab/symphony#1",
          state: "In Progress",
          session_id: "thread-turn",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: %{event: :notification, message: %{"method" => "codex/event/task_started"}},
          last_codex_timestamp: DateTime.utc_now(),
          started_at: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 5,
          codex_total_tokens: 15
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 10, output_tokens: 5, total_tokens: 15, seconds_running: 1},
      rate_limits: nil
    }

    completed = []

    payload = Projection.state_payload(snapshot, completed, generated_at)

    assert payload.counts == %{running: 1, retrying: 0, completed: 0}
    assert [%{issue_identifier: "archelab/symphony#1", last_message: "task started"}] = payload.running
  end

  test "issue_payload returns completed status when only completed sessions exist" do
    completed = [
      %{
        issue_id: "PVTI_1",
        identifier: "archelab/symphony#1",
        kind: "pull_request",
        title: "Runtime split",
        content_id: "PR_1",
        state: "Done",
        url: "https://github.com/archelab/symphony/pull/1",
        number: 1,
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        branch_name: "runtime-split",
        pr: %{state: "MERGED", merged: true, merged_at: "2026-05-14T10:01:00Z"},
        thread_id: "thread",
        attempt: 1,
        dispatched_at: "2026-05-14T10:00:00Z",
        completed_at: "2026-05-14T10:01:00Z",
        duration_ms: 60_000,
        model: "gpt-5.5",
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        stop_reason: :agent_exit_normal
      }
    ]

    assert {:ok, payload} =
             Projection.issue_payload("archelab/symphony#1", [], [], completed, workspace_root: "/tmp/symphony-workspaces")

    assert payload.status == "completed"
    assert payload.issue_id == "PVTI_1"
    assert payload.issue.state == "completed"
    assert payload.issue.tracker_state == "Done"
    assert payload.issue.title == "Runtime split"
    assert payload.issue.repository.name_with_owner == "archelab/symphony"
    assert payload.issue.pr.merged == true
    assert payload.links.github == "https://github.com/archelab/symphony/pull/1"
    assert payload.links.github_label == "GitHub PR"
  end

  test "issue_payload projects running pull request metadata, links, timeline, and recent events" do
    now = DateTime.utc_now()

    running = [
      %{
        issue_id: "PVTI_2",
        identifier: "archelab/symphony#2",
        kind: "pull_request",
        title: "Runtime split",
        content_id: "PR_2",
        state: "In Progress",
        number: 2,
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        branch_name: "feature",
        pr: %{state: "OPEN", merged: false, merged_at: nil, closed_at: nil, is_draft: false, base_ref_name: "main"},
        url: "https://github.com/archelab/symphony/pull/2",
        worker_host: "host-a",
        workspace_path: "/tmp/workspace",
        session_id: "session",
        thread_id: "thread",
        model: "gpt-5.4-mini",
        retry_attempt: 1,
        dispatched_at: "2026-05-14T10:00:00Z",
        started_at: now,
        last_codex_event: :notification,
        last_codex_message: %{event: :notification, message: %{"method" => "turn/cancelled"}},
        last_codex_timestamp: now,
        turn_count: 3,
        codex_input_tokens: 1,
        codex_output_tokens: 2,
        codex_total_tokens: 3
      }
    ]

    assert {:ok, payload} = Projection.issue_payload("archelab/symphony#2", running, [], [], workspace_root: "/tmp/root")

    assert payload.status == "running"
    assert payload.links.github_kind == "pull_request"
    assert payload.links.github_label == "GitHub PR"
    assert payload.issue.repository.name_with_owner == "archelab/symphony"
    assert payload.issue.pr.base_ref_name == "main"
    assert payload.workspace.path == "/tmp/workspace"

    assert payload.recent_events == [
             %{
               at: DateTime.truncate(now, :second) |> DateTime.to_iso8601(),
               event: :notification,
               message: "turn cancelled"
             }
           ]
  end

  test "issue_payload projects retry-only issues and missing issues" do
    retry = [
      %{
        issue_id: "PVTI_3",
        identifier: "archelab/symphony#3",
        attempt: 2,
        due_in_ms: 1_000,
        error: "crashed",
        worker_host: "host-b",
        workspace_path: "/tmp/retry",
        model: "gpt-5.4-mini",
        dispatched_at: "2026-05-14T10:00:00Z"
      }
    ]

    assert {:ok, payload} = Projection.issue_payload("archelab/symphony#3", [], retry, [], workspace_root: "/tmp/root")

    assert payload.status == "retrying"
    assert payload.attempts.restart_count == 1
    assert payload.workspace.host == "host-b"
    assert payload.last_error == "crashed"
    assert payload.links.github == "https://github.com/archelab/symphony/issues/3"

    assert Projection.issue_payload("archelab/symphony#404", [], [], [], workspace_root: "/tmp/root") ==
             {:error, :issue_not_found}
  end

  test "issue_payload handles running plus retry, completed fallbacks, nil messages, and non-atom stop reasons" do
    running = [
      %{
        issue_id: "PVTI_4",
        identifier: "archelab/symphony#4",
        kind: "issue",
        title: "Both states",
        content_id: "I_4",
        state: "In Progress",
        number: 4,
        repository: nil,
        branch_name: nil,
        pr: nil,
        url: nil,
        worker_host: nil,
        workspace_path: nil,
        session_id: "session",
        thread_id: "thread",
        model: "gpt-5.4-mini",
        retry_attempt: 3,
        dispatched_at: "2026-05-14T10:00:00Z",
        started_at: nil,
        last_codex_event: nil,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        turn_count: 0,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0
      }
    ]

    retry = [
      %{issue_id: "PVTI_4", identifier: "archelab/symphony#4", attempt: nil, due_in_ms: nil, error: nil}
    ]

    completed = [
      %{
        issue_id: "PVTI_4",
        identifier: "archelab/symphony#4",
        completed_at: "2026-05-14T11:00:00Z",
        stop_reason: "manual",
        codex_input_tokens: 5,
        codex_output_tokens: 6,
        codex_total_tokens: 11
      }
    ]

    assert {:ok, payload} =
             Projection.issue_payload("archelab/symphony#4", running, retry, completed, workspace_root: "/tmp/root")

    assert payload.status == "running"
    assert payload.recent_events == []
    assert payload.retry.due_at == nil

    assert payload.completed == [
             %{
               issue_id: "PVTI_4",
               issue_identifier: "archelab/symphony#4",
               thread_id: nil,
               attempt: nil,
               dispatched_at: nil,
               completed_at: "2026-05-14T11:00:00Z",
               duration_ms: nil,
               model: nil,
               tokens: %{input_tokens: 5, output_tokens: 6, total_tokens: 11},
               stop_reason: "manual"
             }
           ]

    assert {:ok, payload} =
             Projection.issue_payload("archelab/symphony#5", [], [], [%{}], workspace_root: "/tmp/root")

    assert payload.issue_id == nil
  end
end
