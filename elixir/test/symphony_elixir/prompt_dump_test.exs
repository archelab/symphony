defmodule SymphonyElixir.PromptDumpTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PromptDump

  test "env_names returns the injected app-server environment variable names" do
    assert PromptDump.env_names() == [
             "GH_TOKEN",
             "GITHUB_TOKEN",
             "AGENT_BROWSER_HOME",
             "XDG_RUNTIME_DIR",
             "AGENT_BROWSER_IDLE_TIMEOUT_MS",
             "AGENT_BROWSER_CONTENT_BOUNDARIES"
           ]
  end

  test "dump includes the rendered prompt, runtime envelope, env names, and tool schemas" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_workpad_enabled: true,
      codex_approval_policy: "never",
      codex_model: "gpt-5.5",
      codex_turn_sandbox_policy: %{"type" => "workspaceWrite", "networkAccess" => true},
      prompt: "Prompt for {{ issue.identifier }} thread={{ thread_id }} subject={{ subject_id }} model={{ model }}"
    )

    assert {:ok, dump} =
             PromptDump.dump(sample_issue(),
               thread_id: "thread-123",
               dispatched_at: "2026-05-13T22:10:37Z"
             )

    assert dump =~ "# Symphony Prompt Dump"
    assert dump =~ "publishable startup payload"
    assert dump =~ "- `cwd`: `"
    assert dump =~ "Thread `approvalPolicy`: `never`"
    assert dump =~ "\"networkAccess\": true"
    assert dump =~ "- Network access for the turn sandbox: `true`"
    assert dump =~ "- `GH_TOKEN`"
    assert dump =~ "\"name\": \"github_graphql\""
    assert dump =~ "\"name\": \"agent_browser\""
    assert dump =~ "Prompt for archelab/symphony#210 thread=thread-123 subject=I_210 model=gpt-5.5"
    refute dump =~ "ghp_test_token"
  end

  test "dump supports default options" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_workpad_enabled: true,
      codex_approval_policy: "never",
      codex_model: "gpt-5.5",
      codex_turn_sandbox_policy: %{"type" => "workspaceWrite", "networkAccess" => true},
      prompt: "Prompt for {{ issue.identifier }} thread={{ thread_id }}"
    )

    assert {:ok, dump} = PromptDump.dump(sample_issue())
    assert dump =~ "PROMPT_DUMP_THREAD_ID"
    assert dump =~ "Prompt for archelab/symphony#210"
  end

  test "dump accepts explicit runtime settings and workspace" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: %{reject: %{sandbox_approval: true}},
      codex_model: "gpt-5.4",
      codex_turn_sandbox_policy: %{"type" => "workspaceWrite", "networkAccess" => false}
    )

    runtime_settings = %{
      approval_policy: %{"reject" => %{"sandbox_approval" => true}},
      thread_sandbox: "read-only",
      turn_sandbox_policy: %{"type" => "readOnly"}
    }

    assert {:ok, dump} =
             PromptDump.dump(sample_issue(),
               runtime_settings: runtime_settings,
               workspace: "/tmp/symphony-dump-workspace",
               thread_id: "thread-explicit",
               dispatched_at: "2026-05-13T22:10:37Z"
             )

    assert dump =~ "- `cwd`: `/tmp/symphony-dump-workspace`"
    assert dump =~ "Thread `approvalPolicy`: `{\"reject\":{\"sandbox_approval\":true}}`"
    assert dump =~ "Thread `sandbox`: `read-only`"
    assert dump =~ "- Network access for the turn sandbox: `false`"
  end

  test "fetch_issue normalizes an issue project item from GitHub GraphQL" do
    response = %{
      "data" => %{
        "repository" => %{
          "issueOrPullRequest" => %{
            "__typename" => "Issue",
            "projectItems" => %{"nodes" => [project_item("ISSUE", "Issue", 1)]}
          }
        }
      }
    }

    graphql_fun = fn query, variables, opts ->
      assert query =~ "SymphonyPromptDumpIssue"

      assert variables == %{
               "owner" => "archelab",
               "repo" => "symphony",
               "number" => 210,
               "statusField" => "Status"
             }

      assert opts[:endpoint] == "https://api.github.com/graphql"
      assert opts[:token] == "ghp_test_token"
      {:ok, response}
    end

    assert {:ok, issue} = PromptDump.fetch_issue("archelab/symphony#210", graphql_fun: graphql_fun)
    assert issue.identifier == "archelab/symphony#210"
    assert issue.state == "Agent Ready"
    assert issue.content_id == "I_210"
  end

  test "fetch_issue can select by configured project id and pull request item" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_id: "PVT_target")

    response = %{
      "data" => %{
        "repository" => %{
          "issueOrPullRequest" => %{
            "__typename" => "PullRequest",
            "projectItems" => %{
              "nodes" => [
                project_item("PULL_REQUEST", "PullRequest", 2, project_id: "PVT_other"),
                project_item("PULL_REQUEST", "PullRequest", 3, project_id: "PVT_target")
              ]
            }
          }
        }
      }
    }

    graphql_fun = fn _query, _variables, _opts -> {:ok, response} end

    assert {:ok, issue} = PromptDump.fetch_issue("archelab/symphony#210", graphql_fun: graphql_fun)
    assert issue.kind == "pull_request"
    assert issue.id == "PVTI_3"
  end

  test "fetch_issue reports invalid identifiers, missing items, unknown payloads, and skipped items" do
    assert {:error, {:invalid_issue_identifier, "not-an-issue"}} = PromptDump.fetch_issue("not-an-issue")

    no_item_response = %{
      "data" => %{
        "repository" => %{
          "issueOrPullRequest" => %{
            "__typename" => "Issue",
            "projectItems" => %{"nodes" => [%{}]}
          }
        }
      }
    }

    no_item_fun = fn _query, _variables, _opts -> {:ok, no_item_response} end
    assert {:error, {:project_item_not_found, 1}} = PromptDump.fetch_issue("archelab/symphony#210", graphql_fun: no_item_fun)

    unknown_fun = fn _query, _variables, _opts -> {:ok, %{"data" => %{}}} end

    assert {:error, {:github_unknown_payload, "prompt dump issue lookup"}} =
             PromptDump.fetch_issue("archelab/symphony#210", graphql_fun: unknown_fun)

    skipped_response = %{
      "data" => %{
        "repository" => %{
          "issueOrPullRequest" => %{
            "__typename" => "Issue",
            "projectItems" => %{
              "nodes" => [Map.put(project_item("ISSUE", "Issue", 1), "isArchived", true)]
            }
          }
        }
      }
    }

    skipped_fun = fn _query, _variables, _opts -> {:ok, skipped_response} end
    assert {:error, {:issue_skipped, :archived}} = PromptDump.fetch_issue("archelab/symphony#210", graphql_fun: skipped_fun)

    error_fun = fn _query, _variables, _opts -> {:error, :boom} end
    assert {:error, :boom} = PromptDump.fetch_issue("archelab/symphony#210", graphql_fun: error_fun)
  end

  defp sample_issue do
    Issue.new(%{
      id: "PVTI_210",
      content_id: "I_210",
      identifier: "archelab/symphony#210",
      kind: "issue",
      title: "Dump startup prompt",
      description: "Document the startup payload.",
      state: "Agent Ready",
      repository: %{
        owner: "archelab",
        name: "symphony",
        name_with_owner: "archelab/symphony",
        default_branch: "main"
      },
      number: 210,
      url: "https://github.com/archelab/symphony/issues/210",
      labels: [],
      blocked_by: [],
      issue_state: "OPEN"
    })
  end

  defp project_item(type, typename, suffix, opts \\ []) do
    %{
      "id" => "PVTI_#{suffix}",
      "type" => type,
      "isArchived" => false,
      "project" => %{
        "id" => Keyword.get(opts, :project_id, "PVT_project"),
        "title" => "Symphony",
        "number" => Keyword.get(opts, :project_number, 1)
      },
      "fieldValueByName" => %{
        "__typename" => "ProjectV2ItemFieldSingleSelectValue",
        "name" => "Agent Ready",
        "optionId" => "ready"
      },
      "content" => content(typename)
    }
  end

  defp content("Issue") do
    %{
      "__typename" => "Issue",
      "id" => "I_210",
      "number" => 210,
      "title" => "Dump startup prompt",
      "body" => "Document the startup payload.",
      "url" => "https://github.com/archelab/symphony/issues/210",
      "state" => "OPEN",
      "createdAt" => "2026-05-13T00:00:00Z",
      "updatedAt" => "2026-05-13T00:00:00Z",
      "repository" => repository(),
      "labels" => %{"nodes" => []},
      "blockedBy" => %{"nodes" => []},
      "trackedIssues" => %{"nodes" => []},
      "subIssues" => %{"nodes" => []}
    }
  end

  defp content("PullRequest") do
    %{
      "__typename" => "PullRequest",
      "id" => "PR_210",
      "number" => 210,
      "title" => "Dump startup prompt",
      "body" => "Document the startup payload.",
      "url" => "https://github.com/archelab/symphony/pull/210",
      "state" => "OPEN",
      "merged" => false,
      "mergedAt" => nil,
      "closedAt" => nil,
      "isDraft" => false,
      "headRefName" => "prompt-dump",
      "baseRefName" => "main",
      "createdAt" => "2026-05-13T00:00:00Z",
      "updatedAt" => "2026-05-13T00:00:00Z",
      "repository" => repository(),
      "labels" => %{"nodes" => []}
    }
  end

  defp repository do
    %{
      "nameWithOwner" => "archelab/symphony",
      "owner" => %{"login" => "archelab"},
      "name" => "symphony",
      "defaultBranchRef" => %{"name" => "main"}
    }
  end
end
