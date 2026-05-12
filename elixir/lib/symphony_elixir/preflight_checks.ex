defmodule SymphonyElixir.PreflightChecks do
  @moduledoc """
  Startup checks that catch operator-actionable configuration failures before
  the orchestrator starts dispatching agents.
  """

  require Logger

  alias SymphonyElixir.{Codex.GithubGraphqlTool, Config, Github.Client}

  @viewer_query "query SymphonyPreflightViewer { viewer { login } }"
  @publishing_mutations ~w(createRef createPullRequest)

  @type error :: {:tracker_permission_denied, term()} | {atom(), term()}

  @spec run() :: :ok | {:error, error()}
  def run do
    Config.settings!()
    |> run()
  end

  @spec run(Config.Schema.t()) :: :ok | {:error, error()}
  def run(settings) do
    with :ok <- check_github_auth(settings) do
      warn_missing_publishing_allowlist(settings)
      warn_unwritable_sandbox(settings)
      warn_github_network_disabled(settings)
      :ok
    end
  end

  @spec run!() :: :ok
  def run! do
    Config.settings!()
    |> run!()
  end

  @spec run!(Config.Schema.t()) :: :ok
  def run!(settings) do
    case run(settings) do
      :ok ->
        :ok

      {:error, {:tracker_permission_denied, ctx}} ->
        Logger.error(
          "GitHub tracker preflight failed: :tracker_permission_denied. GITHUB_TOKEN scopes hint: need `project` + `repo`.",
          reason: :tracker_permission_denied,
          context: inspect(ctx)
        )

        raise "GitHub tracker preflight failed: :tracker_permission_denied. GITHUB_TOKEN scopes hint: need `project` + `repo`."

      {:error, {reason, ctx}} ->
        Logger.error("GitHub tracker preflight failed: #{inspect(reason)}", reason: reason, context: inspect(ctx))
        raise "GitHub tracker preflight failed: #{inspect(reason)}"
    end
  end

  defp check_github_auth(%{tracker: %{kind: "github"} = tracker}) do
    graphql = Application.get_env(:symphony_elixir, :github_client, &Client.graphql/3)

    case graphql.(@viewer_query, %{}, endpoint: tracker.endpoint, token: tracker.api_token) do
      {:ok, %{"data" => %{"viewer" => %{"login" => login}}}} when is_binary(login) and login != "" ->
        :ok

      {:ok, payload} ->
        {:error, {:github_unknown_payload, payload}}

      {:error, {:tracker_permission_denied, ctx}} ->
        {:error, {:tracker_permission_denied, ctx}}

      {:error, {reason, ctx}} ->
        {:error, {reason, ctx}}
    end
  end

  defp check_github_auth(_settings), do: :ok

  defp warn_missing_publishing_allowlist(%{agent: %{workpad: %{enabled: true}}}) do
    allowlist = GithubGraphqlTool.allowed_mutations()
    missing = Enum.reject(@publishing_mutations, &(&1 in allowlist))

    if missing != [] do
      Logger.warning(
        "Agent workpad is enabled but #{Enum.join(missing, ", ")} are not allowlisted; the agent will fail to publish branches or pull requests.",
        reason: :github_graphql_publishing_mutation_missing
      )
    end
  end

  defp warn_missing_publishing_allowlist(_settings), do: :ok

  defp warn_unwritable_sandbox(%{
         codex: %{approval_policy: "never", thread_sandbox: sandbox}
       })
       when sandbox != "workspace-write" do
    Logger.warning(
      "Codex thread sandbox is #{sandbox} with approval_policy=never; the agent will be unable to write meaningful changes.",
      reason: :codex_sandbox_unwritable
    )
  end

  defp warn_unwritable_sandbox(_settings), do: :ok

  defp warn_github_network_disabled(%{
         tracker: %{kind: "github"},
         codex: %{turn_sandbox_policy: %{} = policy}
       }) do
    if Map.get(policy, "networkAccess") != true do
      Logger.warning(
        "GitHub tracker is enabled but codex.turn_sandbox_policy.networkAccess is not true; agent gh commands will fail.",
        reason: :codex_turn_network_disabled
      )
    end
  end

  defp warn_github_network_disabled(%{tracker: %{kind: "github"}, codex: %{turn_sandbox_policy: nil}}) do
    Logger.warning(
      "GitHub tracker is enabled but the default turn sandbox has networkAccess=false; agent gh commands will fail unless networkAccess is enabled.",
      reason: :codex_turn_network_disabled
    )
  end

  defp warn_github_network_disabled(_settings), do: :ok
end
