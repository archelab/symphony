defmodule SymphonyElixir.Workpad.DefaultWorkflowCompatTest do
  @moduledoc """
  SPEC §11.8 backward-compatibility guard.

  The default `elixir/WORKFLOW.md` MUST NOT reference any workpad prompt
  variable, and rendering it under the default (workpad-disabled) config MUST
  succeed in Solid strict mode. This is the byte-identical-rendering proof:
  if anything in `WORKFLOW.md` or `PromptBuilder` regresses to emit workpad
  vars by default, this test fails.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Github.Issue, PromptBuilder, Workflow}

  @default_workflow Path.expand("../../../WORKFLOW.md", __DIR__)

  test "default WORKFLOW.md does not reference workpad variables" do
    body = File.read!(@default_workflow)

    refute body =~ "{{ thread_id"
    refute body =~ "{{ subject_id"
    refute body =~ "{{ dispatched_at"
    refute body =~ "{{ prior_sessions"
    refute body =~ "{{ model"
    refute body =~ "symphony-workpad"
  end

  test "default WORKFLOW.md prompt renders under default (workpad disabled) config" do
    {:ok, %{prompt_template: prompt}} = Workflow.load(@default_workflow)

    issue =
      Issue.new(%{
        id: "PVTI_x",
        identifier: "archelab/symphony#1",
        kind: "issue",
        title: "x",
        state: "Agent Ready",
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        number: 1,
        labels: [],
        blocked_by: [],
        issue_state: "OPEN"
      })

    assert {:ok, _rendered} =
             PromptBuilder.render(prompt,
               issue: issue,
               attempt: 1,
               last_run_completed_at: nil
             )
  end
end
