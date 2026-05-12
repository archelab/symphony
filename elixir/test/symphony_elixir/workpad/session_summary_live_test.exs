defmodule SymphonyElixir.Workpad.SessionSummaryLiveTest do
  @moduledoc """
  Live verification of the §11.8.10 per-session summary GraphQL surface
  against real archelab/symphony state.

  Scope: this test proves `Codex.GithubGraphqlTool.handle/1` can post a
  comment with the canonical `<!-- symphony-session-summary:<thread_id>:v1 -->`
  marker and that a subsequent comment query surfaces it intact. It does
  NOT exercise the agent's adherence to the §11.8.10 prose — that's down to
  the LLM following the prompt, and is covered separately by e2e-10.

  Excluded from `mix test_strict` via the `:live_github` tag; run with:

      GITHUB_TOKEN=$(gh auth token) mix test --only live_github
  """
  use SymphonyElixir.TestSupport
  @moduletag :live_github
  @moduletag timeout: :timer.minutes(10)

  alias SymphonyElixir.Codex.GithubGraphqlTool
  alias SymphonyElixir.Github.Adapter
  alias SymphonyElixir.Workpad.Protocol

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
      # SPEC §11.8.10 PR4: independent of workpad. The summary protocol
      # uses `addComment`, which is already on the default mutation
      # allowlist, so no workpad mutation toggle is required.
      agent_workpad_enabled: false,
      codex_model: "gpt-5.5"
    )

    Application.delete_env(:symphony_elixir, :github_client)
    Adapter.invalidate_cache()

    :ok
  end

  @tag timeout: :timer.minutes(5)
  test "addComment with §11.8.10 marker shape round-trips through github_graphql" do
    {issue_number, subject_id} =
      create_throwaway_issue!("[session-summary-live-test] addComment + query round-trip")

    thread_id = "thr-test-#{System.unique_integer([:positive])}"
    open_marker = Protocol.session_summary_marker_open("v1", thread_id)
    close_marker = Protocol.session_summary_marker_close("v1", thread_id)

    summary_body =
      """
      #{open_marker}
      Session: #{thread_id}
      Attempt: 0
      Dispatched: 2026-05-11T10:00:00Z
      Completed: 2026-05-11T10:01:23Z
      Duration: 0h1m23s
      Model: gpt-5.5
      Stop reason: agent_exit_normal

      Smoke test for SPEC §11.8.10 live round-trip. Safe to close.
      #{close_marker}
      """

    # 1. Post the session-summary comment via the same surface the agent uses.
    assert {:ok,
            %{
              "data" => %{
                "addComment" => %{
                  "commentEdge" => %{
                    "node" => %{"id" => comment_id}
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
                 "variables" => %{"subject" => subject_id, "body" => summary_body}
               })
             end)

    assert is_binary(comment_id)

    # 2. Query the issue comments and assert the summary is intact.
    {:ok, %{"data" => %{"repository" => %{"issue" => %{"comments" => %{"nodes" => nodes}}}}}} =
      GithubGraphqlTool.handle(%{
        "query" => """
        query($num: Int!) {
          repository(owner: "archelab", name: "symphony") {
            issue(number: $num) {
              comments(first: 100) {
                nodes { id body }
              }
            }
          }
        }
        """,
        "variables" => %{"num" => issue_number}
      })

    matching =
      Enum.find(nodes, fn n ->
        is_binary(n["body"]) and String.contains?(n["body"], open_marker)
      end)

    assert matching != nil,
           "expected a comment containing #{inspect(open_marker)} but found none"

    body = matching["body"]

    # 3. Header well-formedness — the seven §11.8.10 fields are present and
    # parseable.
    for field <- Protocol.session_summary_header_fields() do
      assert body =~ ~r/^\s*#{Atom.to_string(field)}:\s+/m,
             "missing RFC822 header line for #{inspect(field)}"
    end

    # 4. Closing marker present.
    assert body =~ close_marker
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp create_throwaway_issue!(title_prefix) do
    title = "#{title_prefix} #{System.unique_integer([:positive])}"
    body = "Throwaway live test for SPEC §11.8.10 — safe to close."

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
end
