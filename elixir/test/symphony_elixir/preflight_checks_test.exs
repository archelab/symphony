defmodule SymphonyElixir.PreflightChecksTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.PreflightChecks

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_client)
      Application.delete_env(:symphony_elixir, :github_graphql_mutation_allowlist)
      Application.delete_env(:symphony_elixir, :preflight_checks)
    end)

    :ok
  end

  test "application preflight default is disabled under test but can be overridden" do
    assert SymphonyElixir.Application.preflight_checks_enabled?() == false

    Application.put_env(:symphony_elixir, :preflight_checks, true)
    assert SymphonyElixir.Application.preflight_checks_enabled?() == true

    Application.put_env(:symphony_elixir, :preflight_checks, false)
    assert SymphonyElixir.Application.preflight_checks_enabled?() == false
  end

  test "checks GitHub auth with viewer query before boot" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_valid"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_client, fn query, variables, opts ->
      send(parent, {:github_preflight, query, variables, opts})
      {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}}
    end)

    assert :ok = PreflightChecks.run()

    assert_receive {:github_preflight, query, %{}, opts}
    assert query =~ "viewer"
    assert opts[:token] == "ghp_preflight_valid"
  end

  test "run! accepts the happy path" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_valid"
    )

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}}
    end)

    assert :ok = PreflightChecks.run!()
  end

  test "application preflight runner delegates to startup checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_valid"
    )

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}}
    end)

    Application.put_env(:symphony_elixir, :preflight_checks, true)
    assert :ok = SymphonyElixir.Application.maybe_run_preflight_checks()
  end

  test "refuses boot on GitHub permission denied with tracker scopes hint" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_invalid"
    )

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      {:error, {:tracker_permission_denied, %{http: 401}}}
    end)

    log =
      capture_log(fn ->
        assert_raise RuntimeError, ~r/GITHUB_TOKEN scopes hint/, fn ->
          PreflightChecks.run!()
        end
      end)

    assert log =~ ":tracker_permission_denied"
    assert log =~ "GITHUB_TOKEN scopes hint"
  end

  test "returns an explicit error when viewer payload is malformed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_weird"
    )

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"viewer" => nil}}}
    end)

    assert {:error, {:github_unknown_payload, %{"data" => %{"viewer" => nil}}}} = PreflightChecks.run()
  end

  test "run! raises and logs non-permission GitHub errors" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_timeout"
    )

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      {:error, {:github_api_request, :timeout}}
    end)

    log =
      capture_log(fn ->
        assert_raise RuntimeError, ~r/:github_api_request/, fn ->
          PreflightChecks.run!()
        end
      end)

    assert log =~ "github_api_request"
  end

  test "warns when workpad is enabled but publishing mutations are not allowlisted" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_valid",
      agent_workpad_enabled: true,
      agent_session_summary_enabled: false,
      codex_model: "gpt-test"
    )

    Application.put_env(:symphony_elixir, :github_graphql_mutation_allowlist, ~w(addComment))

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}}
    end)

    log = capture_log(fn -> assert :ok = PreflightChecks.run() end)

    assert log =~ "createRef"
    assert log =~ "createPullRequest"
    assert log =~ "will fail to publish"
  end

  test "warns when sandbox is read-only and approval policy is never" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_valid",
      codex_thread_sandbox: "read-only",
      codex_approval_policy: "never"
    )

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}}
    end)

    log = capture_log(fn -> assert :ok = PreflightChecks.run() end)

    assert log =~ "read-only"
    assert log =~ "approval_policy=never"
    assert log =~ "unable to write"
  end

  test "warns when GitHub tracker uses a turn sandbox without network access" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_valid",
      codex_turn_sandbox_policy: %{type: "workspaceWrite", networkAccess: false}
    )

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}}
    end)

    log = capture_log(fn -> assert :ok = PreflightChecks.run() end)

    assert log =~ "networkAccess"
    assert log =~ "gh commands will fail"
  end

  test "does not warn when GitHub tracker uses network-enabled turn sandbox" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_preflight_valid",
      codex_turn_sandbox_policy: %{type: "workspaceWrite", networkAccess: true}
    )

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}}
    end)

    log = capture_log(fn -> assert :ok = PreflightChecks.run() end)

    refute log =~ "networkAccess"
  end

  test "skips GitHub auth network check for memory tracker" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)

    Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
      flunk("memory tracker should not call GitHub")
    end)

    assert :ok = PreflightChecks.run()
  end
end
