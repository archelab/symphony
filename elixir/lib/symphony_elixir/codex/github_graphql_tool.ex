defmodule SymphonyElixir.Codex.GithubGraphqlTool do
  @moduledoc """
  Codex dynamic tool registration for GitHub GraphQL access.
  Spec §11.5 (agent-driven writes) and §18.2 (github_graphql extension).
  """

  alias SymphonyElixir.{Config, Github.Client}

  @default_mutation_allowlist ~w(
    addComment
    updateProjectV2ItemFieldValue
    addLabelsToLabelable
    removeLabelsFromLabelable
    requestReviews
    addPullRequestReview
    resolveReviewThread
  )

  @spec definition() :: %{name: String.t(), description: String.t(), parameters: map()}
  def definition do
    %{
      name: "github_graphql",
      description:
        "Execute a GitHub GraphQL query or mutation against the Symphony tracker. " <>
          "Mutations are restricted by allowlist; queries are unrestricted.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "GraphQL query or mutation source"},
          "variables" => %{"type" => "object", "description" => "Variables map", "default" => %{}}
        },
        "required" => ["query"]
      }
    }
  end

  @spec handle(map()) :: {:ok, map()} | {:error, term()}
  def handle(%{"query" => query} = args) do
    variables = Map.get(args, "variables", %{}) || %{}

    with {:ok, _kind} <- check_mutation_allowed(query) do
      tracker = Config.settings!().tracker
      fun = Application.get_env(:symphony_elixir, :github_client, &Client.graphql/3)

      fun.(query, variables, endpoint: tracker.endpoint, token: tracker.api_token)
    end
  end

  # Spec §18.2.1: malformed mutations MUST return :mutation_unparseable.
  # Multi-mutation documents must gate ALL top-level fields, not just the first.
  defp check_mutation_allowed(query) do
    trimmed = query |> String.trim_leading() |> strip_leading_comments()

    cond do
      String.starts_with?(trimmed, "{") -> {:ok, :query}
      starts_with_keyword?(trimmed, "query") -> {:ok, :query}
      starts_with_keyword?(trimmed, "subscription") -> {:ok, :query}
      starts_with_keyword?(trimmed, "mutation") -> gate_mutation(query)
      true -> {:error, {:mutation_unparseable, trimmed |> String.slice(0, 80)}}
    end
  end

  defp starts_with_keyword?(text, kw) do
    case text do
      <<^kw::binary, rest::binary>> ->
        rest == "" or String.starts_with?(rest, [" ", "\t", "\n", "(", "{"])

      _ ->
        false
    end
  end

  defp strip_leading_comments(text) do
    case Regex.replace(~r/\A(\s*#[^\n]*\n)+/, text, "") do
      ^text -> text
      stripped -> String.trim_leading(stripped)
    end
  end

  defp gate_mutation(query) do
    # Extract every top-level field selection inside the outer `mutation { ... }`.
    case Regex.run(~r/mutation\b[^{]*\{(.+)\}\s*\z/s, query) do
      [_, body] ->
        names = extract_top_level_fields(body)

        cond do
          names == [] ->
            {:error, {:mutation_unparseable, "no fields in mutation body"}}

          Enum.all?(names, &(&1 in mutation_allowlist())) ->
            {:ok, :mutation}

          true ->
            bad = Enum.find(names, &(&1 not in mutation_allowlist()))
            {:error, {:mutation_not_allowed, bad}}
        end

      _ ->
        {:error, {:mutation_unparseable, "could not isolate mutation body"}}
    end
  end

  # Walk the mutation body, returning every top-level field name (depth 0).
  # Brace-depth tracking handles nested selection sets without a real parser.
  defp extract_top_level_fields(body) do
    body
    |> String.to_charlist()
    |> walk_fields(0, [], [])
    |> Enum.reverse()
  end

  defp walk_fields([], _depth, _buf, acc), do: acc

  defp walk_fields([?{ | rest], depth, buf, acc),
    do: walk_fields(rest, depth + 1, [], maybe_emit(buf, depth, acc))

  defp walk_fields([?} | rest], depth, _buf, acc),
    do: walk_fields(rest, depth - 1, [], acc)

  defp walk_fields([?( | rest], depth, buf, acc),
    do: walk_fields(skip_parens(rest, 1), depth, buf, acc)

  defp walk_fields([c | rest], 0, buf, acc) when c in [?\s, ?\t, ?\n, ?,],
    do: walk_fields(rest, 0, [], maybe_emit(buf, 0, acc))

  defp walk_fields([_c | rest], depth, buf, acc) when depth > 0,
    do: walk_fields(rest, depth, buf, acc)

  defp walk_fields([c | rest], 0, buf, acc),
    do: walk_fields(rest, 0, [c | buf], acc)

  defp skip_parens([], _), do: []
  defp skip_parens(rest, 0), do: rest
  defp skip_parens([?( | rest], n), do: skip_parens(rest, n + 1)
  defp skip_parens([?) | rest], n), do: skip_parens(rest, n - 1)
  defp skip_parens([_ | rest], n), do: skip_parens(rest, n)

  # `maybe_emit/3` is only invoked from depth-0 walk_fields/4 clauses; depths
  # >= 1 are skipped by the `depth > 0` clause so the third positional
  # argument is always 0 here. Kept positional for symmetry with the call
  # sites.
  defp maybe_emit([], _depth, acc), do: acc

  defp maybe_emit(buf, 0, acc) do
    name = buf |> Enum.reverse() |> List.to_string() |> String.trim()
    if name == "" or String.starts_with?(name, "#"), do: acc, else: [name | acc]
  end

  defp mutation_allowlist do
    Application.get_env(
      :symphony_elixir,
      :github_graphql_mutation_allowlist,
      @default_mutation_allowlist
    )
  end
end
