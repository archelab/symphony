defmodule SymphonyElixir.Github.Normalize do
  @moduledoc """
  Convert raw GitHub GraphQL item nodes into the SPEC.md §4.1.1 Issue
  domain model. Also see §11.3 normalization rules.
  """

  alias SymphonyElixir.Github.Issue

  @no_status "<no status>"

  @doc """
  Sentinel returned by `item/2` when an item has no Status set.
  See spec §11.2.1.
  """
  @spec no_status() :: String.t()
  def no_status, do: @no_status

  @spec item(map(), keyword()) :: {:ok, Issue.t()} | {:skip, atom()}
  def item(%{"isArchived" => true}, _opts), do: {:skip, :archived}
  def item(%{"type" => "REDACTED"}, _opts), do: {:skip, :redacted}
  def item(%{"content" => nil}, _opts), do: {:skip, :no_content}

  def item(%{"type" => type, "id" => item_id, "content" => content} = item, opts) do
    kind = type_to_kind(type)
    state = effective_state(item)
    repository = build_repository(content["repository"])

    {identifier, number, url} = identifier_for(kind, item_id, content, repository)

    issue =
      Issue.new(%{
        id: item_id,
        identifier: identifier,
        kind: kind,
        title: content["title"] || "",
        description: content["body"],
        priority: nil,
        state: state,
        repository: repository,
        number: number,
        branch_name: branch_name(kind, content),
        url: url,
        labels: labels(content),
        blocked_by: blockers(kind, content),
        pr: pr(kind, content),
        issue_state: issue_state(kind, content),
        created_at: content["createdAt"],
        updated_at: content["updatedAt"]
      })

    _ = opts
    {:ok, issue}
  end

  defp type_to_kind("ISSUE"), do: "issue"
  defp type_to_kind("PULL_REQUEST"), do: "pull_request"
  defp type_to_kind("DRAFT_ISSUE"), do: "draft_issue"

  defp effective_state(%{"fieldValueByName" => %{"name" => name}}) when is_binary(name), do: name
  defp effective_state(_), do: @no_status

  defp build_repository(nil), do: nil

  defp build_repository(%{"nameWithOwner" => nwo, "owner" => %{"login" => login}, "name" => name} = repo) do
    %Issue.Repository{
      owner: login,
      name: name,
      name_with_owner: nwo,
      default_branch: get_in(repo, ["defaultBranchRef", "name"])
    }
  end

  defp build_repository(%{"nameWithOwner" => nwo} = repo) when is_binary(nwo) do
    # A redacted or otherwise malformed nameWithOwner (no `/`) cannot be split
    # into owner+name; treat it as "no repository" so the upstream `keep_repo?`
    # filter drops the item rather than raising on a bad destructuring match.
    case String.split(nwo, "/", parts: 2) do
      [owner, name] ->
        %Issue.Repository{
          owner: owner,
          name: name,
          name_with_owner: nwo,
          default_branch: get_in(repo, ["defaultBranchRef", "name"])
        }

      _ ->
        nil
    end
  end

  defp build_repository(_other), do: nil

  defp identifier_for("draft_issue", item_id, _content, _repo) do
    short = String.slice(item_id, -8, 8)
    {"draft:" <> short, nil, nil}
  end

  defp identifier_for(_kind, _item_id, content, %Issue.Repository{name_with_owner: nwo}) do
    number = content["number"]
    {nwo <> "#" <> Integer.to_string(number), number, content["url"]}
  end

  defp identifier_for(_kind, item_id, content, nil) do
    {"unknown:" <> item_id, content["number"], content["url"]}
  end

  defp branch_name("pull_request", %{"headRefName" => name}) when is_binary(name), do: name
  defp branch_name(_kind, _content), do: nil

  defp labels(%{"labels" => %{"nodes" => nodes}}) when is_list(nodes) do
    for %{"name" => name} <- nodes, is_binary(name), do: String.downcase(name)
  end

  defp labels(_), do: []

  defp blockers("issue", %{"trackedIssues" => %{"nodes" => nodes}}) when is_list(nodes) do
    for %{"id" => id, "number" => n, "state" => state, "repository" => %{"nameWithOwner" => nwo}} <- nodes do
      %Issue.Blocker{
        id: id,
        identifier: nwo <> "#" <> Integer.to_string(n),
        state: state
      }
    end
  end

  defp blockers(_kind, _content), do: []

  defp pr("pull_request", c) do
    %Issue.PR{
      state: c["state"],
      merged: c["merged"] == true,
      merged_at: c["mergedAt"],
      closed_at: c["closedAt"],
      is_draft: c["isDraft"] == true,
      base_ref_name: c["baseRefName"]
    }
  end

  defp pr(_kind, _c), do: nil

  defp issue_state("issue", %{"state" => state}), do: state
  defp issue_state("pull_request", %{"state" => state}), do: state
  defp issue_state(_, _), do: nil
end
