defmodule Mix.Tasks.Symphony.Prompt.Dump do
  use Mix.Task

  alias SymphonyElixir.PromptDump

  @shortdoc "Dump the publishable Symphony startup payload for an issue"

  @moduledoc """
  Dumps the publishable Symphony startup payload for a GitHub issue or pull
  request.

  The dump includes the rendered `WORKFLOW.md` prompt, runtime envelope,
  dynamic tool schemas, injected environment variable names, cwd, and sandbox
  policy. It excludes hidden platform/system/developer instructions and secret
  values.

  Usage:

      mix symphony.prompt.dump --issue archelab/symphony#210
      mix symphony.prompt.dump --issue archelab/symphony#210 --output initial_prompt.md
  """

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          attempt: :integer,
          dispatched_at: :string,
          help: :boolean,
          issue: :string,
          output: :string,
          thread_id: :string,
          workspace: :string
        ],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      argv != [] ->
        Mix.raise("Unexpected argument(s): #{Enum.join(argv, ", ")}")

      true ->
        dump_payload(opts)
    end
  end

  defp dump_payload(opts) do
    issue_ref = required_opt(opts, :issue)
    fetcher = Application.get_env(:symphony_elixir, :prompt_dump_issue_fetcher, &PromptDump.fetch_issue/1)

    with {:ok, _apps} <- Application.ensure_all_started(:req),
         {:ok, issue} <- fetcher.(issue_ref),
         {:ok, dump} <- PromptDump.dump(issue, dump_opts(opts)) do
      write_dump(dump, opts[:output])
    else
      {:error, reason} -> Mix.raise("Unable to dump Symphony prompt: #{inspect(reason)}")
    end
  end

  defp dump_opts(opts) do
    [
      attempt: opts[:attempt],
      dispatched_at: opts[:dispatched_at],
      thread_id: opts[:thread_id],
      workspace: opts[:workspace]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp write_dump(dump, nil) do
    Mix.shell().info(dump)
  end

  defp write_dump(dump, path) when is_binary(path) do
    File.write!(path, dump)
    Mix.shell().info("Wrote #{path}")
  end
end
