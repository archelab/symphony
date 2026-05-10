defmodule SymphonyElixir.Config.GithubTrackerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

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

    assert {:ok, settings} = Schema.parse(config)
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
    System.put_env("GITHUB_TOKEN", "ghp_resolved")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "$GITHUB_TOKEN",
        "owner" => "archelab",
        "project_number" => 1
      }
    }

    assert {:ok, settings} = Schema.parse(config)
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

    assert {:ok, settings} = Schema.parse(config)
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

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
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

    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(config)
  end

  test "rejects unknown tracker kind with unsupported_tracker_kind" do
    # PR1 still accepts "linear" as a transition kind (see Schema.@valid_kinds);
    # use a truly unsupported value here. PR2 (Task 8b) tightens this further.
    config = %{
      "tracker" => %{
        "kind" => "jira",
        "api_token" => "ghp_test",
        "owner" => "archelab",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
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

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "missing_tracker_api_token"
  end

  test "rejects github kind with empty api_token after env resolution" do
    System.put_env("GITHUB_TOKEN", "")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "$GITHUB_TOKEN",
        "owner" => "archelab",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "missing_tracker_api_token"
  end
end
