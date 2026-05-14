defmodule SymphonyElixir.Orchestrator.SessionHistoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.SessionHistory

  test "build_record captures session metadata and stop reason" do
    started_at = DateTime.add(DateTime.utc_now(), -5, :second)
    completed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    running_entry = %{
      thread_id: "thread-1",
      issue_id: "PVTI_1",
      retry_attempt: 2,
      dispatched_at: "2026-05-14T10:00:00Z",
      identifier: "archelab/symphony#1",
      issue: %{
        kind: "pull_request",
        title: "Runtime split",
        content_id: "PR_1",
        state: "In Review",
        url: "https://github.com/archelab/symphony/pull/1",
        number: 1,
        repository: %{name_with_owner: "archelab/symphony"},
        branch_name: "runtime-split",
        pr: %{state: "OPEN"}
      },
      model: "gpt-5.5",
      codex_input_tokens: 10,
      codex_output_tokens: 5,
      codex_total_tokens: 15,
      started_at: started_at
    }

    record = SessionHistory.build_record(running_entry, completed_at, :agent_exit_normal)

    assert %{
             thread_id: "thread-1",
             issue_id: "PVTI_1",
             kind: "pull_request",
             title: "Runtime split",
             content_id: "PR_1",
             state: "In Review",
             url: "https://github.com/archelab/symphony/pull/1",
             number: 1,
             repository: %{name_with_owner: "archelab/symphony"},
             branch_name: "runtime-split",
             pr: %{state: "OPEN"},
             attempt: 2,
             dispatched_at: "2026-05-14T10:00:00Z",
             completed_at: ^completed_at,
             identifier: "archelab/symphony#1",
             model: "gpt-5.5",
             codex_input_tokens: 10,
             codex_output_tokens: 5,
             codex_total_tokens: 15,
             stop_reason: :agent_exit_normal
           } = record

    assert record.duration_ms >= 0
  end

  test "record_completion prepends and prunes by max session count" do
    completed = %{"PVTI_1" => [%{thread_id: "old-1"}, %{thread_id: "old-2"}]}

    running_entry = %{
      thread_id: "new",
      issue_id: "PVTI_1",
      retry_attempt: 1,
      dispatched_at: "2026-05-14T10:00:00Z",
      identifier: "archelab/symphony#1",
      model: "gpt-5.5",
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: DateTime.utc_now()
    }

    updated =
      SessionHistory.record_completion(completed, "PVTI_1", running_entry, :stall_restart, max_sessions: 2)

    assert [
             %{thread_id: "new", issue_id: "PVTI_1", stop_reason: :stall_restart},
             %{thread_id: "old-1"}
           ] = updated["PVTI_1"]
  end

  test "head_completed_at returns the newest completion timestamp when present" do
    completed = %{
      "PVTI_1" => [
        %{completed_at: "2026-05-14T10:00:00Z"},
        %{completed_at: "2026-05-14T09:00:00Z"}
      ],
      "PVTI_2" => [%{}]
    }

    assert SessionHistory.head_completed_at(completed, "PVTI_1") == "2026-05-14T10:00:00Z"
    assert is_nil(SessionHistory.head_completed_at(completed, "PVTI_2"))
    assert is_nil(SessionHistory.head_completed_at(completed, "PVTI_3"))
  end

  test "build_record falls back when started_at is unavailable" do
    record = SessionHistory.build_record(%{issue_identifier: "archelab/symphony#2"}, "2026-05-14T10:00:00Z", nil)

    assert record.identifier == "archelab/symphony#2"
    assert record.dispatched_at == "2026-05-14T10:00:00Z"
    assert record.duration_ms == 0
  end
end
