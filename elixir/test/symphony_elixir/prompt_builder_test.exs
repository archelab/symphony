defmodule SymphonyElixir.PromptBuilderTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Github.Issue, PromptBuilder}

  test "renders new domain shape including pr.* and last_run_completed_at" do
    issue =
      Issue.new(%{
        id: "PVTI_x",
        identifier: "archelab/symphony#7",
        kind: "pull_request",
        title: "Fix",
        state: "Rework",
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        number: 7,
        branch_name: "fix-x",
        labels: ["bug"],
        blocked_by: [],
        url: "https://github.com/archelab/symphony/pull/7",
        issue_state: "OPEN",
        pr: %{state: "OPEN", merged: false, is_draft: false, base_ref_name: "main"}
      })

    template =
      "{{ issue.identifier }} on {{ issue.pr.base_ref_name }} (attempt={{ attempt }}, since={{ last_run_completed_at }})"

    assert {:ok, rendered} =
             PromptBuilder.render(template,
               issue: issue,
               attempt: 2,
               last_run_completed_at: "2026-05-09T20:00:00Z"
             )

    assert rendered ==
             "archelab/symphony#7 on main (attempt=2, since=2026-05-09T20:00:00Z)"
  end

  test "strict mode rejects unknown variable" do
    issue = sample_issue()
    template = "{{ issue.bogus_field }}"
    assert {:error, _} = PromptBuilder.render(template, issue: issue, attempt: nil)
  end

  test "render/2 works without an `:issue` key in the context" do
    assert {:ok, "attempt=3 since=2026-01-01T00:00:00Z"} =
             PromptBuilder.render(
               "attempt={{ attempt }} since={{ last_run_completed_at }}",
               attempt: 3,
               last_run_completed_at: "2026-01-01T00:00:00Z"
             )
  end

  test "render/2 returns {:error, _} on template parse failures" do
    # Unterminated `{%` tag — Solid.parse/1 yields {:error, ...}
    assert {:error, _} = PromptBuilder.render("{% if attempt", issue: sample_issue(), attempt: 1)
  end

  defp sample_issue do
    Issue.new(%{
      id: "PVTI_y",
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
  end
end
