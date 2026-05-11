defmodule SymphonyElixir.GithubLiveTest do
  @moduledoc """
  Real-integration profile (spec §17.8). Polls archelab/symphony Project #1.
  Skipped unless GITHUB_TOKEN is set. Implementer should run this locally
  during PR1 development: `GITHUB_TOKEN=... mix test --only live_github`.
  """
  use SymphonyElixir.TestSupport
  @moduletag :live_github

  alias SymphonyElixir.Codex.GithubGraphqlTool
  alias SymphonyElixir.Github.{Adapter, Issue}

  setup do
    # Module is tagged :live_github and excluded by `mix test_strict`. When
    # running `mix test --only live_github` without a token, raise — failing
    # loudly is preferred to silently green CI.
    token = System.get_env("GITHUB_TOKEN") || raise "GITHUB_TOKEN not set; run with GITHUB_TOKEN=$(gh auth token)"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: token,
      tracker_owner: "archelab",
      tracker_owner_type: "organization",
      tracker_project_number: 1,
      tracker_repo: "symphony",
      tracker_active_states: ["Agent Ready", "In Progress", "Rework"],
      tracker_terminal_states: ["Done"]
    )

    Application.delete_env(:symphony_elixir, :github_client)
    Adapter.invalidate_cache()

    :ok
  end

  test "fetch_candidate_issues hits real GitHub and returns a list" do
    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    assert is_list(issues)

    Enum.each(issues, fn issue ->
      assert issue.id =~ "PVTI_"
      assert issue.kind in ["issue", "pull_request"]
      assert issue.repository.name_with_owner == "archelab/symphony"
      assert issue.repository.default_branch == "main"
    end)
  end

  test "fetch_issue_states_by_ids round-trips a real ID" do
    {:ok, issues} = Adapter.fetch_candidate_issues()

    case issues do
      [%{id: id} | _] ->
        assert {:ok, [%{id: ^id, state: state}]} =
                 Adapter.fetch_issue_states_by_ids([id])

        assert is_binary(state) or state in ["<no status>", "<closed>", "<merged>"]

      [] ->
        assert {:ok, []} = Adapter.fetch_issue_states_by_ids([])
    end
  end

  test "Status field probe resolves a non-empty option set with well-formed shape" do
    # The project board exposes a Status field with multiple options. We do
    # not assert the exact option set here — the board changes over time and
    # we do not want adapter health tests to go red on a status rename.
    {:ok, _issues} = Adapter.fetch_candidate_issues()

    {_cache_key, _project, %{options: options}} =
      :persistent_term.get({SymphonyElixir.Github.Adapter, :resolved})

    assert is_list(options)
    assert options != [], "Project Status field should expose at least one option"

    assert Enum.all?(options, fn
             {name, id} -> is_binary(name) and is_binary(id)
             _ -> false
           end),
           "Every Status option must be a {name, id} pair of binaries"
  end

  test "Tracker.fetch_candidate_issues/0 routes to Github.Adapter (post-cutover)" do
    assert {:ok, issues} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert is_list(issues)
    # If any issues exist, they must be normalized through Github.Issue.
    # A regression where Tracker.adapter/0 returns a non-GitHub adapter
    # would surface here as a struct-type mismatch.
    Enum.each(issues, fn issue ->
      assert %Issue{} = issue
    end)
  end

  test "github_graphql tool smoke-tests viewer{login} against real GitHub" do
    assert {:ok, %{"data" => %{"viewer" => %{"login" => login}}}} =
             GithubGraphqlTool.handle(%{
               "query" => "query { viewer { login } }",
               "variables" => %{}
             })

    assert is_binary(login)
  end
end
