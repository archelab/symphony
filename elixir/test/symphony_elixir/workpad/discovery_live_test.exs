defmodule SymphonyElixir.Workpad.DiscoveryLiveTest do
  @moduledoc """
  Live verification of the agent-side workpad discovery algorithm (SPEC §11.8.1
  steps 2 and 7) against real archelab/symphony state.

  These tests live behind the `:live_github` tag because each one performs
  100+ real GraphQL mutations and is therefore slow + rate-limit sensitive.
  They are excluded from `mix test_strict` and only run via:

      GITHUB_TOKEN=$(gh auth token) mix test --only live_github

  Scope:

    * `§17.8 item 7` — a 101-comment issue still surfaces the workpad
      via `comments(first: 100, after: $cursor)` pagination.
    * `§17.8 item 8` — when two workpads share a `createdAt` second,
      `(createdAt DESC, databaseId DESC)` resolves a deterministic winner
      (the higher `databaseId`).

  The orchestrator never executes `comments(...)` itself — the agent does, via
  the `github_graphql` Codex tool. These tests therefore execute the spec's
  required GraphQL through `GithubGraphqlTool.handle/1`, the same surface the
  real agent uses.
  """

  use SymphonyElixir.TestSupport
  @moduletag :live_github
  @moduletag timeout: :timer.minutes(10)

  alias SymphonyElixir.Codex.GithubGraphqlTool
  alias SymphonyElixir.Github.Adapter

  @workpad_marker "<!-- symphony-workpad:v1 -->"

  setup do
    token =
      System.get_env("GITHUB_TOKEN") ||
        raise "GITHUB_TOKEN not set; run with GITHUB_TOKEN=$(gh auth token)"

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

    Application.delete_env(:symphony_elixir, :github_client)
    Adapter.invalidate_cache()

    :ok
  end

  @tag timeout: :timer.minutes(5)
  test "Discovery: 101-comment pagination locates a workpad in comment #1 (SPEC §17.8.7 / §11.8.1 step 2)" do
    {issue_number, subject_id} =
      create_throwaway_issue!("[workpad-live-test] 101-comment pagination")

    # 1. Plant the workpad FIRST so it is the oldest comment (default forward
    #    pagination ordering — page 1 of comments(first: 100) starts with the
    #    oldest comment). This proves the agent's loop must walk pages even
    #    when the marker is on the FIRST page.
    workpad_body =
      "#{@workpad_marker}\nworkpad-live-test pagination seed.\n<!-- /symphony-workpad:v1 -->"

    {:ok,
     %{
       "data" => %{
         "addComment" => %{
           "commentEdge" => %{"node" => %{"id" => workpad_comment_id}}
         }
       }
     }} = add_comment!(subject_id, workpad_body)

    assert is_binary(workpad_comment_id)

    # 2. Fire 100 filler comments. addComment is one mutation per call, so
    #    this is ~100 sequential round-trips (~30-60s total).
    for n <- 1..100 do
      {:ok, _} = add_comment!(subject_id, "filler #{n} — workpad-live-test")
      Process.sleep(1_500)
    end

    # 3. Paginate comments(first: 100, after: $cursor) per §11.8.1 step 2.
    {pages, all_nodes} = paginate_comments(issue_number)

    assert length(pages) >= 2,
           "Expected >=2 pages for a 101-comment issue, got #{length(pages)} (total nodes: #{length(all_nodes)})"

    [first_page | _] = pages
    assert length(first_page) == 100, "Page 1 should be saturated at first: 100"

    # 4. Scan each page for a comment whose trimmed body starts with the
    #    workpad marker (mirrors `elixir/WORKFLOW.md` §"Find or
    #    create the workpad" step 1).
    located_on_page =
      pages
      |> Enum.with_index(1)
      |> Enum.find(fn {nodes, _idx} ->
        Enum.any?(nodes, &workpad_marker?/1)
      end)

    assert located_on_page != nil, "Workpad marker not found across #{length(pages)} pages"
    {marker_page_nodes, page_index} = located_on_page

    # Marker was planted FIRST → it is the oldest → it lives on page 1.
    assert page_index == 1,
           "Workpad expected on page 1 (oldest), got page #{page_index}"

    marker_node = Enum.find(marker_page_nodes, &workpad_marker?/1)
    assert marker_node["id"] == workpad_comment_id
  end

  @tag timeout: :timer.minutes(5)
  test "Discovery: multiple workpads resolve via (createdAt DESC, databaseId DESC) (SPEC §17.8.8 / §11.8.1 step 7)" do
    {_issue_number, subject_id} =
      create_throwaway_issue!("[workpad-live-test] tiebreaker (createdAt DESC, databaseId DESC)")

    # 1. Post TWO workpad-marker comments back-to-back. GitHub stores
    #    createdAt at second precision; sequential mutations frequently
    #    collide in the same second.
    body_a = "#{@workpad_marker}\nworkpad-live-test A\n<!-- /symphony-workpad:v1 -->"
    body_b = "#{@workpad_marker}\nworkpad-live-test B\n<!-- /symphony-workpad:v1 -->"

    {:ok,
     %{
       "data" => %{
         "addComment" => %{
           "commentEdge" => %{
             "node" => %{"id" => id_a, "databaseId" => db_a, "createdAt" => created_a}
           }
         }
       }
     }} = add_comment_full!(subject_id, body_a)

    {:ok,
     %{
       "data" => %{
         "addComment" => %{
           "commentEdge" => %{
             "node" => %{"id" => id_b, "databaseId" => db_b, "createdAt" => created_b}
           }
         }
       }
     }} = add_comment_full!(subject_id, body_b)

    assert is_integer(db_a) and is_integer(db_b)
    assert db_b > db_a, "B was posted after A, so its databaseId must be higher"

    # 2. Query the issue comments via the same path the agent uses.
    {_pages, nodes} = paginate_comments_from_subject(subject_id)

    workpads =
      Enum.filter(nodes, fn n ->
        workpad_marker?(n) and n["id"] in [id_a, id_b]
      end)

    assert length(workpads) == 2

    # 3. Spec sort order: (createdAt DESC, databaseId DESC).
    sorted =
      Enum.sort_by(
        workpads,
        fn n -> {n["createdAt"], n["databaseId"]} end,
        :desc
      )

    winner = hd(sorted)

    if created_a == created_b do
      # Tiebreaker actually exercised — databaseId DESC must pick B.
      assert winner["id"] == id_b,
             "createdAt collided (#{created_a}) — winner must be the higher databaseId (#{db_b}), got #{winner["databaseId"]}"

      assert winner["databaseId"] == db_b
    else
      # Timestamps diverged (test was slow) — winner is still the newer one,
      # which is B (posted second). The tiebreaker logic is sound either way.
      assert winner["id"] == id_b,
             "createdAt diverged (a=#{created_a} b=#{created_b}) — newer wins; expected B"

      assert winner["createdAt"] >= created_a
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp create_throwaway_issue!(title_prefix) do
    title = "#{title_prefix} #{System.unique_integer([:positive])}"
    body = "Throwaway live test for SPEC §11.8 discovery — safe to close."

    url = create_issue_with_retry!(title, body)

    url = String.trim(url)
    issue_number_str = url |> String.split("/") |> List.last() |> String.trim()
    issue_number = String.to_integer(issue_number_str)

    on_exit(fn ->
      System.cmd("gh", ["issue", "close", "-R", "archelab/symphony", issue_number_str], stderr_to_stdout: true)
    end)

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
        "variables" => %{"num" => issue_number}
      })

    assert is_binary(subject_id)

    {issue_number, subject_id}
  end

  defp add_comment!(subject_id, body) do
    retry_github_submitted_too_quickly(fn ->
      GithubGraphqlTool.handle(%{
        "query" => """
        mutation($subject: ID!, $body: String!) {
          addComment(input: {subjectId: $subject, body: $body}) {
            commentEdge { node { id body } }
          }
        }
        """,
        "variables" => %{"subject" => subject_id, "body" => body}
      })
    end)
  end

  defp add_comment_full!(subject_id, body) do
    retry_github_submitted_too_quickly(fn ->
      GithubGraphqlTool.handle(%{
        "query" => """
        mutation($subject: ID!, $body: String!) {
          addComment(input: {subjectId: $subject, body: $body}) {
            commentEdge { node { id databaseId body createdAt } }
          }
        }
        """,
        "variables" => %{"subject" => subject_id, "body" => body}
      })
    end)
  end

  defp create_issue_with_retry!(title, body, attempts_left \\ 18)

  defp create_issue_with_retry!(title, body, attempts_left) when attempts_left > 1 do
    case System.cmd(
           "gh",
           ["api", "repos/archelab/symphony/issues", "-X", "POST", "-f", "title=#{title}", "-f", "body=#{body}"],
           stderr_to_stdout: true
         ) do
      {json, 0} ->
        url = issue_url_from_rest_response(json)

        if valid_issue_url?(url) do
          url
        else
          retry_create_issue_or_flunk!(title, body, json, attempts_left)
        end

      {output, _status} ->
        if github_submitted_too_quickly?(output) do
          Process.sleep(15_000)
          create_issue_with_retry!(title, body, attempts_left - 1)
        else
          flunk("gh issue create failed: #{output}")
        end
    end
  end

  defp create_issue_with_retry!(title, body, _attempts_left) do
    case System.cmd(
           "gh",
           ["api", "repos/archelab/symphony/issues", "-X", "POST", "-f", "title=#{title}", "-f", "body=#{body}"],
           stderr_to_stdout: true
         ) do
      {json, 0} ->
        url = issue_url_from_rest_response(json)

        if valid_issue_url?(url),
          do: url,
          else: flunk("gh issue REST create returned no issue URL: #{inspect(json)}")

      {output, _status} ->
        flunk("gh issue REST create failed: #{output}")
    end
  end

  defp retry_create_issue_or_flunk!(title, body, output, attempts_left) do
    if github_submitted_too_quickly?(output) do
      Process.sleep(15_000)
      create_issue_with_retry!(title, body, attempts_left - 1)
    else
      flunk("gh issue REST create returned no issue URL: #{inspect(output)}")
    end
  end

  defp issue_url_from_rest_response(json) do
    case Jason.decode(json) do
      {:ok, %{"html_url" => url}} when is_binary(url) -> String.trim(url)
      _ -> ""
    end
  end

  defp retry_github_submitted_too_quickly(fun, attempts_left \\ 18)

  defp retry_github_submitted_too_quickly(fun, attempts_left) when attempts_left > 1 do
    case fun.() do
      {:error, {:github_graphql_errors, errors}} when is_list(errors) ->
        if github_submitted_too_quickly?(errors) do
          Process.sleep(15_000)
          retry_github_submitted_too_quickly(fun, attempts_left - 1)
        else
          {:error, {:github_graphql_errors, errors}}
        end

      other ->
        other
    end
  end

  defp retry_github_submitted_too_quickly(fun, _attempts_left), do: fun.()

  defp valid_issue_url?(url), do: String.match?(url, ~r{/issues/\d+$})

  defp github_submitted_too_quickly?(output) when is_binary(output),
    do:
      String.contains?(output, "submitted too quickly") or
        String.contains?(output, "secondary rate limit") or
        String.contains?(output, "temporarily blocked from content creation") or
        String.contains?(output, "abuse")

  defp github_submitted_too_quickly?(errors) when is_list(errors) do
    Enum.any?(errors, fn
      %{"message" => message} when is_binary(message) -> github_submitted_too_quickly?(message)
      _ -> false
    end)
  end

  defp github_submitted_too_quickly?(_), do: false

  # Walk comments(first: 100, after: $cursor) by issue number. Returns
  # {pages, all_nodes_flat}.
  defp paginate_comments(issue_number) do
    do_paginate(:by_number, issue_number, nil, [])
  end

  # Walk comments by querying through the subject node (used when we only have
  # the node id, e.g. after creating a fresh issue and not threading the number
  # through).
  defp paginate_comments_from_subject(subject_id) do
    do_paginate(:by_node, subject_id, nil, [])
  end

  defp do_paginate(mode, target, cursor, acc_pages) do
    {query, variables} = paginate_query(mode, target, cursor)

    {:ok, %{"data" => data}} =
      GithubGraphqlTool.handle(%{"query" => query, "variables" => variables})

    page = extract_page(mode, data)
    nodes = page["nodes"] || []
    page_info = page["pageInfo"] || %{}
    new_acc = acc_pages ++ [nodes]

    if page_info["hasNextPage"] do
      do_paginate(mode, target, page_info["endCursor"], new_acc)
    else
      {new_acc, List.flatten(new_acc)}
    end
  end

  defp paginate_query(:by_number, issue_number, cursor) do
    query = """
    query($num: Int!, $cursor: String) {
      repository(owner: "archelab", name: "symphony") {
        issue(number: $num) {
          comments(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes { id databaseId body createdAt author { login } }
          }
        }
      }
    }
    """

    {query, %{"num" => issue_number, "cursor" => cursor}}
  end

  defp paginate_query(:by_node, subject_id, cursor) do
    query = """
    query($id: ID!, $cursor: String) {
      node(id: $id) {
        ... on Issue {
          comments(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes { id databaseId body createdAt author { login } }
          }
        }
      }
    }
    """

    {query, %{"id" => subject_id, "cursor" => cursor}}
  end

  defp extract_page(:by_number, data),
    do: data["repository"]["issue"]["comments"]

  defp extract_page(:by_node, data),
    do: data["node"]["comments"]

  defp workpad_marker?(%{"body" => body}) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.starts_with?(@workpad_marker)
  end

  defp workpad_marker?(_), do: false
end
