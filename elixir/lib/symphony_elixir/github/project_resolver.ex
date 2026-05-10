defmodule SymphonyElixir.Github.ProjectResolver do
  @moduledoc """
  Resolve a Project v2 node ID and probe the configured Status field.
  Spec §11.2 / §11.2.4. This module is stateless; callers (e.g., the adapter
  GenServer in Task 5a) are expected to cache resolved IDs + Status options
  for the process lifetime.
  """

  @resolve_by_id """
  query SymphonyResolveProjectById($id: ID!) {
    node(id: $id) { __typename ... on ProjectV2 { id title number } }
  }
  """

  @resolve_by_org """
  query SymphonyResolveProjectByOrg($owner: String!, $number: Int!) {
    organization(login: $owner) { projectV2(number: $number) { id title number } }
  }
  """

  @resolve_by_user """
  query SymphonyResolveProjectByUser($owner: String!, $number: Int!) {
    user(login: $owner) { projectV2(number: $number) { id title number } }
  }
  """

  @probe_status_field """
  query SymphonyStatusFieldProbe($projectId: ID!, $name: String!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        field(name: $name) {
          __typename
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      }
    }
  }
  """

  @type project :: %{id: String.t(), title: String.t() | nil, number: integer() | nil}

  @spec resolve(map(), function()) :: {:ok, project()} | {:error, {atom(), term()}}
  def resolve(%{project_id: id} = _settings, graphql_fn) when is_binary(id) and id != "" do
    case graphql_fn.(@resolve_by_id, %{"id" => id}, []) do
      {:ok, %{"data" => %{"node" => %{"__typename" => "ProjectV2"} = node}}} ->
        {:ok, %{id: node["id"], title: node["title"], number: node["number"]}}

      {:ok, %{"data" => %{"node" => %{"__typename" => other}}}} ->
        {:error, {:tracker_project_not_found, %{project_id: id, typename: other}}}

      {:ok, %{"data" => %{"node" => nil}}} ->
        {:error, {:tracker_project_not_found, %{project_id: id, typename: nil}}}

      {:ok, _} ->
        {:error, {:tracker_project_not_found, %{project_id: id}}}

      {:error, _} = err ->
        err
    end
  end

  def resolve(
        %{owner: owner, owner_type: "organization", project_number: n},
        graphql_fn
      )
      when is_binary(owner) and is_integer(n) do
    resolve_by_query(@resolve_by_org, %{"owner" => owner, "number" => n}, "organization", graphql_fn, owner)
  end

  def resolve(
        %{owner: owner, owner_type: "user", project_number: n},
        graphql_fn
      )
      when is_binary(owner) and is_integer(n) do
    resolve_by_query(@resolve_by_user, %{"owner" => owner, "number" => n}, "user", graphql_fn, owner)
  end

  def resolve(_settings, _graphql_fn) do
    {:error, {:missing_tracker_project_identifier, "neither project_id nor owner+project_number"}}
  end

  defp resolve_by_query(query, vars, root, graphql_fn, owner) do
    case graphql_fn.(query, vars, []) do
      {:ok, %{"data" => %{^root => %{"projectV2" => %{} = project}}}} ->
        {:ok, %{id: project["id"], title: project["title"], number: project["number"]}}

      {:ok, _} ->
        {:error, {:tracker_project_not_found, %{owner: owner, owner_type: root}}}

      {:error, _} = err ->
        err
    end
  end

  @spec probe_status_field(String.t(), String.t(), function()) ::
          {:ok, %{id: String.t(), name: String.t(), options: [{String.t(), String.t()}]}}
          | {:error, {atom(), term()}}
  def probe_status_field(project_id, field_name, graphql_fn)
      when is_binary(project_id) and is_binary(field_name) do
    response = graphql_fn.(@probe_status_field, %{"projectId" => project_id, "name" => field_name}, [])
    interpret_field_response(response, project_id, field_name)
  end

  defp interpret_field_response({:ok, %{"data" => %{"node" => %{"field" => field}}}}, project_id, field_name) do
    classify_field(field, project_id, field_name)
  end

  defp interpret_field_response({:ok, _}, _project_id, _field_name) do
    {:error, {:github_unknown_payload, "status field probe"}}
  end

  defp interpret_field_response({:error, _} = err, _project_id, _field_name), do: err

  defp classify_field(%{"__typename" => "ProjectV2SingleSelectField"} = f, _project_id, _field_name) do
    options =
      for o <- f["options"] || [] do
        {String.downcase(o["name"] || ""), o["id"]}
      end

    {:ok, %{id: f["id"], name: f["name"], options: options}}
  end

  defp classify_field(nil, project_id, field_name) do
    {:error, {:tracker_status_field_missing, %{field_name: field_name, project_id: project_id}}}
  end

  defp classify_field(%{"__typename" => other}, project_id, field_name) do
    {:error, {:tracker_status_field_missing, %{field_name: field_name, project_id: project_id, type: other}}}
  end
end
