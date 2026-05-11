defmodule SymphonyElixir.Github.NormalizeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Github.{Issue, Normalize}

  setup do
    payload = "test/fixtures/github/items_page.json" |> File.read!() |> Jason.decode!()
    items = get_in(payload, ["data", "node", "items", "nodes"])
    {:ok, items: items}
  end

  test "normalizes an issue with mixed-state blockers", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_iss1"))

    assert {:ok, %Issue{} = issue} = Normalize.item(item, status_field: "Status")
    assert issue.id == "PVTI_iss1"
    assert issue.identifier == "archelab/symphony#42"
    assert issue.kind == "issue"
    assert issue.state == "Agent Ready"
    assert issue.labels == ["bug", "p1"]
    assert issue.repository.name_with_owner == "archelab/symphony"
    assert issue.repository.default_branch == "main"
    assert issue.number == 42
    assert issue.url == "https://github.com/archelab/symphony/issues/42"
    assert issue.issue_state == "OPEN"

    assert [closed, open] = issue.blocked_by
    assert closed.identifier == "archelab/symphony#7"
    assert closed.state == "CLOSED"
    assert open.identifier == "archelab/symphony#8"
    assert open.state == "OPEN"
  end

  test "normalizes a merged PR with Tier 1 fields", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_pr_merged"))

    assert {:ok, %Issue{kind: "pull_request"} = issue} = Normalize.item(item, status_field: "Status")
    assert issue.identifier == "archelab/symphony#3"
    assert issue.branch_name == "old-branch"
    assert issue.pr.state == "MERGED"
    assert issue.pr.merged == true
    assert issue.pr.is_draft == false
    assert issue.pr.base_ref_name == "main"
    assert issue.issue_state == "MERGED"
  end

  test "filters archived item", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_archived"))
    assert {:skip, :archived} = Normalize.item(item, status_field: "Status")
  end

  test "filters REDACTED item", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_redacted"))
    assert {:skip, :redacted} = Normalize.item(item, status_field: "Status")
  end

  test "no-status item gets <no status> sentinel", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_no_status"))
    assert {:ok, %Issue{state: "<no status>"}} = Normalize.item(item, status_field: "Status")
  end

  test "draft_issue identifier uses last 8 chars of node id", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_draft1"))

    assert {:ok, %Issue{kind: "draft_issue", identifier: "draft:" <> short} = issue} =
             Normalize.item(item, status_field: "Status")

    assert String.length(short) == 8
    assert issue.repository == nil
    assert issue.url == nil
  end

  # ------------------------------------------------------------------
  # Coverage gates
  # ------------------------------------------------------------------

  test "skips when content is nil but type is not REDACTED" do
    item = %{"type" => "ISSUE", "isArchived" => false, "id" => "PVTI_orphan", "content" => nil}
    assert {:skip, :no_content} = Normalize.item(item, status_field: "Status")
  end

  test "build_repository short form (nameWithOwner only) yields owner+name split" do
    # Drive the short-form clause via an Issue whose repository payload is the
    # bare {"nameWithOwner" => "..."} shape (matches what the refresh query
    # emits for trackedIssues — but routed through Issue normalize here).
    item = %{
      "type" => "ISSUE",
      "id" => "PVTI_short",
      "isArchived" => false,
      "fieldValueByName" => %{"name" => "Agent Ready"},
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_short",
        "number" => 1,
        "title" => "x",
        "state" => "OPEN",
        "url" => "https://example",
        "repository" => %{"nameWithOwner" => "archelab/symphony"},
        "labels" => %{"nodes" => []},
        "trackedIssues" => %{"nodes" => []}
      }
    }

    assert {:ok, %Issue{repository: %Issue.Repository{owner: "archelab", name: "symphony", default_branch: nil}}} =
             Normalize.item(item, status_field: "Status")
  end

  test "issue with no repository and no number falls back to unknown identifier" do
    item = %{
      "type" => "ISSUE",
      "id" => "PVTI_orphan_repo",
      "isArchived" => false,
      "fieldValueByName" => %{"name" => "Agent Ready"},
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_orphan",
        "number" => nil,
        "title" => "x",
        "state" => "OPEN",
        "url" => nil,
        "repository" => nil,
        "labels" => nil,
        "trackedIssues" => nil
      }
    }

    assert {:ok, %Issue{identifier: "unknown:PVTI_orphan_repo", repository: nil, labels: []}} =
             Normalize.item(item, status_field: "Status")
  end

  test "branch_name returns nil for non-PR kinds (issue, draft)", %{items: items} do
    issue_item = Enum.find(items, &(&1["id"] == "PVTI_iss1"))
    {:ok, issue} = Normalize.item(issue_item, status_field: "Status")
    assert issue.branch_name == nil

    draft_item = Enum.find(items, &(&1["id"] == "PVTI_draft1"))
    {:ok, draft} = Normalize.item(draft_item, status_field: "Status")
    assert draft.branch_name == nil
  end

  test "pr/2 is nil for non-PR kinds", %{items: items} do
    issue_item = Enum.find(items, &(&1["id"] == "PVTI_iss1"))
    {:ok, issue} = Normalize.item(issue_item, status_field: "Status")
    assert issue.pr == nil
  end

  test "issue_state for draft_issue is nil (catch-all)", %{items: items} do
    draft_item = Enum.find(items, &(&1["id"] == "PVTI_draft1"))
    {:ok, draft} = Normalize.item(draft_item, status_field: "Status")
    assert draft.issue_state == nil
  end

  test "labels handles missing labels key" do
    item = %{
      "type" => "ISSUE",
      "id" => "PVTI_no_labels",
      "isArchived" => false,
      "fieldValueByName" => %{"name" => "Agent Ready"},
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_nl",
        "number" => 5,
        "title" => "x",
        "state" => "OPEN",
        "url" => "u",
        "repository" => %{"nameWithOwner" => "archelab/symphony", "owner" => %{"login" => "archelab"}, "name" => "symphony"}
      }
    }

    assert {:ok, %Issue{labels: []}} = Normalize.item(item, status_field: "Status")
  end

  test "blockers/2 is empty list for non-issue (PR)" do
    item = %{
      "type" => "PULL_REQUEST",
      "id" => "PVTI_pr_blockers",
      "isArchived" => false,
      "fieldValueByName" => %{"name" => "In Progress"},
      "content" => %{
        "__typename" => "PullRequest",
        "id" => "PR_b",
        "number" => 9,
        "title" => "x",
        "state" => "OPEN",
        "url" => "u",
        "merged" => false,
        "isDraft" => false,
        "headRefName" => "feat/x",
        "baseRefName" => "main",
        "repository" => %{
          "nameWithOwner" => "archelab/symphony",
          "owner" => %{"login" => "archelab"},
          "name" => "symphony"
        },
        "labels" => %{"nodes" => []}
      }
    }

    assert {:ok, %Issue{blocked_by: []}} = Normalize.item(item, status_field: "Status")
  end

  test "blockers/2 is empty list for issue without trackedIssues key" do
    item = %{
      "type" => "ISSUE",
      "id" => "PVTI_no_tracked",
      "isArchived" => false,
      "fieldValueByName" => %{"name" => "Agent Ready"},
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_nt",
        "number" => 6,
        "title" => "x",
        "state" => "OPEN",
        "url" => "u",
        "repository" => %{"nameWithOwner" => "archelab/symphony", "owner" => %{"login" => "archelab"}, "name" => "symphony"},
        "labels" => %{"nodes" => []}
      }
    }

    assert {:ok, %Issue{blocked_by: []}} = Normalize.item(item, status_field: "Status")
  end
end
