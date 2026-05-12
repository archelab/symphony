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

  test "github_graphql workpad allowlist round-trip: addComment + updateIssueComment (SPEC §11.8.4)" do
    # Live workpad-allowlist proof. Creates a throwaway issue via the `gh`
    # CLI (createIssue is intentionally NOT on the allowlist), then exercises
    # the agent-side surface: addComment and updateIssueComment through the
    # `github_graphql` Codex tool. Finally verifies deleteIssueComment is
    # rejected — workpad is append-only by spec.

    # SPEC §11.8.4 + §17.8: updateIssueComment is gated by
    # `agent.workpad.enabled`. Toggle it on for this test only.
    token = System.get_env("GITHUB_TOKEN")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: token,
      tracker_owner: "archelab",
      tracker_owner_type: "organization",
      tracker_project_number: 1,
      tracker_repo: "symphony",
      tracker_active_states: ["Agent Ready", "In Progress", "Rework"],
      tracker_terminal_states: ["Done"],
      agent_workpad_enabled: true,
      codex_model: "gpt-5.5"
    )

    title = "[workpad-live-test] addComment + updateIssueComment round-trip #{System.unique_integer([:positive])}"
    body = "Throwaway live test for SPEC §11.8.4 — safe to close/delete."

    # 1. Create throwaway issue via gh CLI.
    url = create_issue_with_retry!(title, body)

    url = String.trim(url)
    issue_number = url |> String.split("/") |> List.last() |> String.trim()

    # Cleanup is registered immediately so we close the issue even if a
    # later assertion crashes the test.
    on_exit(fn ->
      System.cmd("gh", ["issue", "close", "-R", "archelab/symphony", issue_number], stderr_to_stdout: true)
    end)

    # 2. Resolve the issue node id (subject for addComment).
    {:ok,
     %{
       "data" => %{
         "repository" => %{
           "issue" => %{"id" => subject_id}
         }
       }
     }} =
      GithubGraphqlTool.handle(%{
        "query" => """
        query($num: Int!) {
          repository(owner: "archelab", name: "symphony") {
            issue(number: $num) { id }
          }
        }
        """,
        "variables" => %{"num" => String.to_integer(issue_number)}
      })

    assert is_binary(subject_id)

    # 3. addComment (the agent's "create workpad" path).
    add_body = "<!-- symphony-workpad:v1 -->\nwopad live-test seed body."

    assert {:ok,
            %{
              "data" => %{
                "addComment" => %{
                  "commentEdge" => %{
                    "node" => %{"id" => comment_id, "body" => returned_body}
                  }
                }
              }
            }} =
             retry_github_submitted_too_quickly(fn ->
               GithubGraphqlTool.handle(%{
                 "query" => """
                 mutation($subject: ID!, $body: String!) {
                   addComment(input: {subjectId: $subject, body: $body}) {
                     commentEdge { node { id body } }
                   }
                 }
                 """,
                 "variables" => %{"subject" => subject_id, "body" => add_body}
               })
             end)

    assert is_binary(comment_id)
    assert returned_body =~ "<!-- symphony-workpad:v1 -->"

    # 4. updateIssueComment (the agent's "update workpad" path — SPEC §11.8.4).
    update_body = "<!-- symphony-workpad:v1 -->\nwopad live-test updated body."

    assert {:ok,
            %{
              "data" => %{
                "updateIssueComment" => %{
                  "issueComment" => %{"id" => ^comment_id, "body" => updated_body}
                }
              }
            }} =
             GithubGraphqlTool.handle(%{
               "query" => """
               mutation($id: ID!, $body: String!) {
                 updateIssueComment(input: {id: $id, body: $body}) {
                   issueComment { id body }
                 }
               }
               """,
               "variables" => %{"id" => comment_id, "body" => update_body}
             })

    assert updated_body =~ "updated body"

    # 5. deleteIssueComment MUST be rejected — workpad is append-only.
    assert {:error, {:mutation_not_allowed, "deleteIssueComment"}} =
             GithubGraphqlTool.handle(%{
               "query" => """
               mutation($id: ID!) {
                 deleteIssueComment(input: {id: $id}) { clientMutationId }
               }
               """,
               "variables" => %{"id" => comment_id}
             })
  end

  test "github_graphql publishing allowlist round-trip: createRef + createPullRequest" do
    token = System.get_env("GITHUB_TOKEN")
    unique = System.unique_integer([:positive])
    branch = "live-test/github-graphql-publish-#{unique}"
    test_path = ".github/symphony-live-tests/#{unique}.txt"
    {:ok, cleanup} = Agent.start(fn -> %{pr_number: nil, ref_id: nil, branch: branch} end)

    on_exit(fn ->
      %{pr_number: pr_number, ref_id: ref_id, branch: branch} = Agent.get(cleanup, & &1)
      Agent.stop(cleanup)

      if pr_number do
        System.cmd("gh", ["pr", "close", "-R", "archelab/symphony", Integer.to_string(pr_number), "--delete-branch"], stderr_to_stdout: true)
      end

      if ref_id do
        System.cmd(
          "gh",
          [
            "api",
            "graphql",
            "-f",
            "query=mutation($refId:ID!){ deleteRef(input:{refId:$refId}) { clientMutationId } }",
            "-F",
            "refId=#{ref_id}"
          ],
          stderr_to_stdout: true
        )
      else
        System.cmd("git", ["push", "https://x-access-token:#{token}@github.com/archelab/symphony.git", ":#{branch}"], stderr_to_stdout: true)
      end
    end)

    {:ok,
     %{
       "data" => %{
         "repository" => %{
           "id" => repo_id,
           "defaultBranchRef" => %{"target" => %{"oid" => base_oid}}
         }
       }
     }} =
      GithubGraphqlTool.handle(%{
        "query" => """
        query {
          repository(owner: "archelab", name: "symphony") {
            id
            defaultBranchRef { target { oid } }
          }
        }
        """,
        "variables" => %{}
      })

    assert {:ok,
            %{
              "data" => %{
                "createRef" => %{
                  "ref" => %{"id" => ref_id, "name" => ^branch}
                }
              }
            }} =
             GithubGraphqlTool.handle(%{
               "query" => """
               mutation($repositoryId: ID!, $name: String!, $oid: GitObjectID!) {
                 createRef(input: {repositoryId: $repositoryId, name: $name, oid: $oid}) {
                   ref { id name }
                 }
               }
               """,
               "variables" => %{
                 "repositoryId" => repo_id,
                 "name" => "refs/heads/#{branch}",
                 "oid" => base_oid
               }
             })

    Agent.update(cleanup, &Map.put(&1, :ref_id, ref_id))

    encoded = Base.encode64("Live github_graphql publishing allowlist test #{unique}\n")

    {_, 0} =
      System.cmd(
        "gh",
        [
          "api",
          "-X",
          "PUT",
          "repos/archelab/symphony/contents/#{test_path}",
          "-f",
          "message=live-test: prepare github_graphql createPullRequest branch",
          "-f",
          "content=#{encoded}",
          "-f",
          "branch=#{branch}"
        ],
        stderr_to_stdout: true
      )

    assert {:ok,
            %{
              "data" => %{
                "createPullRequest" => %{
                  "pullRequest" => %{"number" => pr_number, "url" => url}
                }
              }
            }} =
             retry_github_submitted_too_quickly(fn ->
               GithubGraphqlTool.handle(%{
                 "query" => """
                 mutation($input: CreatePullRequestInput!) {
                   createPullRequest(input: $input) {
                     pullRequest { number url }
                   }
                 }
                 """,
                 "variables" => %{
                   "input" => %{
                     "repositoryId" => repo_id,
                     "baseRefName" => "main",
                     "headRefName" => branch,
                     "title" => "[live-test] github_graphql createPullRequest #{unique}",
                     "body" => "Throwaway live test for the github_graphql publishing allowlist. This PR should be closed automatically."
                   }
                 }
               })
             end)

    Agent.update(cleanup, &Map.put(&1, :pr_number, pr_number))

    assert is_integer(pr_number)
    assert url =~ "github.com/archelab/symphony/pull/"
  end

  defp create_issue_with_retry!(title, body, attempts_left \\ 4)

  defp create_issue_with_retry!(title, body, attempts_left) when attempts_left > 1 do
    case System.cmd(
           "gh",
           ["issue", "create", "-R", "archelab/symphony", "--title", title, "--body", body],
           stderr_to_stdout: true
         ) do
      {url, 0} ->
        String.trim(url)

      {output, _status} ->
        if String.contains?(output, "submitted too quickly") do
          Process.sleep(5_000)
          create_issue_with_retry!(title, body, attempts_left - 1)
        else
          flunk("gh issue create failed: #{output}")
        end
    end
  end

  defp create_issue_with_retry!(title, body, _attempts_left) do
    case System.cmd(
           "gh",
           ["issue", "create", "-R", "archelab/symphony", "--title", title, "--body", body],
           stderr_to_stdout: true
         ) do
      {url, 0} -> String.trim(url)
      {output, _status} -> flunk("gh issue create failed: #{output}")
    end
  end

  defp retry_github_submitted_too_quickly(fun, attempts_left \\ 4)

  defp retry_github_submitted_too_quickly(fun, attempts_left) when attempts_left > 1 do
    case fun.() do
      {:error, {:github_graphql_errors, [%{"message" => "was submitted too quickly"} | _]}} ->
        Process.sleep(5_000)
        retry_github_submitted_too_quickly(fun, attempts_left - 1)

      other ->
        other
    end
  end

  defp retry_github_submitted_too_quickly(fun, _attempts_left), do: fun.()
end
