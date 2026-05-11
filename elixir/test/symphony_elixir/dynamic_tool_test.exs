defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the github_graphql input contract" do
    specs = DynamicTool.tool_specs()

    %{
      "description" => description,
      "inputSchema" => %{
        "properties" => %{"query" => _, "variables" => _},
        "required" => ["query"],
        "type" => "object"
      },
      "name" => "github_graphql"
    } = Enum.find(specs, &(&1["name"] == "github_graphql"))

    assert description =~ "GitHub"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["github_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  describe "github_graphql dispatch" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

      :ok
    end

    test "string-form query is routed through github_graphql" do
      test_pid = self()

      Application.put_env(:symphony_elixir, :github_client, fn query, variables, opts ->
        send(test_pid, {:github_client_called, query, variables, opts})
        {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}}
      end)

      response = DynamicTool.execute("github_graphql", "  query Viewer { viewer { login } }  ")

      assert_received {:github_client_called, "query Viewer { viewer { login } }", %{}, _opts}
      assert response["success"] == true
      assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"login" => "octocat"}}}
    end

    test "map-form query with variables forwards both" do
      test_pid = self()

      Application.put_env(:symphony_elixir, :github_client, fn query, variables, opts ->
        send(test_pid, {:github_client_called, query, variables, opts})
        {:ok, %{"data" => %{"ok" => true}}}
      end)

      response =
        DynamicTool.execute("github_graphql", %{
          "query" => "query Viewer { viewer { login } }",
          "variables" => %{"limit" => 10}
        })

      assert_received {:github_client_called, "query Viewer { viewer { login } }", %{"limit" => 10}, _opts}

      assert response["success"] == true
    end

    test "blank string-form query returns a failure payload without calling the client" do
      Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
        flunk("github client should not be called when the query is blank")
      end)

      response = DynamicTool.execute("github_graphql", "   ")

      assert response["success"] == false

      assert Jason.decode!(response["output"]) == %{
               "error" => %{
                 "message" => "`github_graphql` requires a non-empty `query` string."
               }
             }
    end

    test "invalid argument types return a failure payload" do
      Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
        flunk("github client should not be called when arguments are invalid")
      end)

      response = DynamicTool.execute("github_graphql", [:not, :valid])

      assert response["success"] == false

      assert Jason.decode!(response["output"]) == %{
               "error" => %{
                 "message" => "`github_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
               }
             }
    end

    test "mutations not on the allowlist surface as a structured failure" do
      Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
        flunk("github client should not be called for rejected mutations")
      end)

      response =
        DynamicTool.execute("github_graphql", %{"query" => "mutation { deleteProject(input: {}) { id } }"})

      assert response["success"] == false
      decoded = Jason.decode!(response["output"])
      assert decoded["error"]["message"] =~ "github_graphql"
      assert decoded["error"]["mutation"] == "deleteProject"
    end

    test "GraphQL error responses are surfaced as failures" do
      Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
        {:ok, %{"errors" => [%{"message" => "boom"}], "data" => nil}}
      end)

      response = DynamicTool.execute("github_graphql", %{"query" => "query { viewer { login } }"})

      assert response["success"] == false
      assert Jason.decode!(response["output"]) == %{"errors" => [%{"message" => "boom"}], "data" => nil}
    end

    test "client transport errors surface a structured failure payload" do
      Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
        {:error, {:request_failed, :timeout}}
      end)

      response = DynamicTool.execute("github_graphql", %{"query" => "query { viewer { login } }"})

      assert response["success"] == false
      decoded = Jason.decode!(response["output"])
      assert decoded["error"]["message"] == "GitHub GraphQL tool execution failed."
    end

    test "non-JSON-encodable client payloads fall back to inspect" do
      Application.put_env(:symphony_elixir, :github_client, fn _query, _variables, _opts ->
        {:ok, :ok}
      end)

      response = DynamicTool.execute("github_graphql", %{"query" => "query { viewer { login } }"})

      assert response["success"] == true
      assert response["output"] == ":ok"
    end
  end
end
