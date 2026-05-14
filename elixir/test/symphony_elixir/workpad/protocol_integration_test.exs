defmodule SymphonyElixir.Workpad.ProtocolIntegrationTest do
  @moduledoc """
  SPEC §17.8 / §11.8 round-trip: a first dispatch produces ONE session record
  in `state.completed`, and the prompt rendered for a subsequent dispatch
  surfaces that record under `prior_sessions[0]`.

  In-memory only — no real GitHub calls. The orchestrator's `:DOWN` handler
  (the §13.1 normal-exit path) is exercised directly, which is the same code
  path a live `agent_exit_normal` takes after `AppServer.start_session/2` has
  populated `running_entry.thread_id`. The "second dispatch" assertion calls
  `PromptBuilder.build_prompt/2` with exactly the keyword opts the
  orchestrator builds at `spawn_issue_on_worker_host/5` (see
  `orchestrator.ex:918-933`).
  """
  use SymphonyElixir.TestSupport

  test "dispatch → session record → re-dispatch prompt surfaces prior_sessions[0]" do
    issue_id = "PVTI_workpad_integration"
    issue_identifier = "archelab/symphony#777"
    content_id = "I_xyz"
    first_thread_id = "thr-first"
    model = "gpt-5.5"

    # 1. WORKFLOW with workpad enabled + a prompt that exposes the workpad
    # variables we want to assert on. Strict-variable mode (the
    # PromptBuilder default) ensures the test fails loudly if the orchestrator
    # omits a variable that the workpad flag is supposed to surface.
    workpad_prompt =
      """
      thread_id={{ thread_id }}
      subject_id={{ subject_id }}
      model={{ model }}
      dispatched_at={{ dispatched_at }}
      prior_sessions_count={{ prior_sessions.size }}
      {% for s in prior_sessions %}prior[{{ forloop.index0 }}].thread_id={{ s.thread_id }}
      prior[{{ forloop.index0 }}].model={{ s.model }}
      prior[{{ forloop.index0 }}].stop_reason={{ s.stop_reason }}
      {% endfor %}
      """

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_workpad_enabled: true,
      codex_model: model,
      prompt: workpad_prompt
    )

    issue =
      Issue.new(%{
        id: issue_id,
        identifier: issue_identifier,
        kind: "issue",
        content_id: content_id,
        title: "workpad round-trip",
        state: "Agent Ready",
        issue_state: "OPEN",
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        number: 777,
        labels: [],
        blocked_by: []
      })

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    # 2. Start the orchestrator.
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if is_nil(previous_memory_issues) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)
      end

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    ref = make_ref()
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill) end)
    started_at = DateTime.utc_now()
    dispatched_at = DateTime.to_iso8601(started_at)

    # 3. Plant a running entry shaped exactly like
    # `spawn_issue_on_worker_host/5` produces, but with thread_id nil — that
    # field is filled in by the `:codex_thread_started` handler once
    # `AppServer.start_session/2` returns.
    running_entry = %{
      pid: worker_pid,
      ref: ref,
      identifier: issue_identifier,
      issue: issue,
      started_at: started_at,
      dispatched_at: dispatched_at,
      thread_id: nil,
      model: model,
      retry_attempt: 0
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    # 3a. Simulate the AgentRunner's post-start_session message that promotes
    # the Codex thread id into the running entry. Direct wire-up test for
    # the `:codex_thread_started` handler in Orchestrator. SPEC §11.8.5
    # requires thread_id be available before the first turn.
    send(pid, {:codex_thread_started, issue_id, first_thread_id})
    Process.sleep(20)

    state_with_thread = :sys.get_state(pid)
    assert %{thread_id: ^first_thread_id} = Map.fetch!(state_with_thread.running, issue_id)

    # 4. Simulate normal worker exit (`:agent_exit_normal` per SPEC §13.1).
    send(pid, {:DOWN, ref, :process, worker_pid, :normal})
    Process.sleep(50)

    state_after_first = :sys.get_state(pid)

    # 5. State.completed[issue_id] now has exactly one session record with the
    # shape SPEC §11.8.5 / §4.1.8 prescribe.
    assert [first_record] = Map.fetch!(state_after_first.completed, issue_id)

    assert %{
             thread_id: ^first_thread_id,
             attempt: 0,
             dispatched_at: ^dispatched_at,
             completed_at: completed_at,
             duration_ms: duration_ms,
             model: ^model,
             stop_reason: :agent_exit_normal
           } = first_record

    assert {:ok, _dt, _offset} = DateTime.from_iso8601(completed_at)
    assert is_integer(duration_ms) and duration_ms >= 0

    # 6. Second dispatch — render the prompt with the SAME opts the
    # orchestrator's `spawn_issue_on_worker_host/5` constructs. The
    # `prior_sessions` arg comes straight from `state.completed`, which is
    # exactly what the orchestrator does.
    prior_sessions = Map.fetch!(state_after_first.completed, issue_id)
    second_thread_id = "thr-second"
    second_dispatched_at = DateTime.utc_now() |> DateTime.to_iso8601()

    rendered =
      PromptBuilder.build_prompt(issue,
        attempt: 1,
        last_run_completed_at: completed_at,
        prior_sessions: prior_sessions,
        dispatched_at: second_dispatched_at,
        model: model,
        thread_id: second_thread_id
      )

    # 7. The second dispatch's prompt sees prior_sessions of length 1 with the
    # first session's thread_id + model + stop_reason exposed.
    assert rendered =~ "thread_id=#{second_thread_id}"
    assert rendered =~ "subject_id=#{content_id}"
    assert rendered =~ "model=#{model}"
    assert rendered =~ "dispatched_at=#{second_dispatched_at}"
    assert rendered =~ "prior_sessions_count=1"
    assert rendered =~ "prior[0].thread_id=#{first_thread_id}"
    assert rendered =~ "prior[0].model=#{model}"
    assert rendered =~ "prior[0].stop_reason=agent_exit_normal"
  end
end
