defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from a normalized tracker Issue.

  Spec §12.1–12.3: prompt rendering uses Solid (Liquid) with strict variable
  and filter checking. The render context exposes:

  - `issue` — the normalized `SymphonyElixir.Github.Issue` shape, serialized
    via `Map.from_struct/1`.
  - `attempt` — current dispatch attempt number for continuation/Rework runs.
  - `last_run_completed_at` — ISO8601 timestamp of the prior run's completion,
    sourced from `Orchestrator.State.completed[issue_id][:completed_at]`.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(struct(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(build_context(Keyword.put(opts, :issue, issue)), @render_opts)
    |> IO.iodata_to_binary()
  end

  @doc """
  Render a raw Solid (Liquid) template against an explicit context.

  Returns `{:ok, rendered}` on success, `{:error, reason}` when the template
  references undefined variables/filters (spec §12.2 strict mode) or fails to
  parse.
  """
  @spec render(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render(template, opts) when is_binary(template) and is_list(opts) do
    with {:ok, parsed} <- parse_template(template),
         context = build_context(opts),
         {:ok, iodata} <- safe_render(parsed, context) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  defp build_context(opts) do
    base = %{
      "attempt" => Keyword.get(opts, :attempt),
      "last_run_completed_at" => Keyword.get(opts, :last_run_completed_at)
    }

    case Keyword.fetch(opts, :issue) do
      {:ok, issue} -> Map.put(base, "issue", issue |> Map.from_struct() |> to_solid_map())
      :error -> base
    end
  end

  defp parse_template(prompt) do
    case Solid.parse(prompt) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:template_parse_error, reason}}
    end
  end

  defp safe_render(parsed, context) do
    # Solid 1.2.x returns `{:error, errors, partial}` when strict mode is on
    # and a variable/filter is undefined; it only emits `{:ok, iodata, []}`
    # on a fully successful render.
    case Solid.render(parsed, context, @render_opts) do
      {:ok, iodata, []} -> {:ok, iodata}
      {:error, reason, _partial} -> {:error, reason}
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
