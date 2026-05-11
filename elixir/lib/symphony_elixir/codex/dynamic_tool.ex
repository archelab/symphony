defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Codex.GithubGraphqlTool

  @github_graphql_tool "github_graphql"

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, _opts \\ []) do
    case tool do
      @github_graphql_tool ->
        execute_github_graphql(arguments)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [%{required(String.t()) => term()}, ...]
  def tool_specs do
    %{name: gh_name, description: gh_desc, parameters: gh_params} = GithubGraphqlTool.definition()

    [
      %{
        "name" => gh_name,
        "description" => gh_desc,
        "inputSchema" => gh_params
      }
    ]
  end

  defp execute_github_graphql(arguments) when is_map(arguments) do
    args = Map.new(arguments, fn {k, v} -> {to_string(k), v} end)

    case GithubGraphqlTool.handle(args) do
      {:ok, response} -> graphql_response(response)
      {:error, reason} -> failure_response(github_error_payload(reason))
    end
  end

  defp execute_github_graphql(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" ->
        failure_response(%{
          "error" => %{
            "message" => "`github_graphql` requires a non-empty `query` string."
          }
        })

      query ->
        execute_github_graphql(%{"query" => query})
    end
  end

  defp execute_github_graphql(_other) do
    failure_response(%{
      "error" => %{
        "message" => "`github_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    })
  end

  defp github_error_payload({:mutation_not_allowed, name}) do
    %{
      "error" => %{
        "message" => "`github_graphql` rejected mutation `#{name}`; not on the configured allowlist.",
        "mutation" => name
      }
    }
  end

  defp github_error_payload({:mutation_unparseable, detail}) do
    %{
      "error" => %{
        "message" => "`github_graphql` could not parse the mutation document.",
        "detail" => to_string(detail)
      }
    }
  end

  defp github_error_payload(reason) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
