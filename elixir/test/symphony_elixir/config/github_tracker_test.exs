defmodule SymphonyElixir.Config.GithubTrackerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  # SPEC §11.8.9 + §11.8.10 PR4 amendment: both `agent.workpad.enabled` AND
  # `agent.session_summary.enabled` default to `true`, each forcing its own
  # cross-validation (requires `codex.model`). These tracker-focused tests
  # pre-date both features and assert behaviors orthogonal to them, so we
  # explicitly opt out of BOTH here. Workpad behavior is exercised in
  # `Config.WorkpadTest`; session-summary behavior in
  # `Config.SessionSummaryTest`.
  defp parse(config) do
    agent = Map.get(config, "agent", %{})
    workpad = Map.merge(%{"enabled" => false}, Map.get(agent, "workpad", %{}))
    summary = Map.merge(%{"enabled" => false}, Map.get(agent, "session_summary", %{}))

    Schema.parse(
      Map.put(
        config,
        "agent",
        agent |> Map.put("workpad", workpad) |> Map.put("session_summary", summary)
      )
    )
  end

  test "parses a minimal GitHub tracker config" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "ghp_test",
        "owner" => "archelab",
        "owner_type" => "organization",
        "project_number" => 1,
        "repo" => "symphony"
      }
    }

    assert {:ok, settings} = parse(config)
    assert settings.tracker.kind == "github"
    assert settings.tracker.endpoint == "https://api.github.com/graphql"
    assert settings.tracker.api_token == "ghp_test"
    assert settings.tracker.owner == "archelab"
    assert settings.tracker.owner_type == "organization"
    assert settings.tracker.project_number == 1
    assert settings.tracker.repo == "symphony"
    assert settings.tracker.status_field == "Status"
    assert settings.tracker.include_kinds == ["issue", "pull_request"]
    assert settings.tracker.active_states == ["Todo", "In Progress"]
    assert settings.tracker.terminal_states == ["Done"]
    assert settings.tracker.dependency_gating_states == ["Todo"]
    assert settings.tracker.cross_repo_blockers == true
    assert settings.tracker.gate_running_on_dependencies == false
  end

  test "resolves $GITHUB_TOKEN env reference" do
    previous = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "ghp_resolved")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("GITHUB_TOKEN")
        value -> System.put_env("GITHUB_TOKEN", value)
      end
    end)

    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "$GITHUB_TOKEN",
        "owner" => "archelab",
        "project_number" => 1
      }
    }

    assert {:ok, settings} = parse(config)
    assert settings.tracker.api_token == "ghp_resolved"
  end

  test "accepts project_id and ignores owner_type for resolution" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "ghp_test",
        "project_id" => "PVT_kwDODDTPxM4BXSCK"
      }
    }

    assert {:ok, settings} = parse(config)
    assert settings.tracker.project_id == "PVT_kwDODDTPxM4BXSCK"
    assert settings.tracker.project_number == nil
  end

  test "rejects neither project_id nor project_number" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "ghp_test",
        "owner" => "archelab"
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = parse(config)
    assert message =~ "project_id"
  end

  test "rejects unknown owner_type" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "ghp_test",
        "owner" => "archelab",
        "owner_type" => "team",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, _}} = parse(config)
  end

  test "rejects unknown tracker kind with unsupported_tracker_kind" do
    # Schema.@valid_kinds is ~w(github memory).
    config = %{
      "tracker" => %{
        "kind" => "jira",
        "api_token" => "ghp_test",
        "owner" => "archelab",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = parse(config)
    assert message =~ "unsupported_tracker_kind"
  end

  test "rejects github kind with missing api_token" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "owner" => "archelab",
        "owner_type" => "organization",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = parse(config)
    assert message =~ "missing_tracker_api_token"
  end

  test "rejects github kind with empty api_token after env resolution" do
    previous = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("GITHUB_TOKEN")
        value -> System.put_env("GITHUB_TOKEN", value)
      end
    end)

    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "$GITHUB_TOKEN",
        "owner" => "archelab",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = parse(config)
    assert message =~ "missing_tracker_api_token"
  end

  test "parses optional server block (port + host)" do
    config = %{
      "tracker" => github_tracker_attrs(),
      "server" => %{"port" => 4001, "host" => "0.0.0.0"}
    }

    assert {:ok, settings} = parse(config)
    assert settings.server.port == 4001
    assert settings.server.host == "0.0.0.0"
  end

  test "rejects server.port < 0" do
    config = %{
      "tracker" => github_tracker_attrs(),
      "server" => %{"port" => -1}
    }

    assert {:error, {:invalid_workflow_config, message}} = parse(config)
    assert message =~ "server.port"
  end

  test "workspace.root resolves $VAR env references and falls back to default for missing/empty envs" do
    missing_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"

    previous_missing = System.get_env(missing_env)
    System.delete_env(missing_env)

    on_exit(fn ->
      case previous_missing do
        nil -> System.delete_env(missing_env)
        value -> System.put_env(missing_env, value)
      end
    end)

    # `:missing` branch — env var not set
    config = %{
      "tracker" => github_tracker_attrs(),
      "workspace" => %{"root" => "$#{missing_env}"}
    }

    assert {:ok, settings} = parse(config)
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    # `""` branch — empty string passed explicitly
    assert {:ok, settings} =
             parse(%{
               "tracker" => github_tracker_attrs(),
               "workspace" => %{"root" => ""}
             })

    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "workspace.root preserves a literal path when env reference syntax does not match" do
    config = %{
      "tracker" => github_tracker_attrs(),
      "workspace" => %{"root" => "$!!invalid_env_ref"}
    }

    assert {:ok, settings} = parse(config)
    assert settings.workspace.root == "$!!invalid_env_ref"
  end

  test "workspace.root resolves to env value when env is set" do
    set_env = "SYMP_SET_WORKSPACE_#{System.unique_integer([:positive])}"
    previous = System.get_env(set_env)
    System.put_env(set_env, "/tmp/symphony-resolved-workspace")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env(set_env)
        value -> System.put_env(set_env, value)
      end
    end)

    config = %{
      "tracker" => github_tracker_attrs(),
      "workspace" => %{"root" => "$#{set_env}"}
    }

    assert {:ok, settings} = parse(config)
    assert settings.workspace.root == "/tmp/symphony-resolved-workspace"
  end

  test "tracker.api_token falls back to GITHUB_TOKEN env when the configured $VAR is unset" do
    missing_env = "SYMP_MISSING_TOKEN_#{System.unique_integer([:positive])}"
    previous_missing = System.get_env(missing_env)
    previous_github = System.get_env("GITHUB_TOKEN")

    System.delete_env(missing_env)
    System.put_env("GITHUB_TOKEN", "ghp_fallback_token")

    on_exit(fn ->
      case previous_missing do
        nil -> System.delete_env(missing_env)
        value -> System.put_env(missing_env, value)
      end

      case previous_github do
        nil -> System.delete_env("GITHUB_TOKEN")
        value -> System.put_env("GITHUB_TOKEN", value)
      end
    end)

    config = %{
      "tracker" => Map.merge(github_tracker_attrs(), %{"api_token" => "$#{missing_env}"})
    }

    assert {:ok, settings} = parse(config)
    assert settings.tracker.api_token == "ghp_fallback_token"
  end

  test "memory tracker normalizes api_token to nil when api_token is unset and GITHUB_TOKEN is unset" do
    previous_github = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      case previous_github do
        nil -> System.delete_env("GITHUB_TOKEN")
        value -> System.put_env("GITHUB_TOKEN", value)
      end
    end)

    # Memory tracker does not require api_token. The finalize step still calls
    # the secret resolver with `(nil, nil)`, exercising the non-binary
    # normalize_secret_value clause.
    config = %{"tracker" => %{"kind" => "memory"}}

    assert {:ok, settings} = parse(config)
    assert settings.tracker.api_token == nil
  end

  test "tracker.api_token resolves $VAR and returns nil for empty env strings" do
    empty_env = "SYMP_EMPTY_TOKEN_#{System.unique_integer([:positive])}"
    previous_empty = System.get_env(empty_env)
    System.put_env(empty_env, "")

    on_exit(fn ->
      case previous_empty do
        nil -> System.delete_env(empty_env)
        value -> System.put_env(empty_env, value)
      end
    end)

    config = %{
      "tracker" => Map.merge(github_tracker_attrs(), %{"api_token" => "$#{empty_env}"})
    }

    # Empty env value resolves to nil → triggers missing_tracker_api_token.
    assert {:error, {:invalid_workflow_config, message}} = parse(config)
    assert message =~ "missing_tracker_api_token"
  end

  defp github_tracker_attrs do
    %{
      "kind" => "github",
      "api_token" => "ghp_test",
      "owner" => "archelab",
      "owner_type" => "organization",
      "project_number" => 1,
      "repo" => "symphony"
    }
  end
end
