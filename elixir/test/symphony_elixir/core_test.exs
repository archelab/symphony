defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    # SPEC §11.8.9 PR4 amendment: workpad defaults to enabled, which fires
    # `validate_workpad_template/1` against any workflow whose front matter
    # does not explicitly opt out. A prompt-only file has no front matter at
    # all, so an empty config map presents no `enabled: false` and the
    # validation rejects the prompt body for not referencing any workpad
    # variable. The pre-PR4 form (prompt-only is accepted) is preserved by
    # treating the empty-config map specifically — no front matter means no
    # opinion about agent.* either way, and `validate_workpad_template/1`
    # treats that as workpad-active. We assert the new (loud) behavior here
    # rather than silently accepting a workpad-less prompt — the test now
    # documents the failure mode operators see if they delete their front
    # matter.
    File.write!(workflow_path, "Prompt only\n")

    assert {:error,
            {:invalid_workflow_config,
             "agent.workpad.enabled: true requires the workflow prompt template to reference at least one of: " <>
               _vars}} = Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    # Same §11.8.9 PR4 contract as the prompt-only case above: unterminated
    # front matter (no closing `---`) means the loader treats the whole file
    # as front matter and produces an empty prompt body. With workpad
    # default-enabled, an empty prompt fails `validate_workpad_template/1`.
    File.write!(workflow_path, "---\ntracker:\n  kind: memory\n")

    assert {:error,
            {:invalid_workflow_config,
             "agent.workpad.enabled: true requires the workflow prompt template to reference at least one of: " <>
               _vars}} = Workflow.load(workflow_path)
  end

  test "workflow load accepts prompt-only files when workpad + session_summary are explicitly disabled (SPEC §11.8.9 + 11.8.10 opt-out)" do
    # Workpad (SPEC §11.8.9) still defaults to enabled, so prompt-only files
    # must opt out of it. Session-summary is opt-in, but this fixture keeps the
    # opt-out explicit so older prompt-only workflows remain unambiguous.
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_OPTED_OUT.md")

    File.write!(
      workflow_path,
      "---\nagent:\n  workpad:\n    enabled: false\n  session_summary:\n    enabled: false\n---\nPrompt only\n"
    )

    assert {:ok,
            %{
              config: %{
                "agent" => %{
                  "workpad" => %{"enabled" => false},
                  "session_summary" => %{"enabled" => false}
                }
              },
              prompt: "Prompt only",
              prompt_template: "Prompt only"
            }} = Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "non-active issue state (refresh map) stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "archelab/symphony#555"
    workspace = Path.join(test_root, "archelab_symphony_555")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        identifier: issue_identifier,
        issue: %Issue{
          id: issue_id,
          identifier: issue_identifier,
          kind: "issue",
          state: "Todo",
          issue_state: "OPEN"
        },
        started_at: DateTime.utc_now(),
        blocked_by_snapshot: []
      }

      state = %Orchestrator.State{
        running: %{issue_id => running_entry},
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      # `Backlog` is neither active nor terminal — :inactive_state branch,
      # which does NOT clean up the workspace per SPEC §8.5 Part B.
      refresh = [%{id: issue_id, state: "Backlog", blocked_by: []}]
      tracker = Config.settings!().tracker

      updated_state =
        Orchestrator.reconcile_running({issue_id, running_entry}, refresh, tracker, state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state (refresh map) stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "archelab/symphony#556"
    workspace = Path.join(test_root, "archelab_symphony_556")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        identifier: issue_identifier,
        issue: %Issue{
          id: issue_id,
          identifier: issue_identifier,
          kind: "issue",
          state: "In Progress",
          issue_state: "OPEN"
        },
        started_at: DateTime.utc_now(),
        blocked_by_snapshot: []
      }

      state = %Orchestrator.State{
        running: %{issue_id => running_entry},
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      # Status moved to a terminal value — :terminal_state branch with
      # workspace cleanup.
      refresh = [%{id: issue_id, state: "Closed", blocked_by: []}]
      tracker = Config.settings!().tracker

      updated_state =
        Orchestrator.reconcile_running({issue_id, running_entry}, refresh, tracker, state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:tick, initial_state.tick_token})
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile (active refresh map) keeps worker and updates blocker snapshot" do
    issue_id = "issue-3"
    identifier = "archelab/symphony#557"

    running_entry = %{
      pid: self(),
      ref: nil,
      issue_id: issue_id,
      issue_identifier: identifier,
      identifier: identifier,
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        kind: "issue",
        state: "Todo",
        issue_state: "OPEN"
      },
      started_at: DateTime.utc_now(),
      blocked_by_snapshot: []
    }

    state = %Orchestrator.State{
      running: %{issue_id => running_entry},
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    refreshed_blockers = [%{id: "B1", identifier: "archelab/symphony#999", state: "OPEN"}]
    refresh = [%{id: issue_id, state: "In Progress", blocked_by: refreshed_blockers}]
    tracker = Config.settings!().tracker

    updated_state =
      Orchestrator.reconcile_running({issue_id, running_entry}, refresh, tracker, state)

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    updated_entry = updated_state.running[issue_id]
    assert updated_entry.blocked_by_snapshot == refreshed_blockers
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert Map.has_key?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 500, 1_100)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  test "dispatch_eligible_for_test re-dispatches an issue in state.completed once the claim is released (SPEC §4.1.8 + §11.8.3 Rework)" do
    # Regression guard: `state.completed` is bookkeeping per §4.1.8. After a
    # crash whose retry chain was torn down (claim released because the issue
    # left Active mid-retry), the user moves Status back to Active for Rework.
    # On the next poll the orchestrator MUST be willing to re-dispatch even
    # though `completed` already has session records for this issue.
    write_workflow_file!(Workflow.workflow_file_path())
    tracker_settings = Config.settings!().tracker

    issue = %Issue{
      id: "PVTI_rework_after_crash",
      identifier: "archelab/symphony#910",
      kind: "issue",
      state: "Agent Ready",
      issue_state: "OPEN"
    }

    state_with_prior_completed = %Orchestrator.State{
      max_concurrent_agents: 4,
      running: %{},
      claimed: MapSet.new(),
      completed: %{
        issue.id => [
          %{
            thread_id: "thr-prior",
            attempt: 1,
            dispatched_at: "2026-05-11T10:00:00Z",
            completed_at: "2026-05-11T10:05:00Z",
            duration_ms: 300_000,
            model: "gpt-5.5",
            stop_reason: :agent_exit_crashed
          }
        ]
      }
    }

    assert Orchestrator.dispatch_eligible_for_test(issue, state_with_prior_completed, tracker_settings)
  end

  test "dispatch_eligible_for_test still blocks an issue while its claim is held (SPEC §4.1.8 — claim is the gate)" do
    write_workflow_file!(Workflow.workflow_file_path())
    tracker_settings = Config.settings!().tracker

    issue = %Issue{
      id: "PVTI_claim_held",
      identifier: "archelab/symphony#911",
      kind: "issue",
      state: "Agent Ready",
      issue_state: "OPEN"
    }

    state_with_active_claim = %Orchestrator.State{
      max_concurrent_agents: 4,
      running: %{},
      claimed: MapSet.new([issue.id]),
      completed: %{}
    }

    refute Orchestrator.dispatch_eligible_for_test(issue, state_with_active_claim, tracker_settings)
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  describe "dispatchable?/2 (SPEC §11.2.1 terminal-OR + §8.2 eligibility)" do
    alias SymphonyElixir.Tracker.Memory

    setup do
      tracker_settings = %{
        active_states: ["Agent Ready", "In Progress"],
        terminal_states: ["Done"],
        dependency_gating_states: ["Agent Ready"],
        gate_running_on_dependencies: false,
        cross_repo_blockers: false
      }

      %{tracker_settings: tracker_settings}
    end

    test "merged PR is treated as terminal even if Project Status is active",
         %{tracker_settings: tracker_settings} do
      pr_issue =
        Issue.new(%{
          id: "PVTI_pr",
          identifier: "archelab/symphony#5",
          kind: "pull_request",
          title: "merged",
          state: "In Progress",
          issue_state: "MERGED",
          pr: %{state: "MERGED", merged: true, is_draft: false, base_ref_name: "main"},
          labels: [],
          blocked_by: [],
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          number: 5
        })

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [pr_issue])

      refute Orchestrator.dispatchable?(pr_issue, tracker_settings)

      # Memory adapter also filters terminal-OR at the source.
      assert {:ok, []} = Memory.fetch_candidate_issues()
    end

    test "closed issue with active Status is rejected", %{tracker_settings: tracker_settings} do
      issue =
        Issue.new(%{
          id: "PVTI_closed",
          identifier: "archelab/symphony#6",
          kind: "issue",
          state: "Agent Ready",
          issue_state: "CLOSED",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"}
        })

      refute Orchestrator.dispatchable?(issue, tracker_settings)
    end

    test "<no status> sentinel is never dispatchable", %{tracker_settings: tracker_settings} do
      issue =
        Issue.new(%{
          id: "PVTI_ns",
          identifier: "archelab/symphony#7",
          kind: "issue",
          state: "<no status>",
          issue_state: "OPEN",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"}
        })

      refute Orchestrator.dispatchable?(issue, tracker_settings)
    end

    test "OPEN issue with active Status is dispatchable", %{tracker_settings: tracker_settings} do
      issue =
        Issue.new(%{
          id: "PVTI_ok",
          identifier: "archelab/symphony#8",
          kind: "issue",
          state: "In Progress",
          issue_state: "OPEN",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"}
        })

      assert Orchestrator.dispatchable?(issue, tracker_settings)
    end

    test "draft_issue with active Status is dispatchable (no issue_state required)",
         %{tracker_settings: tracker_settings} do
      issue =
        Issue.new(%{
          id: "PVTI_draft",
          identifier: "draft:abcdef",
          kind: "draft_issue",
          state: "Agent Ready",
          issue_state: nil
        })

      assert Orchestrator.dispatchable?(issue, tracker_settings)
    end

    test "dependency gating drops parent when same-repo blocker is open",
         %{tracker_settings: tracker_settings} do
      issue =
        Issue.new(%{
          id: "PVTI_parent",
          identifier: "archelab/symphony#9",
          kind: "issue",
          state: "Agent Ready",
          issue_state: "OPEN",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          blocked_by: [%{id: "B1", identifier: "archelab/symphony#10", state: "OPEN"}]
        })

      refute Orchestrator.dispatchable?(issue, tracker_settings)
    end

    test "dependency gating ignores cross-repo blockers when cross_repo_blockers=false",
         %{tracker_settings: tracker_settings} do
      issue =
        Issue.new(%{
          id: "PVTI_parent_cross",
          identifier: "archelab/symphony#11",
          kind: "issue",
          state: "Agent Ready",
          issue_state: "OPEN",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          blocked_by: [%{id: "B2", identifier: "other/repo#1", state: "OPEN"}]
        })

      assert Orchestrator.dispatchable?(issue, tracker_settings)
    end

    test "dependency gating honors cross-repo blockers when enabled" do
      tracker_settings = %{
        active_states: ["Agent Ready"],
        terminal_states: ["Done"],
        dependency_gating_states: ["Agent Ready"],
        gate_running_on_dependencies: false,
        cross_repo_blockers: true
      }

      issue =
        Issue.new(%{
          id: "PVTI_parent_cross_on",
          identifier: "archelab/symphony#12",
          kind: "issue",
          state: "Agent Ready",
          issue_state: "OPEN",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          blocked_by: [%{id: "B3", identifier: "other/repo#1", state: "OPEN"}]
        })

      refute Orchestrator.dispatchable?(issue, tracker_settings)
    end

    test "draft blocker with `draft:<short>` identifier is dropped under cross_repo_blockers=false",
         %{tracker_settings: tracker_settings} do
      issue =
        Issue.new(%{
          id: "PVTI_draft_blocker",
          identifier: "archelab/symphony#13",
          kind: "issue",
          state: "Agent Ready",
          issue_state: "OPEN",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          blocked_by: [%{id: "B4", identifier: "draft:abc123", state: "OPEN"}]
        })

      assert Orchestrator.dispatchable?(issue, tracker_settings)
    end

    test "CLOSED blocker is resolved; parent dispatches", %{tracker_settings: tracker_settings} do
      issue =
        Issue.new(%{
          id: "PVTI_unblocked",
          identifier: "archelab/symphony#14",
          kind: "issue",
          state: "Agent Ready",
          issue_state: "OPEN",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          blocked_by: [%{id: "B5", identifier: "archelab/symphony#99", state: "CLOSED"}]
        })

      assert Orchestrator.dispatchable?(issue, tracker_settings)
    end

    test "native blockedBy open blocker prevents dispatch and closed blocker allows it",
         %{tracker_settings: tracker_settings} do
      open_issue =
        Issue.new(%{
          id: "PVTI_native_blocked",
          identifier: "archelab/symphony#15",
          kind: "issue",
          state: "Agent Ready",
          issue_state: "OPEN",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          blocked_by: [%{id: "I_native_open", identifier: "archelab/symphony#16", state: "OPEN"}]
        })

      closed_issue =
        Issue.new(%{
          id: "PVTI_native_unblocked",
          identifier: "archelab/symphony#17",
          kind: "issue",
          state: "Agent Ready",
          issue_state: "OPEN",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          blocked_by: [%{id: "I_native_closed", identifier: "archelab/symphony#18", state: "CLOSED"}]
        })

      refute Orchestrator.dispatchable?(open_issue, tracker_settings)
      assert Orchestrator.dispatchable?(closed_issue, tracker_settings)
    end
  end

  describe "reconcile_running/3 (SPEC §8.5 Part B + §13.1 stop-reason vocab)" do
    setup do
      tracker_settings = %{
        active_states: ["Agent Ready", "In Progress"],
        terminal_states: ["Done"],
        dependency_gating_states: ["Agent Ready"],
        gate_running_on_dependencies: false,
        cross_repo_blockers: false
      }

      running_entry = %{
        issue_id: "PVTI_x",
        issue_identifier: "archelab/symphony#1",
        identifier: "archelab/symphony#1",
        session_id: "t-1",
        pid: nil,
        ref: nil,
        started_at: DateTime.utc_now(),
        blocked_by_snapshot: []
      }

      state = %Orchestrator.State{
        running: %{"PVTI_x" => running_entry},
        claimed: MapSet.new(["PVTI_x"]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      %{tracker_settings: tracker_settings, running: running_entry, state: state}
    end

    test "<no status> reconciliation is a no-op (SPEC §11.2.1) — no worker stop",
         %{tracker_settings: settings, running: running, state: state} do
      refresh = [%{id: "PVTI_x", state: "<no status>"}]

      {updated, log} =
        with_log(fn ->
          Orchestrator.reconcile_running({"PVTI_x", running}, refresh, settings, state)
        end)

      refute log =~ "worker stop"
      assert Map.has_key?(updated.running, "PVTI_x")
    end

    test "<closed> sentinel emits :terminal_or_closed stop",
         %{tracker_settings: settings, running: running, state: state} do
      refresh = [%{id: "PVTI_x", state: "<closed>"}]

      {updated, log} =
        with_log(fn ->
          Orchestrator.reconcile_running({"PVTI_x", running}, refresh, settings, state)
        end)

      assert log =~ "worker stop"
      assert log =~ "reason=:terminal_or_closed"
      refute Map.has_key?(updated.running, "PVTI_x")
    end

    test "<merged> sentinel emits :terminal_or_merged stop",
         %{tracker_settings: settings, running: running, state: state} do
      refresh = [%{id: "PVTI_x", state: "<merged>"}]

      {updated, log} =
        with_log(fn ->
          Orchestrator.reconcile_running({"PVTI_x", running}, refresh, settings, state)
        end)

      assert log =~ "worker stop"
      assert log =~ "reason=:terminal_or_merged"
      refute Map.has_key?(updated.running, "PVTI_x")
    end

    test "terminal Status emits :terminal_state stop",
         %{tracker_settings: settings, running: running, state: state} do
      refresh = [%{id: "PVTI_x", state: "Done"}]

      {updated, log} =
        with_log(fn ->
          Orchestrator.reconcile_running({"PVTI_x", running}, refresh, settings, state)
        end)

      assert log =~ "reason=:terminal_state"
      refute Map.has_key?(updated.running, "PVTI_x")
    end

    test "non-active non-terminal Status emits :inactive_state stop",
         %{tracker_settings: settings, running: running, state: state} do
      refresh = [%{id: "PVTI_x", state: "Backlog"}]

      {updated, log} =
        with_log(fn ->
          Orchestrator.reconcile_running({"PVTI_x", running}, refresh, settings, state)
        end)

      assert log =~ "reason=:inactive_state"
      refute Map.has_key?(updated.running, "PVTI_x")
    end

    test "missing refresh row emits :reconciled_missing stop",
         %{tracker_settings: settings, running: running, state: state} do
      {updated, log} =
        with_log(fn ->
          Orchestrator.reconcile_running({"PVTI_x", running}, [], settings, state)
        end)

      assert log =~ "reason=:reconciled_missing"
      refute Map.has_key?(updated.running, "PVTI_x")
    end

    test "active Status with no blocker churn is a no-op",
         %{tracker_settings: settings, running: running, state: state} do
      refresh = [%{id: "PVTI_x", state: "In Progress", blocked_by: []}]

      {updated, log} =
        with_log(fn ->
          Orchestrator.reconcile_running({"PVTI_x", running}, refresh, settings, state)
        end)

      refute log =~ "worker stop"
      assert Map.has_key?(updated.running, "PVTI_x")
    end

    test "gate_running_on_dependencies=true + blocker transition CLOSED→OPEN emits :dependencies_reopened" do
      settings = %{
        active_states: ["In Progress"],
        terminal_states: ["Done"],
        dependency_gating_states: ["Agent Ready"],
        gate_running_on_dependencies: true,
        cross_repo_blockers: false
      }

      running_entry = %{
        issue_id: "PVTI_y",
        issue_identifier: "archelab/symphony#2",
        identifier: "archelab/symphony#2",
        session_id: "t-2",
        pid: nil,
        ref: nil,
        started_at: DateTime.utc_now(),
        blocked_by_snapshot: [%{id: "B1", identifier: "archelab/symphony#3", state: "CLOSED"}]
      }

      state = %Orchestrator.State{
        running: %{"PVTI_y" => running_entry},
        claimed: MapSet.new(["PVTI_y"]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      refresh = [
        %{
          id: "PVTI_y",
          state: "In Progress",
          blocked_by: [%{id: "B1", identifier: "archelab/symphony#3", state: "OPEN"}]
        }
      ]

      {updated, log} =
        with_log(fn ->
          Orchestrator.reconcile_running({"PVTI_y", running_entry}, refresh, settings, state)
        end)

      assert log =~ "reason=:dependencies_reopened"
      refute Map.has_key?(updated.running, "PVTI_y")
    end

    test "apply_reconcile_running/2 pins the private reconcile entry point" do
      # Pin the production seam: reconcile_running_issues/1 ->
      # apply_reconcile_running/2 -> reconcile_running/4. A refactor that
      # bypasses apply_reconcile_running/2 would silently drop the
      # :dependencies_reopened branch; this test fails loudly in that case.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["In Progress"],
        tracker_terminal_states: ["Done"],
        tracker_dependency_gating_states: ["Agent Ready"],
        tracker_gate_running_on_dependencies: true,
        tracker_cross_repo_blockers: false
      )

      running_entry = %{
        issue_id: "PVTI_e2e",
        issue_identifier: "archelab/symphony#11",
        identifier: "archelab/symphony#11",
        session_id: "t-e2e",
        pid: nil,
        ref: nil,
        started_at: DateTime.utc_now(),
        blocked_by_snapshot: [
          %{id: "B1", identifier: "archelab/symphony#12", state: "CLOSED"}
        ]
      }

      state = %Orchestrator.State{
        running: %{"PVTI_e2e" => running_entry},
        claimed: MapSet.new(["PVTI_e2e"]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      refresh = [
        %{
          id: "PVTI_e2e",
          state: "In Progress",
          blocked_by: [%{id: "B1", identifier: "archelab/symphony#12", state: "OPEN"}]
        }
      ]

      {updated, log} =
        with_log(fn ->
          Orchestrator.apply_reconcile_running_for_test(state, refresh)
        end)

      assert log =~ "reason=:dependencies_reopened"
      refute Map.has_key?(updated.running, "PVTI_e2e")
    end
  end

  test "completed records the latest session as head of a list (SPEC §11.8.5)" do
    issue_id = "issue-completed-iso8601"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CompletedAtOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()
    dispatched_at = DateTime.to_iso8601(started_at)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "archelab/symphony#100",
      issue: %Issue{
        id: issue_id,
        identifier: "archelab/symphony#100",
        kind: "issue",
        state: "In Progress",
        issue_state: "OPEN"
      },
      started_at: started_at,
      dispatched_at: dispatched_at,
      thread_id: "thr-abc",
      model: "gpt-5.5",
      retry_attempt: 0
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    state = :sys.get_state(pid)

    assert [head | _] = Map.fetch!(state.completed, issue_id)

    assert %{
             thread_id: "thr-abc",
             attempt: 0,
             dispatched_at: ^dispatched_at,
             completed_at: completed_at,
             duration_ms: duration_ms,
             model: "gpt-5.5",
             stop_reason: :agent_exit_normal
           } = head

    assert {:ok, _datetime, _offset} = DateTime.from_iso8601(completed_at)
    assert is_integer(duration_ms) and duration_ms >= 0
  end

  test "completed list grows on successive dispatches and prunes to K (SPEC §11.8.5)" do
    issue_id = "issue-completed-prune"
    orchestrator_name = Module.concat(__MODULE__, :CompletedPruneOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    # Seed 25 prior sessions so we can verify pruning.
    seed_records =
      for i <- 1..25 do
        %{
          thread_id: "thr-#{i}",
          attempt: 0,
          dispatched_at: "2026-05-11T00:00:0#{rem(i, 10)}Z",
          completed_at: "2026-05-11T01:00:0#{rem(i, 10)}Z",
          duration_ms: 1000 * i,
          model: nil,
          stop_reason: :agent_exit_normal
        }
      end

    ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "archelab/symphony#101",
      issue: %Issue{id: issue_id, identifier: "archelab/symphony#101", kind: "issue", state: "In Progress", issue_state: "OPEN"},
      started_at: started_at,
      dispatched_at: DateTime.to_iso8601(started_at),
      thread_id: "thr-new",
      model: nil,
      retry_attempt: 0
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:completed, %{issue_id => seed_records})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    state = :sys.get_state(pid)
    records = Map.fetch!(state.completed, issue_id)

    # Pruned to 20 total (default max_sessions). New record is at the head.
    assert length(records) == 20
    assert [%{thread_id: "thr-new"} | _] = records
  end

  test "abnormal worker exit (:agent_exit_crashed) records a session record (SPEC §11.8.3)" do
    issue_id = "issue-completed-crashed"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashedExitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()
    dispatched_at = DateTime.to_iso8601(started_at)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "archelab/symphony#900",
      issue: %Issue{
        id: issue_id,
        identifier: "archelab/symphony#900",
        kind: "issue",
        state: "In Progress",
        issue_state: "OPEN"
      },
      started_at: started_at,
      dispatched_at: dispatched_at,
      thread_id: "thr-crash",
      model: "gpt-5.5",
      retry_attempt: 2
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    # Non-:normal exit reasons map to :agent_exit_crashed per §13.1 vocabulary.
    send(pid, {:DOWN, ref, :process, self(), {:badarg, []}})
    Process.sleep(50)

    state = :sys.get_state(pid)

    assert [
             %{
               thread_id: "thr-crash",
               attempt: 2,
               stop_reason: :agent_exit_crashed,
               model: "gpt-5.5"
             }
             | _
           ] = Map.fetch!(state.completed, issue_id)
  end

  test ":stall_restart records a session record (SPEC §11.8.3 — recover via prior_sessions[0])" do
    issue_id = "PVTI_stall_restart_completed"
    orchestrator_name = Module.concat(__MODULE__, :StallRestartOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    # Drive the stall detector: last_codex_timestamp older than stall_timeout_ms.
    stall_timeout_ms = Config.settings!().codex.stall_timeout_ms
    started_at = DateTime.add(DateTime.utc_now(), -(stall_timeout_ms + 60_000), :millisecond)

    fake_pid = spawn(fn -> Process.sleep(:infinity) end)
    fake_ref = Process.monitor(fake_pid)

    running_entry = %{
      pid: fake_pid,
      ref: fake_ref,
      issue_id: issue_id,
      issue_identifier: "archelab/symphony#901",
      identifier: "archelab/symphony#901",
      issue: %Issue{
        id: issue_id,
        identifier: "archelab/symphony#901",
        kind: "issue",
        state: "In Progress",
        issue_state: "OPEN"
      },
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      blocked_by_snapshot: [],
      started_at: started_at,
      dispatched_at: DateTime.to_iso8601(started_at),
      thread_id: "thr-stall",
      model: nil,
      retry_attempt: 3,
      last_codex_timestamp: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    state_before = :sys.get_state(pid)
    state_after = Orchestrator.apply_reconcile_stalled_runs_for_test(state_before)

    assert [%{stop_reason: :stall_restart, thread_id: "thr-stall", attempt: 3} | _] =
             Map.fetch!(state_after.completed, issue_id)
  end

  test "stop_reason carries reconcile-driven tokens (SPEC §11.8.5)" do
    issue_id = "PVTI_reconcile_completed"
    orchestrator_name = Module.concat(__MODULE__, :ReconcileStopReasonOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    fake_pid = spawn(fn -> Process.sleep(:infinity) end)
    fake_ref = Process.monitor(fake_pid)

    running_entry = %{
      pid: fake_pid,
      ref: fake_ref,
      issue_id: issue_id,
      issue_identifier: "archelab/symphony#102",
      identifier: "archelab/symphony#102",
      issue: %Issue{id: issue_id, identifier: "archelab/symphony#102", kind: "issue", state: "Done", issue_state: "CLOSED"},
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      blocked_by_snapshot: [],
      started_at: started_at,
      dispatched_at: DateTime.to_iso8601(started_at),
      thread_id: "thr-reconcile",
      model: nil,
      retry_attempt: 2
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    refresh = [%{id: issue_id, state: "<closed>", blocked_by: []}]
    state_before = :sys.get_state(pid)
    state_after = Orchestrator.apply_reconcile_running_for_test(state_before, refresh)

    assert [%{stop_reason: :terminal_or_closed, thread_id: "thr-reconcile", attempt: 2} | _] =
             Map.fetch!(state_after.completed, issue_id)
  end

  test "completed_sessions_for returns identifier matches ordered by completed_at desc and capped" do
    orchestrator_name = Module.concat(__MODULE__, :CompletedSessionsLookupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    records =
      for i <- 1..25 do
        %{
          issue_id: "issue-completed-lookup",
          identifier: "archelab/symphony#lookup",
          thread_id: "thr-#{i}",
          attempt: i,
          dispatched_at: "2026-05-12T01:00:00Z",
          completed_at: "2026-05-12T01:00:#{String.pad_leading(Integer.to_string(rem(i, 60)), 2, "0")}Z",
          duration_ms: i,
          model: nil,
          stop_reason: :agent_exit_normal
        }
      end

    :sys.replace_state(pid, fn state ->
      Map.put(state, :completed, %{
        "issue-completed-lookup" => Enum.reverse(records),
        "issue-other" => [
          %{
            issue_id: "issue-other",
            identifier: "archelab/symphony#other",
            thread_id: "thr-other",
            attempt: 1,
            dispatched_at: "2026-05-12T01:00:00Z",
            completed_at: "2026-05-12T02:00:00Z",
            duration_ms: 1,
            model: nil,
            stop_reason: :agent_exit_normal
          }
        ]
      })
    end)

    sessions = Orchestrator.completed_sessions_for("archelab/symphony#lookup", orchestrator_name, 5_000)

    assert length(sessions) == 20
    assert hd(sessions).thread_id == "thr-25"
    assert List.last(sessions).thread_id == "thr-6"
    assert Orchestrator.completed_sessions_for("archelab/symphony#missing", orchestrator_name, 5_000) == []
  end

  test "reconcile termination sends wrap-up signal and records normal exit with final intent" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_graceful_termination_budget_ms: 500)

    issue_id = "PVTI_graceful_wrap"
    parent = self()

    worker =
      spawn(fn ->
        receive do
          {:symphony_wrap_up, payload} ->
            send(parent, {:wrap_up_received, payload})
            :ok
        end
      end)

    ref = Process.monitor(worker)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: worker,
      ref: ref,
      issue_id: issue_id,
      issue_identifier: "archelab/symphony#910",
      identifier: "archelab/symphony#910",
      issue: %Issue{id: issue_id, identifier: "archelab/symphony#910", kind: "issue", state: "Blocked", issue_state: "OPEN"},
      worker_host: nil,
      workspace_path: nil,
      session_id: "thread-wrap-turn-1",
      blocked_by_snapshot: [],
      started_at: started_at,
      dispatched_at: DateTime.to_iso8601(started_at),
      thread_id: "thread-wrap",
      model: "gpt-5.4-mini",
      retry_attempt: 1
    }

    state_before =
      %Orchestrator.State{}
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:codex_totals, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        state_after =
          Orchestrator.apply_reconcile_running_for_test(state_before, [
            %{id: issue_id, state: "Blocked", blocked_by: []}
          ])

        assert_receive {:wrap_up_received, %{reason: :inactive_state, budget_ms: 500}}
        refute Process.alive?(worker)
        refute Map.has_key?(state_after.running, issue_id)

        assert [%{stop_reason: :agent_exit_normal, identifier: "archelab/symphony#910"} | _] =
                 Map.fetch!(state_after.completed, issue_id)
      end)

    assert log =~ "reason=:agent_exit_normal"
    assert log =~ "final_intent=:inactive_state"
  end

  test "reconcile termination kills worker after wrap-up budget expires" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_graceful_termination_budget_ms: 10)

    issue_id = "PVTI_graceful_timeout"
    parent = self()

    worker =
      spawn(fn ->
        receive do
          {:symphony_wrap_up, payload} ->
            send(parent, {:wrap_up_received, payload})
            Process.sleep(:infinity)
        end
      end)

    ref = Process.monitor(worker)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: worker,
      ref: ref,
      issue_id: issue_id,
      issue_identifier: "archelab/symphony#911",
      identifier: "archelab/symphony#911",
      issue: %Issue{id: issue_id, identifier: "archelab/symphony#911", kind: "issue", state: "Done", issue_state: "CLOSED"},
      worker_host: nil,
      workspace_path: nil,
      session_id: "thread-timeout-turn-1",
      blocked_by_snapshot: [],
      started_at: started_at,
      dispatched_at: DateTime.to_iso8601(started_at),
      thread_id: "thread-timeout",
      model: nil,
      retry_attempt: 0
    }

    state_before =
      %Orchestrator.State{}
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:codex_totals, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        state_after =
          Orchestrator.apply_reconcile_running_for_test(state_before, [
            %{id: issue_id, state: "<closed>", blocked_by: []}
          ])

        assert_receive {:wrap_up_received, %{reason: :terminal_or_closed, budget_ms: 10}}
        refute Map.has_key?(state_after.running, issue_id)

        assert [%{stop_reason: :terminal_or_closed} | _] =
                 Map.fetch!(state_after.completed, issue_id)
      end)

    refute Process.alive?(worker)
    assert log =~ "reason=:terminal_or_closed"
    assert log =~ "graceful=false"
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a tracker issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue =
      Issue.new(%{
        id: "PVTI_abc",
        identifier: "archelab/symphony#42",
        kind: "issue",
        # SPEC §11.8.5: `content_id` is the underlying Issue/PullRequest GraphQL
        # node id, surfaced to the agent as `subject_id`. Required for the
        # workpad bridge to activate; the PR4-default WORKFLOW.md references
        # `{{ subject_id }}` and Solid strict mode rejects an unbound binding.
        content_id: "I_abc",
        title: "Use rich templates for WORKFLOW.md",
        description: "Render with rich template variables",
        state: "In Progress",
        repository: %{
          owner: "archelab",
          name: "symphony",
          name_with_owner: "archelab/symphony",
          default_branch: "main"
        },
        number: 42,
        url: "https://github.com/archelab/symphony/issues/42",
        labels: ["templating", "workflow"],
        blocked_by: [],
        issue_state: "OPEN"
      })

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt =
      PromptBuilder.build_prompt(issue,
        attempt: 2,
        last_run_completed_at: "2026-05-09T20:00:00Z",
        thread_id: "thr-render",
        dispatched_at: "2026-05-10T01:00:00Z",
        model: "gpt-5.5",
        prior_sessions: []
      )

    assert prompt =~ "You are working on GitHub item `archelab/symphony#42`"
    assert prompt =~ "## Item context"
    assert prompt =~ "Identifier: archelab/symphony#42"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current Project Status: In Progress"
    assert prompt =~ "https://github.com/archelab/symphony/issues/42"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "## Continuation context"
    assert prompt =~ "dispatch attempt #2"
    assert prompt =~ "Prior session ended at 2026-05-09T20:00:00Z"
    assert prompt =~ "gh issue view 42 -R archelab/symphony"
    assert prompt =~ "Open work on a feature branch and submit a Pull Request against\n`main`"
    assert prompt =~ "`github_graphql` tool is registered"
    # SPEC §11.8.5: workpad bridge active → rendered prompt surfaces the
    # five vars passed above.
    assert prompt =~ "thr-render"
    assert prompt =~ "I_abc"
    assert prompt =~ "gpt-5.5"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner turns wrap-up signal into one final Codex turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-wrap-up-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        turn_count=0
        trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/symphony-wrap.trace}"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$trace_file"
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            *'"method":"thread/start"'*)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-wrap"}}}'
              ;;
            *'"method":"turn/start"'*)
              turn_count=$((turn_count + 1))
              if [ "$turn_count" -eq 1 ]; then
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-main"}}}'
              else
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-wrap"}}}'
                printf '%s\\n' '{"method":"turn/completed"}'
              fi
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)
      previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> restore_env("SYMP_TEST_CODEX_TRACE", previous_trace) end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-wrap-up-turn",
        identifier: "MT-WRAP",
        title: "Wrap up",
        description: "Final turn",
        state: "In Progress"
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            test_pid,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
          )
        end)

      assert_receive {:codex_worker_update, "issue-wrap-up-turn", %{event: :session_started, session_id: "thread-wrap-turn-main"}}, 1_000

      send(task.pid, {:symphony_wrap_up, %{reason: :inactive_state, budget_ms: 30_000}})

      assert :ok = Task.await(task, 5_000)
      trace = File.read!(trace_file)

      assert trace =~ "Symphony is terminating this worker."
      assert trace =~ "Reason: `inactive_state`"
      assert trace =~ "## Blocker report"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  # Regression for the e2e crash where AgentRunner.continue_with_issue?/2
  # pattern-matched the fetcher result on %Issue{}, but the Github adapter's
  # fetch_issue_states_by_ids/1 returns refresh-result MAPS
  # (Tracker.refresh_result). The agent task crashed with :case_clause after
  # turn 1. The runner must accept both shapes (Memory %Issue{} and Github
  # refresh map) so production GitHub flows survive the continuation check.
  test "agent runner accepts Github refresh-map shape from issue_state_fetcher" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-refresh-map-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-refresh-map"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-refresh-map-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-refresh-map-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      # First refresh returns the Github adapter's map shape with state
      # "Agent Ready" (active) → runner must continue. Second refresh returns
      # state "Done" → runner must stop without crashing.
      state_fetcher = fn [issue_id] ->
        attempt = Process.get(:refresh_map_fetch_count, 0) + 1
        Process.put(:refresh_map_fetch_count, attempt)
        send(parent, {:refresh_map_fetch, attempt})

        state =
          if attempt == 1 do
            "Agent Ready"
          else
            "Done"
          end

        {:ok,
         [
           %{
             id: issue_id,
             identifier: "draft:KzgsX7CM",
             state: state,
             blocked_by: []
           }
         ]}
      end

      issue = %Issue{
        id: "PVTI_lADODDTPxM4BXSCKzgsX7CM",
        identifier: "draft:KzgsX7CM",
        title: "smoke test refresh-map",
        description: "still active after first turn",
        state: "Agent Ready",
        url: nil,
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:refresh_map_fetch, 1}
      assert_receive {:refresh_map_fetch, 2}

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
