defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @default_preflight_checks if Code.ensure_loaded?(Mix), do: Mix.env() != :test, else: true

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    :ok = maybe_run_preflight_checks()

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  @doc false
  @spec maybe_run_preflight_checks() :: :ok
  def maybe_run_preflight_checks do
    if preflight_checks_enabled?() do
      run_preflight_checks!()
    else
      :ok
    end
  end

  @doc false
  @spec run_preflight_checks!() :: :ok
  def run_preflight_checks! do
    SymphonyElixir.PreflightChecks.run!()
  end

  @doc false
  @spec preflight_checks_enabled?() :: boolean()
  def preflight_checks_enabled? do
    Application.get_env(:symphony_elixir, :preflight_checks, @default_preflight_checks)
  end
end
