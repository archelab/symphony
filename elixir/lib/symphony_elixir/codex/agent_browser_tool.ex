defmodule SymphonyElixir.Codex.AgentBrowserTool do
  @moduledoc """
  Constrained host-side `agent-browser` dynamic tool.

  The tool lets sandboxed Codex agents request browser checks without launching
  Chrome from inside the Codex shell sandbox. The orchestrator executes a small
  allowlisted set of `agent-browser` commands with browser state rooted in the
  issue workspace.
  """

  @allowed_hosts MapSet.new(["127.0.0.1", "::1", "localhost"])
  @actions ~w(open wait_networkidle snapshot_interactive screenshot get_title get_url close)

  @type handle_error ::
          {:invalid_arguments, String.t()}
          | {:unsupported_action, String.t()}
          | {:unsafe_url, String.t()}
          | {:workspace_required, String.t()}
          | {:browser_runtime_dir_unavailable, Path.t(), File.posix()}
          | {:agent_browser_failed, non_neg_integer(), String.t()}

  @spec definition() :: %{name: String.t(), description: String.t(), parameters: map()}
  def definition do
    %{
      name: "agent_browser",
      description:
        "Run constrained host-side agent-browser checks for local UI verification. " <>
          "Only localhost/127.0.0.1 URLs and safe read/capture actions are supported.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @actions,
            "description" => "Browser action to run."
          },
          "url" => %{
            "type" => "string",
            "description" => "Required for action=open. Must be http(s)://localhost, http(s)://127.0.0.1, or http(s)://[::1]."
          }
        },
        "required" => ["action"],
        "additionalProperties" => false
      }
    }
  end

  @spec handle(term()) :: {:ok, map()} | {:error, handle_error()}
  def handle(args), do: handle(args, [])

  @spec handle(term(), keyword()) :: {:ok, map()} | {:error, handle_error()}
  def handle(args, opts) when is_map(args) do
    normalized = Map.new(args, fn {key, value} -> {to_string(key), value} end)

    with {:ok, workspace} <- workspace(opts),
         :ok <- prepare_runtime_dirs(workspace),
         {:ok, command} <- command(normalized, workspace) do
      run(command, workspace)
    end
  end

  def handle(_args, _opts) do
    {:error, {:invalid_arguments, "`agent_browser` expects an object with an action."}}
  end

  defp workspace(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" -> {:ok, workspace}
      _ -> {:error, {:workspace_required, "`agent_browser` requires a local issue workspace."}}
    end
  end

  defp prepare_runtime_dirs(workspace) do
    with :ok <- prepare_runtime_dir(browser_home(workspace)),
         do: prepare_runtime_dir(runtime_dir(workspace))
  end

  defp prepare_runtime_dir(path) do
    with :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:browser_runtime_dir_unavailable, path, reason}}
    end
  end

  defp command(%{"action" => "open", "url" => url}, _workspace) when is_binary(url) do
    with :ok <- validate_local_url(url) do
      {:ok, ["open", url]}
    end
  end

  defp command(%{"action" => "open"}, _workspace) do
    {:error, {:invalid_arguments, "`agent_browser` action=open requires a url."}}
  end

  defp command(%{"action" => "wait_networkidle"}, _workspace), do: {:ok, ["wait", "--load", "networkidle"]}
  defp command(%{"action" => "snapshot_interactive"}, _workspace), do: {:ok, ["snapshot", "-i"]}
  defp command(%{"action" => "get_title"}, _workspace), do: {:ok, ["get", "title"]}
  defp command(%{"action" => "get_url"}, _workspace), do: {:ok, ["get", "url"]}
  defp command(%{"action" => "close"}, _workspace), do: {:ok, ["close"]}

  defp command(%{"action" => "screenshot"}, _workspace), do: {:ok, ["screenshot"]}

  defp command(%{"action" => action}, _workspace) when is_binary(action) do
    {:error, {:unsupported_action, action}}
  end

  defp command(_args, _workspace) do
    {:error, {:invalid_arguments, "`agent_browser` requires an action."}}
  end

  defp validate_local_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        if MapSet.member?(@allowed_hosts, String.downcase(host)) do
          :ok
        else
          {:error, {:unsafe_url, "`agent_browser` only opens localhost/127.0.0.1/[::1] URLs."}}
        end

      _ ->
        {:error, {:unsafe_url, "`agent_browser` only opens http(s) localhost URLs."}}
    end
  end

  defp run(command, workspace) do
    runner = Application.get_env(:symphony_elixir, :agent_browser_runner, &default_runner/3)
    env = browser_env(workspace)

    case runner.(command, workspace, env) do
      {output, 0} ->
        {:ok,
         %{
           action: action_name(command),
           argv: ["agent-browser" | command],
           output: String.trim_trailing(output)
         }}

      {output, status} when is_integer(status) and status >= 0 ->
        {:error, {:agent_browser_failed, status, output}}
    end
  end

  defp default_runner(command, workspace, env) do
    executable = Application.get_env(:symphony_elixir, :agent_browser_executable, "agent-browser")
    System.cmd(executable, command, cd: workspace, env: env, stderr_to_stdout: true)
  end

  defp browser_env(workspace) do
    [
      {"AGENT_BROWSER_HOME", browser_home(workspace)},
      {"XDG_RUNTIME_DIR", runtime_dir(workspace)},
      {"AGENT_BROWSER_IDLE_TIMEOUT_MS", "60000"},
      {"AGENT_BROWSER_CONTENT_BOUNDARIES", "1"}
    ]
  end

  defp browser_home(workspace), do: Path.join(workspace, ".agent-browser")
  defp runtime_dir(workspace), do: Path.join(workspace, ".runtime")
  defp action_name(["wait", "--load", "networkidle"]), do: "wait_networkidle"
  defp action_name(["snapshot", "-i"]), do: "snapshot_interactive"
  defp action_name(["get", "title"]), do: "get_title"
  defp action_name(["get", "url"]), do: "get_url"
  defp action_name([action | _]), do: action
end
