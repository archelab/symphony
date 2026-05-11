defmodule SymphonyElixir.Github.Adapter do
  @moduledoc """
  Implements the Tracker behaviour for GitHub Projects v2.
  Spec §11.1 / §11.2 / §11.3.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Github.{Client, Normalize, ProjectResolver, RateLimitGate}

  # Composable fragments — Phase 2 adds @pr_fragment_tier2 by concatenation
  # without rewriting the surrounding query. Spec §11.7 expansion.
  @issue_fragment """
  ... on Issue {
    id number title body url state createdAt updatedAt
    repository {
      nameWithOwner owner { login } name
      defaultBranchRef { name }
    }
    labels(first: 50) { nodes { name } }
    trackedIssues(first: 50) {
      nodes { id number state repository { nameWithOwner } }
    }
  }
  """

  @pr_fragment_tier1 """
  ... on PullRequest {
    id number title body url state merged mergedAt closedAt isDraft headRefName baseRefName createdAt updatedAt
    repository {
      nameWithOwner owner { login } name
      defaultBranchRef { name }
    }
    labels(first: 50) { nodes { name } }
  }
  """

  @draft_fragment """
  ... on DraftIssue {
    id title body createdAt updatedAt
  }
  """

  @candidate_query """
  query SymphonyProjectItems($projectId: ID!, $first: Int!, $after: String) {
    rateLimit { limit cost remaining used resetAt }
    node(id: $projectId) {
      ... on ProjectV2 {
        id title number
        items(first: $first, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id type isArchived createdAt updatedAt
            fieldValueByName(name: "Status") {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
            }
            content {
              __typename
              #{@issue_fragment}
              #{@pr_fragment_tier1}
              #{@draft_fragment}
            }
          }
        }
      }
    }
  }
  """

  @refresh_query """
  query SymphonyRefresh($ids: [ID!]!) {
    rateLimit { remaining resetAt }
    nodes(ids: $ids) {
      __typename
      ... on ProjectV2Item {
        id type isArchived
        fieldValueByName(name: "Status") {
          ... on ProjectV2ItemFieldSingleSelectValue { name }
        }
        content {
          __typename
          ... on Issue {
            id number state repository { nameWithOwner }
            trackedIssues(first: 50) {
              nodes { id number state repository { nameWithOwner } }
            }
          }
          ... on PullRequest { id number state merged repository { nameWithOwner } }
          ... on DraftIssue  { id }
        }
      }
    }
  }
  """

  @page_size 100

  @impl true
  def fetch_candidate_issues do
    with {:ok, project} <- ensure_resolved(),
         {:ok, items} <- paginate_items(project.id) do
      tracker = Config.settings!().tracker
      active = Enum.map(tracker.active_states, &String.downcase/1)
      terminal = Enum.map(tracker.terminal_states, &String.downcase/1)

      issues =
        items
        |> normalized_filtered_issues(tracker)
        |> Stream.filter(&active?(&1, active, terminal))
        |> Enum.to_list()

      {:ok, issues}
    end
  end

  @doc """
  Fetch normalized issues whose Project Status field name (downcased) appears
  in `state_names`. Empty list short-circuits to `{:ok, []}` without calling
  the GraphQL API.

  Note: this matches by Status field name only and does NOT apply the
  terminal-OR rule from spec §11.2.1. A merged PR sitting in `In Progress`
  matches `["In Progress"]` but NOT `["Done"]` even though it is terminal.
  Callers needing terminal-state semantics should use
  `fetch_candidate_issues/0` and inspect each issue's `issue_state` field.
  """
  @impl true
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, project} <- ensure_resolved(),
         {:ok, items} <- paginate_items(project.id) do
      tracker = Config.settings!().tracker
      wanted = Enum.map(state_names, &String.downcase/1)

      issues =
        items
        |> normalized_filtered_issues(tracker)
        |> Stream.filter(fn issue -> String.downcase(issue.state) in wanted end)
        |> Enum.to_list()

      {:ok, issues}
    end
  end

  # Shared page → normalize → kind/repo filter pipeline used by both
  # fetch_candidate_issues/0 and fetch_issues_by_states/1. Returns a Stream;
  # callers attach the final state-filter clause.
  defp normalized_filtered_issues(items, tracker) do
    items
    |> Stream.map(&Normalize.item(&1, status_field: tracker.status_field))
    |> Stream.flat_map(fn
      {:ok, issue} -> [issue]
      {:skip, _} -> []
    end)
    |> Stream.filter(&keep_kind?(&1, tracker.include_kinds))
    |> Stream.filter(&keep_repo?(&1, tracker.repo, tracker.owner))
  end

  @impl true
  def fetch_issue_states_by_ids([]), do: {:ok, []}

  def fetch_issue_states_by_ids(ids) when is_list(ids) do
    case graphql(@refresh_query, %{"ids" => ids}) do
      {:ok, %{"data" => %{"nodes" => nodes}}} ->
        {:ok, refresh_results(nodes)}

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Internals
  # ============================================================

  defp refresh_results(nodes) when is_list(nodes) do
    for node <- nodes,
        is_map(node),
        node["__typename"] == "ProjectV2Item",
        node["type"] != "REDACTED",
        node["isArchived"] != true,
        # Drop phantom-content rows: anything whose content is missing or of
        # an unrecognized __typename would otherwise produce an `unknown:<id>`
        # identifier that no caller can act on. Spec §11.3 normalization keeps
        # the recognized triplet of Issue / PullRequest / DraftIssue.
        get_in(node, ["content", "__typename"]) in ["Issue", "PullRequest", "DraftIssue"] do
      state = get_in(node, ["fieldValueByName", "name"]) || Normalize.no_status()

      %{
        id: node["id"],
        identifier: identifier_from_refresh(node),
        state: terminal_or_state(node, state),
        blocked_by: blocked_by_from_refresh(node)
      }
    end
  end

  # SPEC §8.2.1 / §8.5 Part C: the running-worker reconcile needs the current
  # `blocked_by` set to detect CLOSED→OPEN transitions on dependencies. We
  # surface the normalized list (`[%{id, identifier, state}]`) on Issue rows
  # and an empty list otherwise so the orchestrator can compare against the
  # snapshot taken at dispatch.
  defp blocked_by_from_refresh(%{"content" => %{"__typename" => "Issue"} = content}) do
    case get_in(content, ["trackedIssues", "nodes"]) do
      nodes when is_list(nodes) ->
        for %{"id" => id, "number" => n, "state" => state, "repository" => %{"nameWithOwner" => nwo}} <-
              nodes do
          %{id: id, identifier: "#{nwo}##{n}", state: state}
        end

      _ ->
        []
    end
  end

  defp blocked_by_from_refresh(_node), do: []

  defp identifier_from_refresh(%{
         "content" => %{"__typename" => "Issue", "number" => n, "repository" => %{"nameWithOwner" => nwo}}
       }),
       do: "#{nwo}##{n}"

  defp identifier_from_refresh(%{
         "content" => %{"__typename" => "PullRequest", "number" => n, "repository" => %{"nameWithOwner" => nwo}}
       }),
       do: "#{nwo}##{n}"

  defp identifier_from_refresh(%{"content" => %{"__typename" => "DraftIssue", "id" => id}}),
    do: "draft:" <> String.slice(id, -8, 8)

  defp terminal_or_state(%{"content" => %{"__typename" => "Issue", "state" => "CLOSED"}}, _), do: "<closed>"

  defp terminal_or_state(%{"content" => %{"__typename" => "PullRequest", "state" => state}}, _)
       when state in ["CLOSED", "MERGED"],
       do: "<#{String.downcase(state)}>"

  defp terminal_or_state(_node, state), do: state

  # `acc` collects per-page node lists in REVERSE order ([page_n, ..., page_1]);
  # the final reverse + flatten happens once at the terminal clause so the
  # accumulation is O(total_items) rather than the O(n²) `acc ++ nodes` it
  # replaced. Final list order matches GitHub's pagination order (page 1 items,
  # then page 2, ...).
  defp paginate_items(project_id), do: paginate_items(project_id, nil, [])

  defp paginate_items(project_id, after_cursor, acc) do
    case graphql(@candidate_query, %{"projectId" => project_id, "first" => @page_size, "after" => after_cursor}) do
      {:ok, %{"data" => %{"node" => %{"items" => %{"pageInfo" => page_info, "nodes" => nodes}}}}} ->
        handle_page(project_id, page_info, nodes, acc)

      {:ok, _} ->
        {:error, {:github_unknown_payload, "candidate items"}}

      {:error, _} = err ->
        err
    end
  end

  defp handle_page(project_id, page_info, nodes, acc) do
    new_acc = [nodes || [] | acc]

    cond do
      page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) ->
        paginate_items(project_id, page_info["endCursor"], new_acc)

      page_info["hasNextPage"] == true ->
        {:error, {:github_missing_end_cursor, %{}}}

      true ->
        {:ok, new_acc |> Enum.reverse() |> Enum.concat()}
    end
  end

  defp keep_kind?(%{kind: kind}, include_kinds) when is_list(include_kinds), do: kind in include_kinds

  defp keep_repo?(%{kind: "draft_issue"}, _repo, _owner), do: true
  defp keep_repo?(_, repo, _owner) when repo in [nil, ""], do: true
  defp keep_repo?(%{repository: nil}, _repo, _owner), do: false

  defp keep_repo?(%{repository: %{owner: r_owner, name: r_name}}, repo_filter, owner_filter) do
    case String.split(repo_filter, "/", parts: 2) do
      [bare_name] ->
        # Short form: "<repo>". Requires owner match against tracker.owner.
        is_binary(owner_filter) and String.downcase(r_owner) == String.downcase(owner_filter) and
          r_name == bare_name

      [filter_owner, filter_name] ->
        # Cross-owner long form: "<owner>/<repo>".
        String.downcase(r_owner) == String.downcase(filter_owner) and r_name == filter_name
    end
  end

  defp active?(%{kind: "draft_issue"} = issue, active_states, terminal_states) do
    state_lc = String.downcase(issue.state)

    state_lc != Normalize.no_status() and state_lc in active_states and
      state_lc not in terminal_states
  end

  defp active?(issue, active_states, terminal_states) do
    state_lc = String.downcase(issue.state)

    cond do
      state_lc == Normalize.no_status() -> false
      state_lc in terminal_states -> false
      issue.issue_state in ["CLOSED", "MERGED"] -> false
      state_lc in active_states -> true
      true -> false
    end
  end

  defp ensure_resolved do
    tracker = Config.settings!().tracker
    cache_key = config_cache_key(tracker)

    case :persistent_term.get({__MODULE__, :resolved}, :unset) do
      {^cache_key, project, _status} ->
        {:ok, project}

      _ ->
        with {:ok, project} <- ProjectResolver.resolve(tracker, &graphql/3),
             {:ok, status} <-
               ProjectResolver.probe_status_field(project.id, tracker.status_field, &graphql/3) do
          :persistent_term.put({__MODULE__, :resolved}, {cache_key, project, status})
          {:ok, project}
        end
    end
  end

  # Cache key changes when any tracker setting that affects resolution changes,
  # so a WORKFLOW.md reload that points at a new project transparently
  # invalidates the cache. Spec §11.2 says the resolved ID SHOULD be cached
  # for the lifetime of the process — but only while the underlying config is
  # unchanged.
  defp config_cache_key(tracker) do
    {tracker.endpoint, tracker.api_token, tracker.owner, tracker.owner_type, tracker.project_id, tracker.project_number, tracker.status_field}
  end

  @doc false
  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    _ = :persistent_term.erase({__MODULE__, :resolved})
    :ok
  end

  defp graphql(query, variables, opts \\ []) do
    case RateLimitGate.gated?() do
      {:gated, ms_remaining} ->
        {:error, {:github_rate_limited, %{retry_after_seconds: div(ms_remaining, 1_000) + 1}}}

      :open ->
        do_graphql(query, variables, opts)
    end
  end

  defp do_graphql(query, variables, opts) do
    fun = Application.get_env(:symphony_elixir, :github_client, &Client.graphql/3)
    tracker = Config.settings!().tracker

    result =
      fun.(query, variables, Keyword.merge([endpoint: tracker.endpoint, token: tracker.api_token], opts))

    record_rate_limit(result)
    result
  end

  defp record_rate_limit({:error, {:github_rate_limited, %{retry_after_seconds: n}}})
       when is_integer(n) do
    RateLimitGate.record_secondary(n)
  end

  defp record_rate_limit({:ok, %{"data" => %{"rateLimit" => %{"remaining" => 0, "resetAt" => reset_at}}}}) do
    RateLimitGate.record_primary(reset_at)
  end

  defp record_rate_limit(_), do: :ok
end
