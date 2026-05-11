defmodule SymphonyElixir.PromptBuilderTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Github.Issue, PromptBuilder}

  defp enable_workpad! do
    workflow_file = Application.get_env(:symphony_elixir, :workflow_file_path)
    write_workflow_file!(workflow_file, agent_workpad_enabled: true, codex_model: "gpt-5.5")
  end

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

  describe "workpad variables (SPEC §11.8.5)" do
    test "disabled + issue kind: strict mode rejects template referencing thread_id" do
      issue = sample_issue(kind: "issue", content_id: "I_xyz")
      template = "{{ thread_id }}"

      assert {:error, _reason} =
               PromptBuilder.render(template,
                 issue: issue,
                 attempt: 1,
                 thread_id: "thr-1",
                 dispatched_at: "2026-05-11T20:00:00Z",
                 model: "gpt-5.5",
                 prior_sessions: []
               )
    end

    test "enabled + issue kind: all five vars present, prior_sessions renders" do
      enable_workpad!()
      issue = sample_issue(kind: "issue", content_id: "I_xyz")

      template =
        "thread={{ thread_id }} subject={{ subject_id }} model={{ model }} dispatched={{ dispatched_at }} prior_count={{ prior_sessions.size }} prior_thread={{ prior_sessions[0].thread_id }} prior_stop={{ prior_sessions[0].stop_reason }}"

      prior = [
        %{
          thread_id: "thr-0",
          attempt: 1,
          dispatched_at: "2026-05-10T20:00:00Z",
          completed_at: "2026-05-10T20:30:00Z",
          duration_ms: 1_800_000,
          # Cover nil pass-through (orchestrator may not always capture a model).
          model: nil,
          stop_reason: :agent_exit_normal
        }
      ]

      assert {:ok, rendered} =
               PromptBuilder.render(template,
                 issue: issue,
                 attempt: 2,
                 thread_id: "thr-1",
                 dispatched_at: "2026-05-11T20:00:00Z",
                 model: "gpt-5.5",
                 prior_sessions: prior
               )

      assert rendered =~ "thread=thr-1"
      assert rendered =~ "subject=I_xyz"
      assert rendered =~ "model=gpt-5.5"
      assert rendered =~ "dispatched=2026-05-11T20:00:00Z"
      assert rendered =~ "prior_count=1"
      assert rendered =~ "prior_thread=thr-0"
      assert rendered =~ "prior_stop=agent_exit_normal"
    end

    test "enabled + pull_request kind: all 5 workpad vars present and non-empty (SPEC §17.8)" do
      enable_workpad!()

      issue =
        sample_issue(
          kind: "pull_request",
          content_id: "PR_xyz",
          pr: %{state: "OPEN", merged: false, is_draft: false, base_ref_name: "main"}
        )

      prior = [
        %{
          thread_id: "thr-prior",
          attempt: 1,
          dispatched_at: "2026-05-10T20:00:00Z",
          completed_at: "2026-05-10T20:30:00Z",
          duration_ms: 1_800_000,
          model: "gpt-5.5",
          stop_reason: :agent_exit_normal
        }
      ]

      template =
        "tid={{ thread_id }} sid={{ subject_id }} m={{ model }} d={{ dispatched_at }} " <>
          "n={{ prior_sessions.size }} pt={{ prior_sessions[0].thread_id }}"

      assert {:ok, rendered} =
               PromptBuilder.render(template,
                 issue: issue,
                 attempt: 2,
                 thread_id: "thr-1",
                 dispatched_at: "2026-05-11T20:00:00Z",
                 model: "gpt-5.5",
                 prior_sessions: prior
               )

      assert rendered =~ "tid=thr-1"
      assert rendered =~ "sid=PR_xyz"
      assert rendered =~ "m=gpt-5.5"
      assert rendered =~ "d=2026-05-11T20:00:00Z"
      assert rendered =~ "n=1"
      assert rendered =~ "pt=thr-prior"
    end

    test "enabled + draft_issue kind: workpad vars absent, strict rejects template" do
      enable_workpad!()
      issue = sample_issue(kind: "draft_issue", content_id: "DI_xyz")
      template = "{{ thread_id }}"

      assert {:error, _reason} =
               PromptBuilder.render(template,
                 issue: issue,
                 attempt: 1,
                 thread_id: "thr-1",
                 dispatched_at: "2026-05-11T20:00:00Z",
                 model: "gpt-5.5",
                 prior_sessions: []
               )
    end
  end

  defp sample_issue(overrides \\ []) do
    base = %{
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
    }

    Issue.new(Map.merge(base, Map.new(overrides)))
  end
end
