defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"

  # SPEC §11.8.10: the per-session summary header carries Session,
  # Dispatched, and (via the marker) a thread_id. A workflow that opts into
  # session-summary comments MUST reference at least one of these so the
  # agent's rendered prompt actually carries per-session identity. The
  # workpad's `model` and `prior_sessions` vars are intentionally NOT on
  # this list — a workpad-disabled, summary-enabled deployment must still
  # satisfy this validation, and `model` lives only in the workpad context
  # map.
  @session_summary_required_template_vars ~w(thread_id subject_id dispatched_at)

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp parse(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        loaded = %{
          config: front_matter,
          prompt: prompt,
          prompt_template: prompt
        }

        with :ok <- validate_workpad_template(loaded),
             :ok <- validate_session_summary_template(loaded) do
          {:ok, loaded}
        end

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  # SPEC §11.8.9 — when an operator opts into the workpad protocol via
  # `agent.workpad.enabled: true`, the workflow prompt template MUST reference
  # at least one of the five workpad-bridging Liquid variables (see
  # `SymphonyElixir.Workpad.Protocol.prompt_variables/0`). Without this guard
  # the orchestrator would emit the variables and the rendered prompt would
  # carry zero workpad context — the agent would have no idea the workpad is
  # supposed to exist. We fail loud here at config-load time instead of
  # silently producing protocol-less prompts at runtime.
  defp validate_workpad_template(%{config: config, prompt_template: prompt})
       when is_binary(prompt) do
    if workpad_enabled?(config) do
      vars = SymphonyElixir.Workpad.Protocol.prompt_variables()

      if Enum.any?(vars, &template_references_var?(prompt, &1)) do
        :ok
      else
        {:error,
         {:invalid_workflow_config,
          "agent.workpad.enabled: true requires the workflow prompt template to reference at least one of: " <>
            Enum.join(vars, ", ") <> " (SPEC §11.8.9)"}}
      end
    else
      :ok
    end
  end

  # SPEC §11.8.9 (PR4 amendment): workpad defaults to enabled. The validation
  # fires whenever the operator has NOT explicitly opted out via
  # `agent.workpad.enabled: false`, mirroring `Config.Schema.Agent.Workpad`'s
  # `default: true`. Pre-PR3 templates without a workpad block (and without a
  # workpad section in the prompt) hit this branch and fail loud at boot —
  # exactly the migration signal documented in the SPEC's "Migrating to
  # default-on" note.
  defp workpad_enabled?(%{"agent" => %{"workpad" => %{"enabled" => false}}}), do: false
  defp workpad_enabled?(_), do: true

  # SPEC §11.8.10: a workflow whose front matter opts INTO session-summary
  # comments (`agent.session_summary.enabled: true`) MUST have
  # a prompt template that references at least one of `thread_id`,
  # `subject_id`, or `dispatched_at`. Without those bindings the agent's
  # rendered prompt would carry no per-session identity and the audit
  # comment's marker would be `<!-- symphony-session-summary::v1 -->`. Same
  # fail-loud philosophy as `validate_workpad_template/1`.
  defp validate_session_summary_template(%{config: config, prompt_template: prompt})
       when is_binary(prompt) do
    if session_summary_enabled?(config) do
      vars = @session_summary_required_template_vars

      if Enum.any?(vars, &template_references_var?(prompt, &1)) do
        :ok
      else
        {:error,
         {:invalid_workflow_config,
          "agent.session_summary.enabled: true requires the workflow prompt template to reference at least one of: " <>
            Enum.join(vars, ", ") <> " (SPEC §11.8.10)"}}
      end
    else
      :ok
    end
  end

  defp session_summary_enabled?(%{"agent" => %{"session_summary" => %{"enabled" => false}}}),
    do: false

  defp session_summary_enabled?(%{"agent" => %{"session_summary" => %{"enabled" => true}}}),
    do: true

  defp session_summary_enabled?(_), do: false

  # Match Liquid output tags (`{{ … }}`) and control-flow tags (`{% … %}`).
  # `\b` plus `Regex.escape/1` keep the match anchored to the literal variable
  # token — e.g. an unrelated `{{ model_name }}` won't satisfy the `model`
  # requirement. False positives are tolerated (operator referencing `model`
  # for non-workpad purposes is rare and benign); false negatives are not.
  defp template_references_var?(prompt, var) when is_binary(prompt) and is_binary(var) do
    escaped = Regex.escape(var)

    Regex.match?(~r/\{\{[^}]*\b#{escaped}\b/, prompt) or
      Regex.match?(~r/\{%[^%]*\b#{escaped}\b/, prompt)
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_store do
    _ =
      if Process.whereis(WorkflowStore) do
        WorkflowStore.force_reload()
      end

    :ok
  end
end
