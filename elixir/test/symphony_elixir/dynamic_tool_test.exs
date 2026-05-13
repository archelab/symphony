defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.{AgentBrowserTool, DynamicTool}

  test "tool_specs advertises the github_graphql and agent_browser input contracts" do
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

    %{
      "description" => browser_description,
      "inputSchema" => %{
        "properties" => %{
          "action" => %{"enum" => actions},
          "url" => %{"type" => "string"}
        },
        "required" => ["action"],
        "type" => "object"
      },
      "name" => "agent_browser"
    } = Enum.find(specs, &(&1["name"] == "agent_browser"))

    assert browser_description =~ "localhost"
    assert "open" in actions
    assert "snapshot_interactive" in actions
    assert "click" in actions
    assert "fill" in actions
    assert "console" in actions
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["github_graphql", "agent_browser"]
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

  describe "agent_browser dispatch" do
    setup do
      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :agent_browser_executable)
        Application.delete_env(:symphony_elixir, :agent_browser_runner)
      end)

      :ok
    end

    test "public handle helpers cover default arity and invalid arguments" do
      workspace = tmp_workspace()

      Application.put_env(:symphony_elixir, :agent_browser_runner, fn command, cwd, _env ->
        assert command == ["get", "title"]
        assert cwd == workspace
        {"title", 0}
      end)

      assert {:ok, %{action: "get_title", output: "title"}} =
               AgentBrowserTool.handle(%{"action" => "get_title"}, workspace: workspace)

      assert {:error, {:workspace_required, _message}} = AgentBrowserTool.handle(%{"action" => "get_title"})
      assert {:error, {:invalid_arguments, _message}} = AgentBrowserTool.handle(:not_a_map, [])
    end

    test "open action rejects non-localhost URLs before calling the runner" do
      Application.put_env(:symphony_elixir, :agent_browser_runner, fn _command, _workspace, _env ->
        flunk("agent-browser runner should not be called for unsafe URLs")
      end)

      response =
        DynamicTool.execute(
          "agent_browser",
          %{"action" => "open", "url" => "https://example.com"},
          workspace: tmp_workspace()
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "localhost"
    end

    test "open action rejects non-http URLs before calling the runner" do
      Application.put_env(:symphony_elixir, :agent_browser_runner, fn _command, _workspace, _env ->
        flunk("agent-browser runner should not be called for unsafe URLs")
      end)

      response =
        DynamicTool.execute(
          "agent_browser",
          %{"action" => "open", "url" => "file:///tmp/index.html"},
          workspace: tmp_workspace()
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "http"
    end

    test "open action requires a URL" do
      response = DynamicTool.execute("agent_browser", %{"action" => "open"}, workspace: tmp_workspace())

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "requires a url"
    end

    test "open action accepts IPv6 loopback URLs" do
      workspace = tmp_workspace()
      test_pid = self()

      Application.put_env(:symphony_elixir, :agent_browser_runner, fn command, cwd, _env ->
        send(test_pid, {:agent_browser_called, command, cwd})
        {"opened", 0}
      end)

      response =
        DynamicTool.execute(
          "agent_browser",
          %{"action" => "open", "url" => "http://[::1]:4001/"},
          workspace: workspace
        )

      assert response["success"] == true
      assert_received {:agent_browser_called, ["open", "http://[::1]:4001/"], ^workspace}
    end

    test "unsupported actions are rejected before calling the runner" do
      Application.put_env(:symphony_elixir, :agent_browser_runner, fn _command, _workspace, _env ->
        flunk("agent-browser runner should not be called for unsupported actions")
      end)

      response = DynamicTool.execute("agent_browser", %{"action" => "chat"}, workspace: tmp_workspace())

      assert response["success"] == false

      decoded = Jason.decode!(response["output"])
      assert decoded["error"]["message"] == "`agent_browser` rejected unsupported action `chat`."
      assert "click" in decoded["error"]["supportedActions"]
      assert "chat" not in decoded["error"]["supportedActions"]
    end

    test "missing action is rejected before calling the runner" do
      response = DynamicTool.execute("agent_browser", %{}, workspace: tmp_workspace())

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "requires an action"
    end

    test "open action runs host-side agent-browser with workspace-local runtime env" do
      workspace = tmp_workspace()
      test_pid = self()

      Application.put_env(:symphony_elixir, :agent_browser_runner, fn command, cwd, env ->
        send(test_pid, {:agent_browser_called, command, cwd, env})
        {"opened", 0}
      end)

      response =
        DynamicTool.execute(
          "agent_browser",
          %{"action" => "open", "url" => "http://127.0.0.1:4001/"},
          workspace: workspace
        )

      assert response["success"] == true

      assert_received {:agent_browser_called, ["open", "http://127.0.0.1:4001/"], ^workspace, env}

      assert Enum.sort(env) ==
               Enum.sort([
                 {"AGENT_BROWSER_HOME", Path.join(workspace, ".agent-browser")},
                 {"XDG_RUNTIME_DIR", Path.join(workspace, ".runtime")},
                 {"AGENT_BROWSER_IDLE_TIMEOUT_MS", "60000"},
                 {"AGENT_BROWSER_CONTENT_BOUNDARIES", "1"}
               ])

      assert File.dir?(Path.join(workspace, ".agent-browser"))
      assert File.dir?(Path.join(workspace, ".runtime"))

      assert Jason.decode!(response["output"]) == %{
               "action" => "open",
               "argv" => ["agent-browser", "open", "http://127.0.0.1:4001/"],
               "output" => "opened"
             }
    end

    test "snapshot action maps to interactive snapshot command" do
      workspace = tmp_workspace()
      test_pid = self()

      Application.put_env(:symphony_elixir, :agent_browser_runner, fn command, cwd, _env ->
        send(test_pid, {:agent_browser_called, command, cwd})
        {"@e1 button OK", 0}
      end)

      response =
        DynamicTool.execute("agent_browser", %{"action" => "snapshot_interactive"}, workspace: workspace)

      assert response["success"] == true
      assert_received {:agent_browser_called, ["snapshot", "-i"], ^workspace}
    end

    test "read and capture actions map to safe agent-browser commands" do
      workspace = tmp_workspace()
      test_pid = self()

      Application.put_env(:symphony_elixir, :agent_browser_runner, fn command, cwd, _env ->
        send(test_pid, {:agent_browser_called, command, cwd})
        {Enum.join(command, " "), 0}
      end)

      for {action, command} <- [
            {"wait_networkidle", ["wait", "--load", "networkidle"]},
            {"wait_text", ["wait", "--text", "Dashboard"]},
            {"wait_selector", ["wait", "@e1"]},
            {"wait_ms", ["wait", "250"]},
            {"get_url", ["get", "url"]},
            {"console", ["console"]},
            {"errors", ["errors"]},
            {"close", ["close"]},
            {"screenshot", ["screenshot"]}
          ] do
        args =
          case action do
            "wait_text" -> %{"action" => action, "text" => "Dashboard"}
            "wait_selector" -> %{"action" => action, "selector" => "@e1"}
            "wait_ms" -> %{"action" => action, "ms" => 250}
            _ -> %{"action" => action}
          end

        response = DynamicTool.execute("agent_browser", args, workspace: workspace)

        assert response["success"] == true
        assert_received {:agent_browser_called, ^command, ^workspace}
        assert Jason.decode!(response["output"])["action"] == action
      end
    end

    test "interaction actions map to allowlisted agent-browser commands" do
      workspace = tmp_workspace()
      test_pid = self()

      Application.put_env(:symphony_elixir, :agent_browser_runner, fn command, cwd, _env ->
        send(test_pid, {:agent_browser_called, command, cwd})
        {Enum.join(command, " "), 0}
      end)

      cases = [
        {%{"action" => "click", "selector" => "@e1"}, ["click", "@e1"]},
        {%{"action" => "click", "selector" => "@e2", "new_tab" => true}, ["click", "@e2", "--new-tab"]},
        {%{"action" => "fill", "selector" => "#email", "text" => "pedro@example.com"}, ["fill", "#email", "pedro@example.com"]},
        {%{"action" => "type", "selector" => "#search", "text" => "abc"}, ["type", "#search", "abc"]},
        {%{"action" => "press", "key" => "Control+a"}, ["press", "Control+a"]},
        {%{"action" => "select", "selector" => "#country", "value" => "BR"}, ["select", "#country", "BR"]},
        {%{"action" => "select", "selector" => "#roles", "values" => ["admin", "reviewer"]}, ["select", "#roles", "admin", "reviewer"]}
      ]

      for {args, command} <- cases do
        response = DynamicTool.execute("agent_browser", args, workspace: workspace)

        assert response["success"] == true
        assert_received {:agent_browser_called, ^command, ^workspace}
        assert Jason.decode!(response["output"])["argv"] == ["agent-browser" | command]
      end
    end

    test "interaction actions validate required fields before calling the runner" do
      Application.put_env(:symphony_elixir, :agent_browser_runner, fn _command, _workspace, _env ->
        flunk("agent-browser runner should not be called for invalid interaction arguments")
      end)

      for args <- [
            %{"action" => "click"},
            %{"action" => "fill", "selector" => "#email"},
            %{"action" => "type", "text" => "abc"},
            %{"action" => "press"},
            %{"action" => "press", "key" => "Control a"},
            %{"action" => "select"},
            %{"action" => "select", "selector" => "#country"},
            %{"action" => "select", "selector" => "#country", "values" => []},
            %{"action" => "wait_ms", "ms" => 60_001},
            %{"action" => "wait_text"},
            %{"action" => "wait_selector"},
            %{"action" => "screenshot", "path" => 123}
          ] do
        response = DynamicTool.execute("agent_browser", args, workspace: tmp_workspace())

        assert response["success"] == false
        assert Jason.decode!(response["output"])["error"]["message"] =~ "`agent_browser`"
      end
    end

    test "screenshot supports safe relative output paths and options" do
      workspace = tmp_workspace()
      test_pid = self()

      Application.put_env(:symphony_elixir, :agent_browser_runner, fn command, cwd, _env ->
        send(test_pid, {:agent_browser_called, command, cwd})
        {"saved", 0}
      end)

      response =
        DynamicTool.execute(
          "agent_browser",
          %{
            "action" => "screenshot",
            "selector" => "#main",
            "path" => "tmp/symphony-dashboard.png",
            "full" => true,
            "annotate" => true
          },
          workspace: workspace
        )

      assert response["success"] == true

      assert_received {:agent_browser_called, ["screenshot", "--full", "--annotate", "#main", "tmp/symphony-dashboard.png"], ^workspace}
    end

    test "screenshot rejects paths outside the issue workspace" do
      Application.put_env(:symphony_elixir, :agent_browser_runner, fn _command, _workspace, _env ->
        flunk("agent-browser runner should not be called for unsafe screenshot paths")
      end)

      response =
        DynamicTool.execute(
          "agent_browser",
          %{"action" => "screenshot", "path" => "../outside.png"},
          workspace: tmp_workspace()
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "inside the issue workspace"
    end

    test "default runner executes configured agent-browser executable" do
      workspace = tmp_workspace()
      executable = Path.join(workspace, "fake-agent-browser")
      env_trace = Path.join(workspace, "env.trace")

      File.write!(executable, """
      #!/bin/sh
      printf 'argv=%s\\n' "$*" > "#{env_trace}"
      printf 'home=%s\\n' "$AGENT_BROWSER_HOME" >> "#{env_trace}"
      printf 'runtime=%s\\n' "$XDG_RUNTIME_DIR" >> "#{env_trace}"
      printf 'fake title\\n'
      """)

      File.chmod!(executable, 0o755)
      Application.put_env(:symphony_elixir, :agent_browser_executable, executable)

      response = DynamicTool.execute("agent_browser", %{"action" => "get_title"}, workspace: workspace)

      assert response["success"] == true
      assert Jason.decode!(response["output"])["output"] == "fake title"

      assert File.read!(env_trace) ==
               """
               argv=get title
               home=#{Path.join(workspace, ".agent-browser")}
               runtime=#{Path.join(workspace, ".runtime")}
               """
    end

    test "runner failures surface structured output" do
      workspace = tmp_workspace()

      Application.put_env(:symphony_elixir, :agent_browser_runner, fn _command, _cwd, _env ->
        {"daemon failed", 1}
      end)

      response = DynamicTool.execute("agent_browser", %{"action" => "get_title"}, workspace: workspace)

      assert response["success"] == false

      assert Jason.decode!(response["output"]) == %{
               "error" => %{
                 "message" => "`agent_browser` command failed.",
                 "output" => "daemon failed",
                 "status" => 1
               }
             }
    end

    test "missing workspace is rejected" do
      response = DynamicTool.execute("agent_browser", %{"action" => "get_title"})

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "requires a local issue workspace"
    end

    test "runtime directory preparation failures surface structured output" do
      workspace = tmp_workspace()
      File.write!(Path.join(workspace, ".agent-browser"), "not a directory")

      response = DynamicTool.execute("agent_browser", %{"action" => "get_title"}, workspace: workspace)

      assert response["success"] == false
      decoded = Jason.decode!(response["output"])
      assert decoded["error"]["message"] =~ "could not prepare"
      assert decoded["error"]["path"] == Path.join(workspace, ".agent-browser")
    end
  end

  defp tmp_workspace do
    path = Path.join(System.tmp_dir!(), "symphony-agent-browser-tool-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
