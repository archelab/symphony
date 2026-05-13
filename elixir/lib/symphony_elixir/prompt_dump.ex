defmodule SymphonyElixir.PromptDump do
  @moduledoc """
  Builds a publishable dump of the Symphony-rendered startup payload.

  The dump intentionally excludes hidden platform/system/developer messages,
  Codex runtime internals, and secret values. It records the rendered
  `WORKFLOW.md` prompt plus the runtime envelope that Symphony sends through
  app-server.
  """

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{Config, PromptBuilder, Workspace}
  alias SymphonyElixir.Github.{Client, Issue, Normalize}

  @env_names ~w(
    GH_TOKEN
    GITHUB_TOKEN
    AGENT_BROWSER_HOME
    XDG_RUNTIME_DIR
    AGENT_BROWSER_IDLE_TIMEOUT_MS
    AGENT_BROWSER_CONTENT_BOUNDARIES
  )

  @issue_lookup_query """
  query SymphonyPromptDumpIssue($owner: String!, $repo: String!, $number: Int!, $statusField: String!) {
    repository(owner: $owner, name: $repo) {
      issueOrPullRequest(number: $number) {
        __typename
        ... on Issue {
          projectItems(first: 20) { nodes { ...ProjectItemForPromptDump } }
        }
        ... on PullRequest {
          projectItems(first: 20) { nodes { ...ProjectItemForPromptDump } }
        }
      }
    }
  }

  fragment ProjectItemForPromptDump on ProjectV2Item {
    id type isArchived createdAt updatedAt
    project { id title number }
    fieldValueByName(name: $statusField) {
      __typename
      ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
    }
    content {
      __typename
      ... on Issue {
        id number title body url state createdAt updatedAt
        repository {
          nameWithOwner owner { login } name
          defaultBranchRef { name }
        }
        labels(first: 50) { nodes { name } }
        blockedBy(first: 50) {
          nodes { id number state repository { nameWithOwner } }
        }
        trackedIssues(first: 50) {
          nodes { id number state repository { nameWithOwner } }
        }
        subIssues(first: 50) {
          nodes { id number state repository { nameWithOwner } }
        }
      }
      ... on PullRequest {
        id number title body url state merged mergedAt closedAt isDraft headRefName baseRefName createdAt updatedAt
        repository {
          nameWithOwner owner { login } name
          defaultBranchRef { name }
        }
        labels(first: 50) { nodes { name } }
      }
    }
  }
  """

  @type dump_option ::
          {:attempt, non_neg_integer() | nil}
          | {:dispatched_at, String.t()}
          | {:graphql_fun, (String.t(), map(), Client.opts() -> {:ok, map()} | {:error, term()})}
          | {:model, String.t() | nil}
          | {:prior_sessions, [map()]}
          | {:runtime_settings, Config.codex_runtime_settings()}
          | {:settings, Config.Schema.t()}
          | {:thread_id, String.t()}
          | {:workspace, Path.t()}

  @spec env_names() :: [String.t()]
  def env_names, do: @env_names

  @spec dump(Issue.t(), [dump_option()]) :: {:ok, String.t()} | {:error, term()}
  def dump(%Issue{} = issue, opts \\ []) when is_list(opts) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)
    workspace = Keyword.get_lazy(opts, :workspace, fn -> default_workspace(issue, settings) end)

    with {:ok, runtime_settings} <- runtime_settings(workspace, opts) do
      prompt = PromptBuilder.build_prompt(issue, prompt_options(settings, opts))

      {:ok,
       format_dump(%{
         issue: issue,
         prompt: prompt,
         runtime_settings: runtime_settings,
         settings: settings,
         workspace: workspace
       })}
    end
  end

  @spec fetch_issue(String.t(), [dump_option()]) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue(identifier, opts \\ []) when is_binary(identifier) and is_list(opts) do
    with {:ok, parsed} <- parse_issue_identifier(identifier),
         settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0),
         {:ok, response} <- fetch_issue_payload(parsed, settings, opts),
         {:ok, item} <- select_project_item(response, settings),
         {:ok, issue} <- Normalize.item(item, status_field: settings.tracker.status_field) do
      {:ok, issue}
    else
      {:skip, reason} -> {:error, {:issue_skipped, reason}}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_issue_payload(%{owner: owner, repo: repo, number: number}, settings, opts) do
    graphql_fun = Keyword.get(opts, :graphql_fun, &Client.graphql/3)

    graphql_fun.(
      @issue_lookup_query,
      %{
        "owner" => owner,
        "repo" => repo,
        "number" => number,
        "statusField" => settings.tracker.status_field
      },
      endpoint: settings.tracker.endpoint,
      token: settings.tracker.api_token
    )
  end

  defp select_project_item(%{"data" => %{"repository" => repository}}, settings) when is_map(repository) do
    items = get_in(repository, ["issueOrPullRequest", "projectItems", "nodes"]) || []

    case Enum.find(items, &target_project?(&1, settings)) do
      nil -> {:error, {:project_item_not_found, settings.tracker.project_id || settings.tracker.project_number}}
      item -> {:ok, item}
    end
  end

  defp select_project_item(_payload, _settings), do: {:error, {:github_unknown_payload, "prompt dump issue lookup"}}

  defp target_project?(%{"project" => %{"id" => project_id}}, %{tracker: %{project_id: configured_id}})
       when is_binary(configured_id) and configured_id != "" do
    project_id == configured_id
  end

  defp target_project?(%{"project" => %{"number" => project_number}}, %{tracker: %{project_number: configured_number}}) do
    project_number == configured_number
  end

  defp target_project?(_item, _settings), do: false

  defp parse_issue_identifier(identifier) do
    case Regex.run(~r/\A([^\/\s#]+)\/([^\/\s#]+)#([1-9][0-9]*)\z/, identifier) do
      [_full, owner, repo, number] ->
        {:ok, %{owner: owner, repo: repo, number: String.to_integer(number)}}

      _ ->
        {:error, {:invalid_issue_identifier, identifier}}
    end
  end

  defp runtime_settings(workspace, opts) do
    case Keyword.fetch(opts, :runtime_settings) do
      {:ok, runtime_settings} -> {:ok, runtime_settings}
      :error -> Config.codex_runtime_settings(workspace)
    end
  end

  defp prompt_options(settings, opts) do
    [
      attempt: Keyword.get(opts, :attempt),
      thread_id: Keyword.get(opts, :thread_id, "PROMPT_DUMP_THREAD_ID"),
      dispatched_at: Keyword.get_lazy(opts, :dispatched_at, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end),
      model: Keyword.get(opts, :model, settings.codex.model),
      prior_sessions: Keyword.get(opts, :prior_sessions, [])
    ]
  end

  defp default_workspace(%Issue{identifier: identifier}, settings) do
    settings.workspace.root
    |> Path.join(Workspace.workspace_key(identifier))
    |> Path.expand()
  end

  defp format_dump(%{
         issue: issue,
         prompt: prompt,
         runtime_settings: runtime_settings,
         settings: settings,
         workspace: workspace
       }) do
    """
    # Symphony Prompt Dump

    This is a publishable startup payload for `#{issue.identifier}`.

    It intentionally excludes hidden platform/system/developer instructions, Codex runtime internals, repo/global instructions, matching skill bodies, and secret values. Codex may still load repo `AGENTS.md`, global instructions, and matching skills outside the Symphony-rendered first-turn prompt.

    ## Runtime Envelope

    - `cwd`: `#{workspace}`
    - Thread `approvalPolicy`: `#{inline(runtime_settings.approval_policy)}`
    - Thread `sandbox`: `#{runtime_settings.thread_sandbox}`
    - Turn `sandboxPolicy`:

    ```json
    #{json(runtime_settings.turn_sandbox_policy)}
    ```

    - Network access for the turn sandbox: `#{network_access(runtime_settings.turn_sandbox_policy)}`
    - Writable workspace root: the issue workspace
    - Codex command: `#{settings.codex.command}`
    - Codex model: `#{settings.codex.model || "(unspecified)"}`

    ## Injected Environment

    Symphony injects the following environment variables by name. Secret values are not reproduced.

    #{Enum.map_join(@env_names, "\n", &"- `#{&1}`")}

    ## Dynamic Tools

    The thread registers these dynamic tool schemas.

    ```json
    #{json(DynamicTool.tool_specs())}
    ```

    ## Rendered Symphony Prompt

    The following block is the rendered `WORKFLOW.md` prompt for this issue using the supplied workpad variables.

    ```text
    #{prompt}
    ```
    """
  end

  defp inline(value) when is_binary(value), do: value
  defp inline(value), do: Jason.encode!(value)

  defp network_access(%{"networkAccess" => value}), do: inspect(value)
  defp network_access(_policy), do: "false"

  defp json(value), do: Jason.encode!(value, pretty: true)
end
