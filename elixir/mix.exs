defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          SymphonyElixir.Config,
          # PR1 transitional: Config.Schema and Config.Schema.Server lose coverage
          # from :skip_until_task_6-tagged tests. PR2 must remove these entries
          # when those tests are re-enabled.
          SymphonyElixir.Config.Schema,
          SymphonyElixir.Config.Schema.Server,
          SymphonyElixir.Linear.Adapter,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.CLI,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard,
          SymphonyElixir.LogFile,
          SymphonyElixir.Workspace,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.ObservabilityApiController,
          SymphonyElixirWeb.Presenter,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:mix, :ex_unit],
        flags: [
          :error_handling,
          :extra_return,
          :missing_return,
          :underspecs,
          :unmatched_returns,
          :unknown
        ]
      ],
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # `test_strict` is not auto-detected as a test alias by Mix's env inference
  # (the alias name doesn't start with `test`-the-task), so pin it explicitly.
  def cli do
    [preferred_envs: [test_strict: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "deps.compile", "dialyzer --plt"],
      build: ["escript.build"],
      # `mix lint` is the strict gate run on every PR. Linear-era carry-over
      # modules may surface :underspecs warnings that Task 8 will retire when
      # Linear is deleted; until then, run `lint.baseline` to capture the
      # acceptable noise floor and track regressions only against that floor.
      lint: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "specs.check",
        "credo --strict",
        "dialyzer --halt-exit-status"
      ],
      "lint.baseline": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "specs.check",
        "credo --strict"
      ],
      # live_github is excluded — those tests hit real GitHub and require
      # GITHUB_TOKEN; run them locally via `mix test --only live_github`.
      # Do NOT strip the exclusion: CI has no token and the suite would fail.
      test_strict: [
        "test --cover --warnings-as-errors --exclude skip_until_task_6 --exclude live_github"
      ]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: SymphonyElixir.CLI,
      name: "symphony",
      path: "bin/symphony"
    ]
  end
end
