defmodule SymphonyElixir.Github.ProjectResolverTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Github.ProjectResolver

  defmodule FakeClient do
    def respond(query_to_response) do
      pid = self()
      fn query, variables, _opts -> handle(query, variables, pid, query_to_response) end
    end

    defp handle(query, variables, pid, query_to_response) do
      send(pid, {:graphql, query, variables})
      lookup(query, query_to_response)
    end

    defp lookup(query, query_to_response) do
      case Enum.find(query_to_response, fn {pat, _} -> String.contains?(query, pat) end) do
        {_pat, response} -> response
        nil -> {:error, {:github_unknown_payload, "no fake match"}}
      end
    end
  end

  test "resolves by project_id and confirms ProjectV2 typename" do
    fake =
      FakeClient.respond([
        {"node(id:",
         {:ok,
          %{
            "data" => %{
              "node" => %{
                "__typename" => "ProjectV2",
                "id" => "PVT_xxx",
                "title" => "Symphony",
                "number" => 1
              }
            }
          }}}
      ])

    assert {:ok, project} =
             ProjectResolver.resolve(
               %{project_id: "PVT_xxx", project_number: nil, owner: nil, owner_type: "organization"},
               fake
             )

    assert project.id == "PVT_xxx"
    assert project.number == 1
  end

  test "non-ProjectV2 node id raises tracker_project_not_found" do
    fake =
      FakeClient.respond([
        {"node(id:", {:ok, %{"data" => %{"node" => %{"__typename" => "Issue", "id" => "I_xxx"}}}}}
      ])

    assert {:error, {:tracker_project_not_found, _}} =
             ProjectResolver.resolve(
               %{project_id: "I_xxx", project_number: nil, owner: nil, owner_type: "organization"},
               fake
             )
  end

  test "resolves by owner + project_number when owner_type is organization" do
    fake =
      FakeClient.respond([
        {"organization(login:",
         {:ok,
          %{
            "data" => %{
              "organization" => %{
                "projectV2" => %{"id" => "PVT_yyy", "title" => "Symphony", "number" => 1}
              }
            }
          }}}
      ])

    assert {:ok, project} =
             ProjectResolver.resolve(
               %{project_id: nil, project_number: 1, owner: "archelab", owner_type: "organization"},
               fake
             )

    assert project.id == "PVT_yyy"
  end

  test "null project on owner+number resolution raises tracker_project_not_found" do
    fake =
      FakeClient.respond([
        {"organization(login:", {:ok, %{"data" => %{"organization" => %{"projectV2" => nil}}}}}
      ])

    assert {:error, {:tracker_project_not_found, _}} =
             ProjectResolver.resolve(
               %{project_id: nil, project_number: 99, owner: "archelab", owner_type: "organization"},
               fake
             )
  end

  test "probe Status field returns options when SingleSelect" do
    fake =
      FakeClient.respond([
        {"field(name:",
         {:ok,
          %{
            "data" => %{
              "node" => %{
                "field" => %{
                  "__typename" => "ProjectV2SingleSelectField",
                  "id" => "PVTSSF_xxx",
                  "name" => "Status",
                  "options" => [
                    %{"id" => "f75ad846", "name" => "Todo"},
                    %{"id" => "5264dd8c", "name" => "Agent Ready"}
                  ]
                }
              }
            }
          }}}
      ])

    assert {:ok, %{id: "PVTSSF_xxx", options: options}} =
             ProjectResolver.probe_status_field("PVT_xxx", "Status", fake)

    assert {"todo", "f75ad846"} in options
    assert {"agent ready", "5264dd8c"} in options
  end

  test "probe returns tracker_status_field_missing when field is null" do
    fake =
      FakeClient.respond([
        {"field(name:", {:ok, %{"data" => %{"node" => %{"field" => nil}}}}}
      ])

    assert {:error, {:tracker_status_field_missing, _}} =
             ProjectResolver.probe_status_field("PVT_xxx", "Status", fake)
  end

  test "probe returns tracker_status_field_missing when field is not SingleSelect" do
    fake =
      FakeClient.respond([
        {"field(name:",
         {:ok,
          %{
            "data" => %{
              "node" => %{
                "field" => %{"__typename" => "ProjectV2Field", "id" => "PVTF_x", "name" => "Status"}
              }
            }
          }}}
      ])

    assert {:error, {:tracker_status_field_missing, _}} =
             ProjectResolver.probe_status_field("PVT_xxx", "Status", fake)
  end

  # ---------------------------------------------------------------------------
  # Coverage gates — exercise branches not covered by the 7 PLAN tests.
  # These are not new spec requirements; they ensure 100% line/branch coverage
  # on SymphonyElixir.Github.ProjectResolver under `mix test_strict`.
  # ---------------------------------------------------------------------------

  test "resolves by owner + project_number when owner_type is user" do
    fake =
      FakeClient.respond([
        {"user(login:",
         {:ok,
          %{
            "data" => %{
              "user" => %{
                "projectV2" => %{"id" => "PVT_uuu", "title" => "Personal", "number" => 5}
              }
            }
          }}}
      ])

    assert {:ok, %{id: "PVT_uuu", number: 5}} =
             ProjectResolver.resolve(
               %{project_id: nil, project_number: 5, owner: "octocat", owner_type: "user"},
               fake
             )
  end

  test "node nil on resolve_by_id raises tracker_project_not_found with typename: nil" do
    fake =
      FakeClient.respond([
        {"node(id:", {:ok, %{"data" => %{"node" => nil}}}}
      ])

    assert {:error, {:tracker_project_not_found, %{project_id: "PVT_x", typename: nil}}} =
             ProjectResolver.resolve(
               %{project_id: "PVT_x", project_number: nil, owner: nil, owner_type: "organization"},
               fake
             )
  end

  test "malformed resolve_by_id payload falls through to tracker_project_not_found" do
    fake =
      FakeClient.respond([
        {"node(id:", {:ok, %{"data" => %{"unexpected" => true}}}}
      ])

    assert {:error, {:tracker_project_not_found, %{project_id: "PVT_x"}}} =
             ProjectResolver.resolve(
               %{project_id: "PVT_x", project_number: nil, owner: nil, owner_type: "organization"},
               fake
             )
  end

  test "resolve_by_id propagates graphql client errors" do
    fake = fn _q, _v, _o -> {:error, {:tracker_permission_denied, %{http: 401}}} end

    assert {:error, {:tracker_permission_denied, _}} =
             ProjectResolver.resolve(
               %{project_id: "PVT_x", project_number: nil, owner: nil, owner_type: "organization"},
               fake
             )
  end

  test "resolve_by_query propagates graphql client errors" do
    fake = fn _q, _v, _o -> {:error, {:github_api_request, :timeout}} end

    assert {:error, {:github_api_request, :timeout}} =
             ProjectResolver.resolve(
               %{project_id: nil, project_number: 1, owner: "archelab", owner_type: "organization"},
               fake
             )
  end

  test "resolve without project_id or owner+project_number returns missing_tracker_project_identifier" do
    fake = fn _q, _v, _o -> {:error, :should_not_be_called} end

    assert {:error, {:missing_tracker_project_identifier, _}} =
             ProjectResolver.resolve(
               %{project_id: nil, project_number: nil, owner: nil, owner_type: "organization"},
               fake
             )
  end

  test "probe_status_field propagates graphql client errors" do
    fake = fn _q, _v, _o -> {:error, {:github_rate_limited, %{retry_after_seconds: 30}}} end

    assert {:error, {:github_rate_limited, _}} =
             ProjectResolver.probe_status_field("PVT_x", "Status", fake)
  end

  test "probe_status_field returns github_unknown_payload on malformed response" do
    fake = fn _q, _v, _o -> {:ok, %{"data" => %{"unexpected" => true}}} end

    assert {:error, {:github_unknown_payload, "status field probe"}} =
             ProjectResolver.probe_status_field("PVT_x", "Status", fake)
  end

  test "probe_status_field handles SingleSelectField with nil options" do
    fake =
      FakeClient.respond([
        {"field(name:",
         {:ok,
          %{
            "data" => %{
              "node" => %{
                "field" => %{
                  "__typename" => "ProjectV2SingleSelectField",
                  "id" => "PVTSSF_x",
                  "name" => "Status",
                  "options" => nil
                }
              }
            }
          }}}
      ])

    assert {:ok, %{id: "PVTSSF_x", options: []}} =
             ProjectResolver.probe_status_field("PVT_x", "Status", fake)
  end

  test "probe_status_field handles option with nil name (lower-cases empty string)" do
    fake =
      FakeClient.respond([
        {"field(name:",
         {:ok,
          %{
            "data" => %{
              "node" => %{
                "field" => %{
                  "__typename" => "ProjectV2SingleSelectField",
                  "id" => "PVTSSF_x",
                  "name" => "Status",
                  "options" => [%{"id" => "x", "name" => nil}]
                }
              }
            }
          }}}
      ])

    assert {:ok, %{options: [{"", "x"}]}} =
             ProjectResolver.probe_status_field("PVT_x", "Status", fake)
  end
end
