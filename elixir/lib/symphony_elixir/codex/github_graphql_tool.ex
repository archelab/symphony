defmodule SymphonyElixir.Codex.GithubGraphqlTool do
  @moduledoc """
  Codex dynamic tool registration for GitHub GraphQL access.
  Spec §11.5 (agent-driven writes), §11.8.4 (workpad append-only edits via
  `updateIssueComment`), and §18.2 (github_graphql extension).
  """

  alias SymphonyElixir.{Config, Github.Client}

  @typedoc """
  Errors emitted by `handle/1` that originate in this module (i.e. before the
  GraphQL request is dispatched). See `Codex.DynamicTool.github_error_payload/1`
  for the user-visible projection.
  """
  @type mutation_error ::
          {:mutation_unparseable, String.t()}
          | {:mutation_not_allowed, String.t()}

  @typedoc """
  Alias for `SymphonyElixir.Github.Client.graphql_error/0`. Errors emitted by
  the underlying transport flow through `handle/1` unchanged.
  """
  @type graphql_error :: SymphonyElixir.Github.Client.graphql_error()

  # SPEC §11.8.4 + §17.8: `updateIssueComment` is intentionally NOT in the
  # default allowlist. `mutation_allowlist/0` appends it only when
  # `agent.workpad.enabled: true` so workflows that opt into §11.8 get the
  # capability while workflows that do not are protected from a hallucinating
  # agent rewriting unrelated issue comments.
  @default_mutation_allowlist ~w(
    addComment
    updateProjectV2ItemFieldValue
    addLabelsToLabelable
    removeLabelsFromLabelable
    createRef
    createPullRequest
    requestReviews
    addPullRequestReview
    addPullRequestReviewComment
    resolveReviewThread
  )

  # Mutations conditionally added when the Agent Workpad Protocol is enabled.
  # Centralized here so future workpad-protocol additions land in one place.
  @workpad_mutation_allowlist ~w(updateIssueComment)

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

  @spec handle(map()) :: {:ok, map()} | {:error, mutation_error() | graphql_error()}
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
      starts_with_keyword?(trimmed, "mutation") -> gate_mutation(trimmed)
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
    # Isolate the outer `mutation { ... }` body using a depth-tracking scan so
    # `}` characters inside argument string literals don't truncate it.
    case isolate_mutation_body(query) do
      {:ok, body} ->
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

      :error ->
        {:error, {:mutation_unparseable, "could not isolate mutation body"}}
    end
  end

  # Locate the outer mutation body: the substring between the first `{`
  # after the `mutation` keyword (skipping operation name + variable defs)
  # and its matching `}`. String-literal aware so quoted `{`/`}` do not
  # affect depth.
  defp isolate_mutation_body(query) do
    charlist = String.to_charlist(query)

    with {:ok, rest_after_mutation} <- skip_mutation_keyword(charlist),
         {:ok, body_chars} <- read_outer_body(rest_after_mutation) do
      {:ok, List.to_string(body_chars)}
    end
  end

  defp skip_mutation_keyword(~c"mutation" ++ rest), do: scan_to_outer_open_brace(rest)
  # `gate_mutation/1` is only called from `check_mutation_allowed/1` after
  # the query has been left-trimmed AND `starts_with_keyword?(trimmed,
  # "mutation")` returned true, so the charlist is guaranteed to start with
  # `mutation`. Defensive branch removed; an upstream contract bug would
  # FunctionClauseError fast, not silently mis-parse.

  # Consume optional operation name + parameter list + directives until the
  # first top-level `{`. Honors string literals so braces inside default
  # values do not confuse us.
  defp scan_to_outer_open_brace(chars), do: scan_to_outer_open_brace(chars, false)

  defp scan_to_outer_open_brace([], _in_string), do: :error
  defp scan_to_outer_open_brace([?\\, ?" | rest], true), do: scan_to_outer_open_brace(rest, true)
  defp scan_to_outer_open_brace([?" | rest], false), do: scan_to_outer_open_brace(rest, true)
  defp scan_to_outer_open_brace([?" | rest], true), do: scan_to_outer_open_brace(rest, false)
  defp scan_to_outer_open_brace([_c | rest], true), do: scan_to_outer_open_brace(rest, true)
  defp scan_to_outer_open_brace([?{ | rest], false), do: {:ok, rest}
  defp scan_to_outer_open_brace([_c | rest], false), do: scan_to_outer_open_brace(rest, false)

  # Read until the matching outer `}`; depth tracking inside braces, parens,
  # and string-literal state.
  defp read_outer_body(chars), do: read_outer_body(chars, 1, false, [])

  defp read_outer_body([], _depth, _in_string, _acc), do: :error

  defp read_outer_body([?\\, ?" | rest], depth, true, acc),
    do: read_outer_body(rest, depth, true, [?", ?\\ | acc])

  defp read_outer_body([?" | rest], depth, false, acc),
    do: read_outer_body(rest, depth, true, [?" | acc])

  defp read_outer_body([?" | rest], depth, true, acc),
    do: read_outer_body(rest, depth, false, [?" | acc])

  defp read_outer_body([c | rest], depth, true, acc),
    do: read_outer_body(rest, depth, true, [c | acc])

  defp read_outer_body([?{ | rest], depth, false, acc),
    do: read_outer_body(rest, depth + 1, false, [?{ | acc])

  defp read_outer_body([?} | _rest], 1, false, acc),
    do: {:ok, Enum.reverse(acc)}

  defp read_outer_body([?} | rest], depth, false, acc) when depth > 1,
    do: read_outer_body(rest, depth - 1, false, [?} | acc])

  defp read_outer_body([c | rest], depth, false, acc),
    do: read_outer_body(rest, depth, false, [c | acc])

  # Walk the mutation body, returning every top-level field name (depth 0).
  # Brace-depth tracking handles nested selection sets without a real parser.
  # `read_outer_body/4` already isolated the body with string-literal-aware
  # depth tracking, so string `}` inside arguments cannot reach this walker
  # at the outer level. Inside selection sets (depth > 0) GraphQL grammar
  # disallows string literals, so we don't need string state here either —
  # any quoted argument lives inside `(...)`, which `skip_parens/3` consumes
  # wholesale. Top-level `@directive(...)` tokens are skipped so they are
  # not gated as mutation fields.
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
    do: walk_fields(skip_parens(rest, 1, false), depth, buf, acc)

  defp walk_fields([c | rest], 0, buf, acc) when c in [?\s, ?\t, ?\n, ?,],
    do: walk_fields(rest, 0, [], maybe_emit(buf, 0, acc))

  defp walk_fields([_c | rest], depth, buf, acc) when depth > 0,
    do: walk_fields(rest, depth, buf, acc)

  defp walk_fields([c | rest], 0, buf, acc),
    do: walk_fields(rest, 0, [c | buf], acc)

  # skip_parens consumes through the argument list `(...)` opened at the
  # caller's `(` character. GraphQL grammar disallows nested function calls,
  # so the only way a `(` reappears at non-string state is via the caller —
  # accordingly there is no separate `?(` increment clause here. Quoted
  # parens inside argument strings (with escaped-quote support) are absorbed
  # by the string state so they do not unbalance the depth counter.
  defp skip_parens([], _, _in_string), do: []
  defp skip_parens(rest, 0, _in_string), do: rest

  defp skip_parens([?\\, ?" | rest], n, true), do: skip_parens(rest, n, true)
  defp skip_parens([?" | rest], n, false), do: skip_parens(rest, n, true)
  defp skip_parens([?" | rest], n, true), do: skip_parens(rest, n, false)
  defp skip_parens([_c | rest], n, true), do: skip_parens(rest, n, true)

  defp skip_parens([?) | rest], n, false), do: skip_parens(rest, n - 1, false)
  defp skip_parens([_ | rest], n, false), do: skip_parens(rest, n, false)

  # `maybe_emit/3` is only invoked from depth-0 walk_fields/5 clauses; depths
  # >= 1 are skipped by the `depth > 0` clause so the third positional
  # argument is always 0 here. Kept positional for symmetry with the call
  # sites. Top-level directives (`@foo(...)`) are skipped so they do not
  # appear in the gated field list.
  defp maybe_emit([], _depth, acc), do: acc

  defp maybe_emit(buf, 0, acc) do
    name = buf |> Enum.reverse() |> List.to_string() |> String.trim()

    cond do
      String.starts_with?(name, "#") -> acc
      String.starts_with?(name, "@") -> acc
      true -> [name | acc]
    end
  end

  defp mutation_allowlist do
    base =
      Application.get_env(
        :symphony_elixir,
        :github_graphql_mutation_allowlist,
        @default_mutation_allowlist
      )

    Enum.uniq(base ++ workpad_mutation_extras())
  end

  # SPEC §11.8.4 / §17.8: emit the workpad-gated mutations only when the
  # workpad is enabled in current effective config. Falls back to `[]` if the
  # workpad config block is absent (older workflows pre-§11.8.9).
  defp workpad_mutation_extras do
    case Config.settings!() do
      %{agent: %{workpad: %{enabled: true}}} -> @workpad_mutation_allowlist
      _ -> []
    end
  end
end
