defmodule SymphonyElixir.Orchestrator.ReconciliationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator.Reconciliation
  alias SymphonyElixir.Workflow

  test "classify_refresh stops missing and terminal issues" do
    tracker = Config.settings!().tracker
    running = %{blocked_by_snapshot: []}

    assert Reconciliation.classify_refresh(nil, running, tracker) ==
             {:stop, :reconciled_missing, false}

    assert Reconciliation.classify_refresh(%{state: "<closed>", blocked_by: []}, running, tracker) ==
             {:stop, :terminal_or_closed, true}

    assert Reconciliation.classify_refresh(%{state: "<merged>", blocked_by: []}, running, tracker) ==
             {:stop, :terminal_or_merged, true}
  end

  test "classify_refresh keeps active refresh and updates blocker snapshot" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Agent Ready", "In Progress"],
      tracker_dependency_gating_states: ["Agent Ready"]
    )

    tracker = Config.settings!().tracker
    running = %{blocked_by_snapshot: []}
    refresh = %{id: "PVTI_1", state: "In Progress", blocked_by: [%{id: "b1", state: "CLOSED"}]}

    assert {:keep, ^refresh} = Reconciliation.classify_refresh(refresh, running, tracker)
  end

  test "classify_refresh stops when a previously closed blocker reopens" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Agent Ready", "In Progress"],
      tracker_dependency_gating_states: ["In Progress"],
      tracker_gate_running_on_dependencies: true
    )

    tracker = Config.settings!().tracker

    running = %{
      issue_id: "PVTI_1",
      blocked_by_snapshot: [%{id: "b1", identifier: "archelab/symphony#1", state: "CLOSED"}]
    }

    refresh = %{
      id: "PVTI_1",
      state: "In Progress",
      blocked_by: [%{id: "b1", identifier: "archelab/symphony#1", state: "OPEN"}]
    }

    assert Reconciliation.classify_refresh(refresh, running, tracker) ==
             {:stop, :dependencies_reopened, false}
  end

  test "classify_refresh handles no-status, inactive, terminal, and malformed refresh results" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Agent Ready"],
      tracker_terminal_states: ["Done"]
    )

    tracker = Config.settings!().tracker

    assert Reconciliation.classify_refresh(%{state: "<no status>"}, %{}, tracker) == :keep
    assert Reconciliation.classify_refresh(%{state: "Done"}, %{}, tracker) == {:stop, :terminal_state, true}
    assert Reconciliation.classify_refresh(%{state: "Backlog"}, %{}, tracker) == {:stop, :inactive_state, false}
    assert Reconciliation.classify_refresh(%{}, %{}, tracker) == :keep
  end

  test "classify_refresh keeps running issues when blocker snapshots are not all closed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["In Progress"],
      tracker_dependency_gating_states: ["In Progress"],
      tracker_gate_running_on_dependencies: true
    )

    tracker = Config.settings!().tracker
    running = %{issue_id: "PVTI_1", blocked_by_snapshot: [%{id: "b1", state: "OPEN"}]}
    refresh = %{id: "PVTI_1", state: "In Progress", blocked_by: [%{id: "b1", state: "OPEN"}]}

    assert {:keep, ^refresh} = Reconciliation.classify_refresh(refresh, running, tracker)
  end

  test "classify_refresh ignores dependency reopening when refreshed issue id is unavailable" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["In Progress"],
      tracker_dependency_gating_states: ["In Progress"],
      tracker_gate_running_on_dependencies: true
    )

    tracker = Config.settings!().tracker
    running = %{issue_id: "PVTI_1", blocked_by_snapshot: [%{id: "b1", state: "CLOSED"}]}
    refresh = %{state: "In Progress", blocked_by: [%{id: "b1", state: "OPEN"}]}

    assert {:keep, ^refresh} = Reconciliation.classify_refresh(refresh, running, tracker)
    assert Reconciliation.classify_refresh(%{state: nil}, running, tracker) == {:stop, :inactive_state, false}
  end
end
