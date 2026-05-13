defmodule SymphonyElixir.Workpad.DefaultWorkflowCompatTest do
  @moduledoc """
  SPEC §11.8.9 (PR4 amendment): the default `elixir/WORKFLOW.md` ships with
  the workpad protocol enabled. This test pins that contract — the stock
  template MUST reference at least one workpad Liquid variable AND MUST
  parse successfully under the new default (workpad-enabled) config.

  If a future change flips the default back to disabled, this test fails
  loud — a deliberate regression gate so the PR4 default-on amendment is
  not silently reverted.

  Render-side coverage of the same template (Solid strict mode rejecting
  unbound workpad variables, workpad-enabled bridge emitting the five vars)
  lives in `template_validation_test.exs` and `protocol_integration_test.exs`.
  This test focuses on the *shipped* default — the very file at
  `elixir/WORKFLOW.md` — to keep the PR4 amendment fixed in tree.
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  @default_workflow Path.expand("../../../WORKFLOW.md", __DIR__)

  test "default WORKFLOW.md references the workpad Liquid variables (SPEC §11.8.9)" do
    body = File.read!(@default_workflow)

    # The reference template surfaces every workpad variable so operators
    # copying it do not have to read SPEC §11.8.5 to discover the bridge
    # contract.
    assert body =~ "{{ thread_id }}"
    assert body =~ "{{ subject_id }}"
    assert body =~ "{{ dispatched_at }}"
    assert body =~ "{{ model }}"
    assert body =~ "{% if prior_sessions %}"
    assert body =~ "symphony-workpad:v1"
  end

  test "default WORKFLOW.md sets agent.workpad.enabled: true + codex.model (SPEC §11.8.5/§11.8.9)" do
    body = File.read!(@default_workflow)

    # Front matter contract:
    #   - agent.workpad.enabled: true (the PR4 default flip)
    #   - codex.model: <string> (required by validate_workpad_requires_model/1)
    assert body =~ ~r/^\s*workpad:\s*$/m
    assert body =~ ~r/^\s*enabled:\s*true\b/m
    assert body =~ ~r/^\s*model:\s*"[^"]+"/m
  end

  test "default WORKFLOW.md tells agents to claim work and keep dependency gating active" do
    body = File.read!(@default_workflow)

    assert body =~ ~s(dependency_gating_states: ["Agent Ready", "In Progress"])
    assert body =~ "### Status → In Progress"
    assert body =~ "claim the item before code"
    assert body =~ "updateProjectV2ItemFieldValue"
  end

  test "default WORKFLOW.md loads successfully under §11.8.9 template validation" do
    # `Workflow.load/1` runs `validate_workpad_template/1` against the parsed
    # front matter + prompt body. The stock template must satisfy it without
    # any preconditioning — failing here would mean the template references
    # zero workpad vars while front matter says `enabled: true`, which is
    # exactly the misconfiguration §11.8.9 fails-loud against.
    assert {:ok, %{config: config, prompt_template: prompt}} = Workflow.load(@default_workflow)

    assert get_in(config, ["agent", "workpad", "enabled"]) == true
    assert get_in(config, ["codex", "model"]) |> is_binary()
    assert prompt =~ "{{ thread_id }}"
  end
end
