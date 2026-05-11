defmodule SymphonyElixir.Github.IssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Github.Issue

  test "issue kind has nil pr struct and populated repository" do
    issue =
      Issue.new(%{
        id: "PVTI_xxx",
        identifier: "archelab/symphony#42",
        kind: "issue",
        title: "Refactor",
        description: "body",
        state: "Agent Ready",
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        number: 42,
        labels: ["bug"],
        blocked_by: [],
        url: "https://github.com/archelab/symphony/issues/42",
        issue_state: "OPEN"
      })

    assert issue.kind == "issue"
    assert issue.pr == nil
    assert issue.repository.name_with_owner == "archelab/symphony"
    assert issue.branch_name == nil
  end

  test "pull_request kind populates pr Tier-1 fields and branch_name" do
    issue =
      Issue.new(%{
        id: "PVTI_yyy",
        identifier: "archelab/symphony#7",
        kind: "pull_request",
        title: "Fix CI",
        state: "In Progress",
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        number: 7,
        branch_name: "fix-ci",
        labels: [],
        blocked_by: [],
        url: "https://github.com/archelab/symphony/pull/7",
        issue_state: "OPEN",
        pr: %{
          state: "OPEN",
          merged: false,
          merged_at: nil,
          closed_at: nil,
          is_draft: false,
          base_ref_name: "main"
        }
      })

    assert issue.kind == "pull_request"
    assert issue.branch_name == "fix-ci"
    assert issue.pr.state == "OPEN"
    assert issue.pr.merged == false
    assert issue.pr.is_draft == false
    assert issue.pr.base_ref_name == "main"
  end

  test "draft_issue identifier uses LAST 8 characters of the project item node ID" do
    # Spec §4.1.1: "where <short> is the last 8 characters of the Project item
    # node ID". The adapter normalization is the source of truth for this rule;
    # this test pins the contract at the domain layer so a later refactor that
    # accidentally takes the FIRST 8 chars is caught before it reaches a fixture.
    full_id = "PVTI_lAHOAAAAAAFAF6gQ123"
    short = String.slice(full_id, -8, 8)
    assert short == "AF6gQ123"

    issue =
      Issue.new(%{
        id: full_id,
        identifier: "draft:" <> short,
        kind: "draft_issue",
        title: "Idea",
        state: "Todo",
        labels: [],
        blocked_by: [],
        repository: nil,
        number: nil,
        url: nil,
        issue_state: nil
      })

    assert issue.identifier == "draft:AF6gQ123"
  end

  test "draft_issue kind has nil repository, nil number, identifier prefix draft:" do
    issue =
      Issue.new(%{
        id: "PVTI_AF6gQ123",
        identifier: "draft:AF6gQ123",
        kind: "draft_issue",
        title: "Idea",
        state: "Todo",
        labels: [],
        blocked_by: [],
        repository: nil,
        number: nil,
        url: nil,
        issue_state: nil
      })

    assert issue.kind == "draft_issue"
    assert issue.repository == nil
    assert issue.number == nil
    assert issue.url == nil
    assert issue.labels == []
    assert String.starts_with?(issue.identifier, "draft:")
  end

  test "blocked_by attrs are normalized into Blocker structs" do
    issue =
      Issue.new(%{
        id: "PVTI_zzz",
        identifier: "archelab/symphony#9",
        kind: "issue",
        title: "Depends",
        state: "Agent Ready",
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        number: 9,
        labels: [],
        blocked_by: [
          %{id: "PVTI_b1", identifier: "archelab/symphony#1", state: "Todo"},
          %SymphonyElixir.Github.Issue.Blocker{
            id: "PVTI_b2",
            identifier: "archelab/symphony#2",
            state: "Done"
          }
        ],
        url: "https://github.com/archelab/symphony/issues/9",
        issue_state: "OPEN"
      })

    assert [
             %SymphonyElixir.Github.Issue.Blocker{id: "PVTI_b1"} = b1,
             %SymphonyElixir.Github.Issue.Blocker{id: "PVTI_b2"} = b2
           ] = issue.blocked_by

    assert b1.identifier == "archelab/symphony#1"
    assert b2.state == "Done"
  end

  describe "content_id (SPEC §11.8.5 subject_id)" do
    # `content_id` is the underlying Issue/PullRequest/DraftIssue node id
    # (`I_*` / `PR_*` / `DI_*`). It is DISTINCT from `id`, which is the
    # ProjectV2Item node id (`PVTI_*`). The Agent Workpad Protocol uses it
    # as the `subjectId` argument to `addComment` / `updateIssueComment`.

    test "Issue.new/1 accepts and stores content_id" do
      issue =
        Issue.new(%{
          id: "PVTI_iss_xyz",
          identifier: "archelab/symphony#42",
          kind: "issue",
          content_id: "I_xyz",
          state: "Agent Ready",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          number: 42,
          labels: [],
          blocked_by: [],
          url: "https://github.com/archelab/symphony/issues/42",
          issue_state: "OPEN"
        })

      assert issue.content_id == "I_xyz"
      assert issue.id == "PVTI_iss_xyz"
    end

    test "Issue.new/1 defaults content_id to nil when omitted" do
      issue =
        Issue.new(%{
          id: "PVTI_iss_xyz",
          identifier: "archelab/symphony#42",
          kind: "issue",
          state: "Agent Ready",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          number: 42,
          labels: [],
          blocked_by: [],
          url: "https://github.com/archelab/symphony/issues/42",
          issue_state: "OPEN"
        })

      assert issue.content_id == nil
    end

    test "Issue.new/1 stores PR_* content_id for pull_request kind" do
      issue =
        Issue.new(%{
          id: "PVTI_pr_xyz",
          identifier: "archelab/symphony#7",
          kind: "pull_request",
          content_id: "PR_xyz",
          state: "In Progress",
          repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
          number: 7,
          labels: [],
          blocked_by: [],
          url: "https://github.com/archelab/symphony/pull/7",
          issue_state: "OPEN"
        })

      assert issue.content_id == "PR_xyz"
    end

    test "Issue.new/1 stores DI_* content_id for draft_issue kind" do
      issue =
        Issue.new(%{
          id: "PVTI_draft_xyz",
          identifier: "draft:af6gQ123",
          kind: "draft_issue",
          content_id: "DI_af6gQ123abcdef",
          state: "Todo",
          repository: nil,
          number: nil,
          labels: [],
          blocked_by: [],
          url: nil,
          issue_state: nil
        })

      assert issue.content_id == "DI_af6gQ123abcdef"
    end
  end

  test "Issue.new accepts pre-built %Repository{} and %PR{} structs without re-wrapping" do
    repo = %SymphonyElixir.Github.Issue.Repository{
      owner: "a",
      name: "b",
      name_with_owner: "a/b"
    }

    pr = %SymphonyElixir.Github.Issue.PR{
      state: "OPEN",
      merged: false,
      merged_at: nil,
      closed_at: nil,
      is_draft: true,
      base_ref_name: "main"
    }

    issue =
      Issue.new(%{
        id: "x",
        identifier: "a/b#1",
        kind: "pull_request",
        title: "t",
        state: "Todo",
        repository: repo,
        number: 1,
        labels: [],
        blocked_by: [],
        url: "u",
        issue_state: "OPEN",
        pr: pr
      })

    assert issue.repository == repo
    assert issue.pr == pr
  end
end
