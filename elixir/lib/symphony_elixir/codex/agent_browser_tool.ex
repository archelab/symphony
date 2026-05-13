defmodule SymphonyElixir.Codex.AgentBrowserTool do
  @moduledoc """
  Constrained host-side `agent-browser` dynamic tool.

  The tool lets sandboxed Codex agents request browser checks without launching
  Chrome from inside the Codex shell sandbox. The orchestrator executes a small
  allowlisted set of `agent-browser` commands with browser state rooted in the
  issue workspace.
  """

  @allowed_hosts MapSet.new(["127.0.0.1", "::1", "localhost"])
  @actions ~w(
    open
    wait_networkidle
    wait_text
    wait_selector
    wait_ms
    snapshot_interactive
    screenshot
    get_title
    get_url
    click
    fill
    type
    press
    select
    console
    errors
    close
  )

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
          },
          "selector" => %{
            "type" => "string",
            "description" => "Element selector or @ref for click, fill, type, select, wait_selector, and optional screenshot scoping."
          },
          "text" => %{
            "type" => "string",
            "description" => "Text for fill, type, or wait_text."
          },
          "key" => %{
            "type" => "string",
            "description" => "Key or key combination for press, such as Enter, Tab, Escape, or Control+a."
          },
          "value" => %{
            "type" => "string",
            "description" => "Single select dropdown value."
          },
          "values" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "One or more select dropdown values."
          },
          "ms" => %{
            "type" => "integer",
            "minimum" => 0,
            "maximum" => 60_000,
            "description" => "Milliseconds for wait_ms."
          },
          "path" => %{
            "type" => "string",
            "description" => "Optional relative workspace path for screenshot output."
          },
          "full" => %{
            "type" => "boolean",
            "description" => "Capture a full-page screenshot."
          },
          "annotate" => %{
            "type" => "boolean",
            "description" => "Annotate screenshot with interactive element labels."
          },
          "new_tab" => %{
            "type" => "boolean",
            "description" => "Open clicked link in a new tab when action=click."
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

  defp command(%{"action" => "wait_text", "text" => text}, _workspace) when is_binary(text) and text != "" do
    {:ok, ["wait", "--text", text]}
  end

  defp command(%{"action" => "wait_text"}, _workspace) do
    {:error, {:invalid_arguments, "`agent_browser` action=wait_text requires text."}}
  end

  defp command(%{"action" => "wait_selector", "selector" => selector}, _workspace)
       when is_binary(selector) and selector != "" do
    {:ok, ["wait", selector]}
  end

  defp command(%{"action" => "wait_selector"}, _workspace) do
    {:error, {:invalid_arguments, "`agent_browser` action=wait_selector requires selector."}}
  end

  defp command(%{"action" => "wait_ms", "ms" => ms}, _workspace) when is_integer(ms) and ms in 0..60_000 do
    {:ok, ["wait", Integer.to_string(ms)]}
  end

  defp command(%{"action" => "wait_ms"}, _workspace) do
    {:error, {:invalid_arguments, "`agent_browser` action=wait_ms requires ms between 0 and 60000."}}
  end

  defp command(%{"action" => "snapshot_interactive"}, _workspace), do: {:ok, ["snapshot", "-i"]}
  defp command(%{"action" => "get_title"}, _workspace), do: {:ok, ["get", "title"]}
  defp command(%{"action" => "get_url"}, _workspace), do: {:ok, ["get", "url"]}
  defp command(%{"action" => "close"}, _workspace), do: {:ok, ["close"]}
  defp command(%{"action" => "console"}, _workspace), do: {:ok, ["console"]}
  defp command(%{"action" => "errors"}, _workspace), do: {:ok, ["errors"]}

  defp command(%{"action" => "click", "selector" => selector} = args, _workspace)
       when is_binary(selector) and selector != "" do
    command = ["click", selector]

    if Map.get(args, "new_tab") == true do
      {:ok, command ++ ["--new-tab"]}
    else
      {:ok, command}
    end
  end

  defp command(%{"action" => "click"}, _workspace) do
    {:error, {:invalid_arguments, "`agent_browser` action=click requires selector."}}
  end

  defp command(%{"action" => action, "selector" => selector, "text" => text}, _workspace)
       when action in ["fill", "type"] and is_binary(selector) and selector != "" and is_binary(text) do
    {:ok, [action, selector, text]}
  end

  defp command(%{"action" => action}, _workspace) when action in ["fill", "type"] do
    {:error, {:invalid_arguments, "`agent_browser` action=#{action} requires selector and text."}}
  end

  defp command(%{"action" => "press", "key" => key}, _workspace) when is_binary(key) and key != "" do
    if String.match?(key, ~r/^[A-Za-z0-9+_-]+$/) do
      {:ok, ["press", key]}
    else
      {:error, {:invalid_arguments, "`agent_browser` action=press received an invalid key."}}
    end
  end

  defp command(%{"action" => "press"}, _workspace) do
    {:error, {:invalid_arguments, "`agent_browser` action=press requires key."}}
  end

  defp command(%{"action" => "select", "selector" => selector} = args, _workspace)
       when is_binary(selector) and selector != "" do
    with {:ok, values} <- select_values(args) do
      {:ok, ["select", selector | values]}
    end
  end

  defp command(%{"action" => "select"}, _workspace) do
    {:error, {:invalid_arguments, "`agent_browser` action=select requires selector and value or values."}}
  end

  defp command(%{"action" => "screenshot"} = args, workspace) do
    with {:ok, path_args} <- screenshot_path_args(args, workspace) do
      {:ok, ["screenshot"] ++ screenshot_flags(args) ++ screenshot_selector_args(args) ++ path_args}
    end
  end

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

  defp select_values(%{"value" => value}) when is_binary(value) and value != "", do: {:ok, [value]}

  defp select_values(%{"values" => values}) when is_list(values) do
    if values != [] and Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, values}
    else
      {:error, {:invalid_arguments, "`agent_browser` action=select requires non-empty string values."}}
    end
  end

  defp select_values(_args) do
    {:error, {:invalid_arguments, "`agent_browser` action=select requires value or values."}}
  end

  defp screenshot_flags(args) do
    []
    |> maybe_append_flag(Map.get(args, "full") == true, "--full")
    |> maybe_append_flag(Map.get(args, "annotate") == true, "--annotate")
  end

  defp maybe_append_flag(command, true, flag), do: command ++ [flag]
  defp maybe_append_flag(command, false, _flag), do: command

  defp screenshot_selector_args(%{"selector" => selector}) when is_binary(selector) and selector != "", do: [selector]
  defp screenshot_selector_args(_args), do: []

  defp screenshot_path_args(%{"path" => path}, workspace) when is_binary(path) and path != "" do
    if safe_relative_path?(path, workspace) do
      {:ok, [path]}
    else
      {:error, {:invalid_arguments, "`agent_browser` screenshot path must stay inside the issue workspace."}}
    end
  end

  defp screenshot_path_args(%{"path" => _path}, _workspace) do
    {:error, {:invalid_arguments, "`agent_browser` screenshot path must be a non-empty string."}}
  end

  defp screenshot_path_args(_args, _workspace), do: {:ok, []}

  defp safe_relative_path?(path, workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(path, workspace)
    expanded_path == expanded_workspace or String.starts_with?(expanded_path, expanded_workspace <> "/")
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
  defp action_name(["wait", "--text", _text]), do: "wait_text"
  defp action_name(["wait", ms]) when is_binary(ms), do: if(String.match?(ms, ~r/^\d+$/), do: "wait_ms", else: "wait_selector")
  defp action_name(["snapshot", "-i"]), do: "snapshot_interactive"
  defp action_name(["get", "title"]), do: "get_title"
  defp action_name(["get", "url"]), do: "get_url"
  defp action_name([action | _]), do: action
end
