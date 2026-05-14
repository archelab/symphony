defmodule SymphonyElixir.Orchestrator.DispatchPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Github.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.DispatchPolicy
  alias SymphonyElixir.Workflow

  test "sort_issues_for_dispatch orders by priority, created_at, and identifier" do
    issues = [
      %Issue{id: "2", identifier: "B", priority: nil, created_at: ~U[2026-05-14 10:00:00Z]},
      %Issue{id: "1", identifier: "A", priority: 1, created_at: ~U[2026-05-14 11:00:00Z]},
      %Issue{id: "3", identifier: "C", priority: 1, created_at: ~U[2026-05-14 09:00:00Z]}
    ]

    assert Enum.map(DispatchPolicy.sort_issues_for_dispatch(issues), & &1.identifier) == ["C", "A", "B"]
  end

  test "dispatchable rejects no-status items and open blockers in gated states" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_dependency_gating_states: ["Agent Ready"],
      tracker_cross_repo_blockers: false,
      max_concurrent_agents_by_state: %{"Agent Ready" => 1}
    )

    tracker = Config.settings!().tracker

    no_status = %Issue{id: "1", identifier: "A", state: "<no status>", kind: "issue", issue_state: "OPEN"}

    blocked = %Issue{
      id: "2",
      identifier: "archelab/symphony#2",
      state: "Agent Ready",
      kind: "issue",
      issue_state: "OPEN",
      repository: %Issue.Repository{
        owner: "archelab",
        name: "symphony",
        name_with_owner: "archelab/symphony"
      },
      blocked_by: [
        %Issue.Blocker{id: "b1", identifier: "archelab/symphony#1", state: "OPEN"}
      ]
    }

    refute DispatchPolicy.dispatchable?(no_status, tracker)
    refute DispatchPolicy.dispatchable?(blocked, tracker)
  end

  test "dispatch_eligible blocks running and claimed issue ids" do
    issue = %Issue{
      id: "PVTI_1",
      identifier: "archelab/symphony#1",
      state: "Agent Ready",
      kind: "issue",
      issue_state: "OPEN"
    }

    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(["PVTI_1"])}
    settings = Config.settings!()

    refute DispatchPolicy.dispatch_eligible?(issue, state, settings.tracker, settings)
  end

  test "dispatch_eligible allows open issues when no slot or dependency gate blocks them" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_dependency_gating_states: [],
      max_concurrent_agents: 2
    )

    settings = Config.settings!()

    issue = %Issue{
      id: "PVTI_1",
      identifier: "archelab/symphony#1",
      state: "Agent Ready",
      kind: "issue",
      issue_state: "OPEN"
    }

    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(), max_concurrent_agents: 2}

    assert DispatchPolicy.dispatch_eligible?(issue, state, settings.tracker, settings)
    assert DispatchPolicy.dispatch_slots_available?(issue, state, settings)
    assert DispatchPolicy.available_slots(state, settings) == 2
  end

  test "worker host selection prefers available hosts and reports capacity exhaustion" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["host-a", "host-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    settings = Config.settings!()

    state = %Orchestrator.State{
      running: %{
        "PVTI_1" => %{worker_host: "host-a"},
        "PVTI_2" => %{worker_host: "host-b"}
      },
      max_concurrent_agents: 3
    }

    assert DispatchPolicy.select_worker_host(state, "host-a", settings) == :no_worker_capacity

    state = %Orchestrator.State{running: %{"PVTI_1" => %{worker_host: "host-a"}}, max_concurrent_agents: 3}

    assert DispatchPolicy.select_worker_host(state, "host-b", settings) == "host-b"
    assert DispatchPolicy.worker_slots_available?(state, "host-b", settings)

    refute DispatchPolicy.worker_slots_available?(
             %Orchestrator.State{
               running: %{
                 "PVTI_1" => %{worker_host: "host-a"},
                 "PVTI_2" => %{worker_host: "host-b"}
               },
               max_concurrent_agents: 3
             },
             "host-a",
             settings
           )
  end

  test "dispatchable handles fallback issue shapes and cross-repo blockers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_dependency_gating_states: ["Agent Ready"],
      tracker_cross_repo_blockers: true
    )

    settings = Config.settings!()

    blocked = %Issue{
      id: "PVTI_1",
      identifier: "archelab/symphony#1",
      state: "Agent Ready",
      kind: "issue",
      issue_state: "OPEN",
      blocked_by: [%Issue.Blocker{id: "b1", identifier: "other/repo#1", state: "OPEN"}]
    }

    refute DispatchPolicy.dispatchable?(blocked, settings.tracker)
    refute DispatchPolicy.dispatchable?(%{state: nil, kind: "issue", issue_state: "OPEN"}, settings.tracker)
    assert DispatchPolicy.sort_issues_for_dispatch([:bad]) == [:bad]
  end

  test "slot helpers handle invalid issue states, unknown blocker shapes, and flat runtime settings" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_dependency_gating_states: ["Agent Ready"],
      tracker_cross_repo_blockers: false
    )

    settings = Config.settings!()

    issue = %Issue{
      id: "PVTI_1",
      identifier: "archelab/symphony#1",
      state: "Agent Ready",
      kind: "issue",
      issue_state: "OPEN",
      repository: %Issue.Repository{name: "symphony", owner: "archelab", name_with_owner: "archelab/symphony"},
      blocked_by: [%{state: "OPEN"}]
    }

    state = %Orchestrator.State{
      running: %{
        "PVTI_2" => %{issue: %{state: nil}},
        "PVTI_3" => %{issue: %{state: "Agent Ready"}}
      },
      claimed: MapSet.new(),
      max_concurrent_agents: 3
    }

    assert DispatchPolicy.dispatchable?(issue, settings.tracker)
    refute DispatchPolicy.dispatch_slots_available?(%{state: nil}, state, settings)

    state_limit_settings = %{
      agent: %{max_concurrent_agents: 10, max_concurrent_agents_by_state: %{"agent ready" => 1}},
      worker: settings.worker
    }

    refute DispatchPolicy.dispatch_slots_available?(%{state: "Agent Ready"}, state, state_limit_settings)
    assert DispatchPolicy.available_slots(%{running: %{}, max_concurrent_agents: nil}, %{max_concurrent_agents: 2}) == 2
    assert DispatchPolicy.select_worker_host(state, nil, %{ssh_hosts: []}) == nil

    assert DispatchPolicy.select_worker_host(state, nil, %{ssh_hosts: ["host-a"], max_concurrent_agents_per_host: nil}) ==
             "host-a"
  end
end
