defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  # When workpad is enabled in a test fixture WORKFLOW.md but the test author
  # did not explicitly pass a `:prompt` override, swap in a prompt that
  # references the canonical workpad Liquid variables. SPEC §11.8.9 (enforced
  # by `Workflow.load/1`) requires the prompt template to reference at least
  # one of the five workpad vars when `agent.workpad.enabled: true`. Keeping
  # the default in lock-step with the validation keeps existing workpad-enabled
  # tests authoring-light without each having to embed a workpad prompt
  # boilerplate just to satisfy config-time validation.
  @workpad_workflow_prompt """
  You are an agent for this repository.

  Workpad context (SPEC §11.8):
  thread_id={{ thread_id }} subject_id={{ subject_id }}
  dispatched_at={{ dispatched_at }} model={{ model }}
  {% if prior_sessions %}prior_sessions_count={{ prior_sessions.size }}{% endif %}
  """

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.Github.Issue
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    # `Supervisor.which_children/1` can exit with `:noproc` (supervisor never
    # started) or `:shutdown` (supervisor mid-teardown). Treat both as "no
    # HTTP server to stop". Without this guard, a setup that runs while
    # another test is restarting a sibling child (WorkflowStore, Orchestrator,
    # PubSub) cascades a `GenServer.call ... :which_children EXIT` into every
    # subsequent test in the suite.
    children =
      try do
        Supervisor.which_children(SymphonyElixir.Supervisor)
      catch
        :exit, _ -> []
      end

    case Enum.find(children, fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        try do
          :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)
        catch
          :exit, _ -> :ok
        end

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "github",
          tracker_endpoint: "https://api.github.com/graphql",
          tracker_api_token: "ghp_test_token",
          tracker_owner: "archelab",
          tracker_owner_type: "organization",
          tracker_project_number: 1,
          tracker_project_id: nil,
          tracker_repo: "symphony",
          tracker_status_field: "Status",
          tracker_include_kinds: ["issue", "pull_request"],
          tracker_active_states: ["Agent Ready", "In Progress", "Rework"],
          tracker_terminal_states: ["Done"],
          tracker_dependency_gating_states: ["Agent Ready"],
          tracker_gate_running_on_dependencies: nil,
          tracker_cross_repo_blockers: nil,
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          agent_workpad_enabled: nil,
          agent_workpad_version: nil,
          agent_workpad_max_sessions_visible: nil,
          agent_workpad_update_throttle_turns: nil,
          codex_command: "codex app-server",
          codex_model: nil,
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: nil
        ],
        overrides
      )

    config =
      case Keyword.get(config, :prompt) do
        nil ->
          default_prompt =
            if Keyword.get(config, :agent_workpad_enabled) == true,
              do: @workpad_workflow_prompt,
              else: @workflow_prompt

          Keyword.put(config, :prompt, default_prompt)

        _ ->
          config
      end

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_owner = Keyword.get(config, :tracker_owner)
    tracker_owner_type = Keyword.get(config, :tracker_owner_type)
    tracker_project_number = Keyword.get(config, :tracker_project_number)
    tracker_project_id = Keyword.get(config, :tracker_project_id)
    tracker_repo = Keyword.get(config, :tracker_repo)
    tracker_status_field = Keyword.get(config, :tracker_status_field)
    tracker_include_kinds = Keyword.get(config, :tracker_include_kinds)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    tracker_dependency_gating_states = Keyword.get(config, :tracker_dependency_gating_states)
    tracker_gate_running_on_dependencies = Keyword.get(config, :tracker_gate_running_on_dependencies)
    tracker_cross_repo_blockers = Keyword.get(config, :tracker_cross_repo_blockers)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    agent_workpad_enabled = Keyword.get(config, :agent_workpad_enabled)
    agent_workpad_version = Keyword.get(config, :agent_workpad_version)
    agent_workpad_max_sessions_visible = Keyword.get(config, :agent_workpad_max_sessions_visible)
    agent_workpad_update_throttle_turns = Keyword.get(config, :agent_workpad_update_throttle_turns)
    codex_command = Keyword.get(config, :codex_command)
    codex_model = Keyword.get(config, :codex_model)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_token: #{yaml_value(tracker_api_token)}",
        "  owner: #{yaml_value(tracker_owner)}",
        "  owner_type: #{yaml_value(tracker_owner_type)}",
        "  project_number: #{yaml_value(tracker_project_number)}",
        "  project_id: #{yaml_value(tracker_project_id)}",
        "  repo: #{yaml_value(tracker_repo)}",
        "  status_field: #{yaml_value(tracker_status_field)}",
        "  include_kinds: #{yaml_value(tracker_include_kinds)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "  dependency_gating_states: #{yaml_value(tracker_dependency_gating_states)}",
        optional_yaml("  gate_running_on_dependencies", tracker_gate_running_on_dependencies),
        optional_yaml("  cross_repo_blockers", tracker_cross_repo_blockers),
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        workpad_yaml(
          agent_workpad_enabled,
          agent_workpad_version,
          agent_workpad_max_sessions_visible,
          agent_workpad_update_throttle_turns
        ),
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        optional_yaml("  model", codex_model),
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp optional_yaml(_key, nil), do: nil
  defp optional_yaml(key, value), do: "#{key}: #{yaml_value(value)}"

  defp workpad_yaml(nil, nil, nil, nil), do: nil

  defp workpad_yaml(enabled, version, max_sessions_visible, update_throttle_turns) do
    [
      "  workpad:",
      optional_yaml("    enabled", enabled),
      optional_yaml("    version", version),
      optional_yaml("    max_sessions_visible", max_sessions_visible),
      optional_yaml("    update_throttle_turns", update_throttle_turns)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
