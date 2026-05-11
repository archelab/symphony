defmodule SymphonyElixir.Workpad.TemplateValidationTest do
  @moduledoc """
  SPEC §11.8.9 — `agent.workpad.enabled: true` MUST require the workflow
  prompt template to reference at least one of the five workpad-bridging
  Liquid variables (`thread_id`, `subject_id`, `prior_sessions`,
  `dispatched_at`, `model`).

  These tests exercise the `Workflow.load/1` boundary directly with bespoke
  on-disk WORKFLOW.md fixtures — they do NOT use `SymphonyElixir.TestSupport`,
  which auto-injects a workpad-aware default prompt whenever workpad is
  enabled. That auto-injection would mask the very regression these tests
  guard against.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workpad.Protocol

  @valid_front_matter """
  ---
  tracker:
    kind: github
    api_token: ghp_test
    owner: archelab
    owner_type: organization
    project_number: 1
    repo: symphony
    status_field: Status
    include_kinds: [issue, pull_request]
    active_states: ["Agent Ready", "In Progress", "Rework"]
    terminal_states: ["Done"]
    dependency_gating_states: ["Agent Ready"]
  polling:
    interval_ms: 30000
  workspace:
    root: /tmp/symphony_workspaces
  agent:
    max_concurrent_agents: 4
    max_turns: 20
    workpad:
      enabled: true
      version: v1
      max_sessions_visible: 20
      update_throttle_turns: 3
  codex:
    command: codex app-server
    model: "gpt-5.5"
    approval_policy: never
    thread_sandbox: workspace-write
  ---
  """

  # SPEC §11.8.10 PR4: session-summary ALSO defaults to enabled at the schema
  # level, so opting out of the workpad is no longer sufficient — we must
  # also opt out of the summary protocol to keep this "workpad disabled, no
  # validation fires" fixture honest. The replacement injects the
  # `session_summary` block at the same indent as `workpad` (2 spaces under
  # `agent:`, 4 spaces for fields).
  @disabled_front_matter @valid_front_matter
                         |> String.replace("enabled: true", "enabled: false")
                         |> String.replace(
                           "    update_throttle_turns: 3\n",
                           "    update_throttle_turns: 3\n  session_summary:\n    enabled: false\n"
                         )

  defp write_workflow!(body) do
    dir = Path.join(System.tmp_dir!(), "symphony-template-validation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "WORKFLOW.md")
    File.write!(path, body)
    on_exit_cleanup(dir)
    path
  end

  defp on_exit_cleanup(dir) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
  end

  test "workpad enabled + template references {{ thread_id }} → loads successfully" do
    path = write_workflow!(@valid_front_matter <> "Workpad subject: {{ thread_id }} for {{ issue.identifier }}\n")

    assert {:ok, %{prompt_template: prompt}} = Workflow.load(path)
    assert prompt =~ "{{ thread_id }}"
  end

  test "workpad enabled + template references {% for s in prior_sessions %} → loads successfully" do
    body =
      @valid_front_matter <>
        """
        {% if prior_sessions %}
        {% for s in prior_sessions %}- {{ s.thread_id }}
        {% endfor %}
        {% endif %}
        """

    path = write_workflow!(body)

    assert {:ok, _loaded} = Workflow.load(path)
  end

  test "workpad enabled + template references NONE of the five → {:error, {:invalid_workflow_config, msg}}" do
    body = @valid_front_matter <> "You are an agent. No workpad context referenced here.\n"

    path = write_workflow!(body)

    assert {:error, {:invalid_workflow_config, message}} = Workflow.load(path)
    assert message =~ "§11.8.9"
    assert message =~ "thread_id"
    assert message =~ "subject_id"
    assert message =~ "prior_sessions"
    assert message =~ "dispatched_at"
    assert message =~ "model"
  end

  test "workpad disabled + template references NONE → loads successfully (validation only fires when enabled)" do
    body = @disabled_front_matter <> "You are an agent. No workpad context referenced.\n"

    path = write_workflow!(body)

    assert {:ok, _loaded} = Workflow.load(path)
  end

  test "Workpad.Protocol.prompt_variables/0 returns exactly the five expected names (lock-step)" do
    assert Protocol.prompt_variables() == ~w(thread_id subject_id prior_sessions dispatched_at model)
  end

  # ── Session-summary template validation (SPEC §11.8.10) ──────────────────
  #
  # `validate_session_summary_template/1` runs INDEPENDENTLY of the workpad
  # validation: a deployment can have summary-on / workpad-off (and vice
  # versa). The required template var set for summary is narrower than for
  # the workpad — `thread_id`, `subject_id`, `dispatched_at` — because those
  # three suffice to render the §11.8.10 header (Session, Dispatched) and
  # the marker payload.

  @summary_only_front_matter """
  ---
  tracker:
    kind: github
    api_token: ghp_test
    owner: archelab
    owner_type: organization
    project_number: 1
    repo: symphony
    status_field: Status
    include_kinds: [issue, pull_request]
    active_states: ["Agent Ready", "In Progress", "Rework"]
    terminal_states: ["Done"]
    dependency_gating_states: ["Agent Ready"]
  polling:
    interval_ms: 30000
  workspace:
    root: /tmp/symphony_workspaces
  agent:
    max_concurrent_agents: 4
    max_turns: 20
    workpad:
      enabled: false
    session_summary:
      enabled: true
  codex:
    command: codex app-server
    model: "gpt-5.5"
    approval_policy: never
    thread_sandbox: workspace-write
  ---
  """

  test "session-summary enabled (workpad off) + template references {{ thread_id }} → loads" do
    path = write_workflow!(@summary_only_front_matter <> "Session id: {{ thread_id }}\n")
    assert {:ok, _loaded} = Workflow.load(path)
  end

  test "session-summary enabled (workpad off) + template references NONE → §11.8.10 error" do
    body = @summary_only_front_matter <> "You are an agent. No session-id context referenced here.\n"
    path = write_workflow!(body)

    assert {:error, {:invalid_workflow_config, message}} = Workflow.load(path)
    assert message =~ "§11.8.10"
    assert message =~ "session_summary"
    assert message =~ "thread_id"
    assert message =~ "subject_id"
    assert message =~ "dispatched_at"
  end

  test "session-summary disabled + workpad disabled → no template validation fires" do
    body = """
    ---
    tracker:
      kind: github
      api_token: ghp_test
      owner: archelab
      owner_type: organization
      project_number: 1
      repo: symphony
      status_field: Status
      include_kinds: [issue, pull_request]
      active_states: ["Agent Ready"]
      terminal_states: ["Done"]
      dependency_gating_states: ["Agent Ready"]
    polling:
      interval_ms: 30000
    workspace:
      root: /tmp/symphony_workspaces
    agent:
      max_concurrent_agents: 4
      max_turns: 20
      workpad:
        enabled: false
      session_summary:
        enabled: false
    codex:
      command: codex app-server
      approval_policy: never
      thread_sandbox: workspace-write
    ---
    You are an agent. No workpad and no session-summary context referenced.
    """

    path = write_workflow!(body)
    assert {:ok, _loaded} = Workflow.load(path)
  end

  test "PromptBuilder source emits exactly Workpad.Protocol.prompt_variables/0 (lock-step)" do
    # Static lock-step check: scan the PromptBuilder source for the
    # `Map.put("<var>", …)` calls inside `maybe_put_workpad_vars` and assert
    # the set equals Protocol.prompt_variables(). If either side drifts
    # (PromptBuilder drops a key or Protocol adds a sixth name), this test
    # fails — surfacing the desync long before a runtime symptom would.
    #
    # Async-safe: pure file read, no global state touched.
    prompt_builder_source =
      Path.expand("../../../lib/symphony_elixir/prompt_builder.ex", __DIR__)
      |> File.read!()

    emitted =
      Regex.scan(~r/Map\.put\(\s*"([a-z_]+)"\s*,/, prompt_builder_source)
      |> Enum.map(fn [_, name] -> name end)
      |> MapSet.new()

    declared = MapSet.new(Protocol.prompt_variables())

    # PromptBuilder may put non-workpad keys (e.g. "issue") on the context map
    # too. Lock-step requires that EVERY declared variable is emitted; extra
    # emitted keys (like "issue") are fine.
    assert MapSet.subset?(declared, emitted),
           "PromptBuilder is missing Map.put for workpad variables: " <>
             inspect(MapSet.difference(declared, emitted))
  end
end
