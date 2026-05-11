defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  Low-level GitHub GraphQL client. Spec §11.2.

  Public surface:
    graphql(query, variables, opts) :: {:ok, map} | {:error, {category, payload}}

  Recognized error categories (spec §11.4):
    :github_api_request, :github_api_status, :github_rate_limited,
    :github_graphql_errors, :github_unknown_payload, :tracker_permission_denied
  """

  @default_timeout_ms 30_000
  @user_agent "symphony-elixir/0.1"

  @type opts :: [
          endpoint: String.t(),
          token: String.t(),
          timeout_ms: pos_integer()
        ]

  @typedoc """
  Categorized error union emitted by `graphql/3`. Spec §11.4.

  Each variant pairs an atom category with a context value:

    * `:github_api_request` — Req transport error (timeout, dns, conn refused).
      Context is the raw `Req` reason term.
    * `:github_api_status` — non-2xx HTTP that didn't map to one of the
      categorized statuses below. Context is `%{http: integer(), body: binary()}`.
    * `:github_rate_limited` — HTTP 429 or HTTP 403 with `retry-after`.
      Context is `%{retry_after_seconds: pos_integer() | nil}`.
    * `:github_graphql_errors` — HTTP 200 with a non-empty `errors` array and no
      forbidden classification. Context is the raw errors list.
    * `:github_unknown_payload` — HTTP 200 with neither `data` nor `errors`.
      Context is a human-readable binary.
    * `:tracker_permission_denied` — HTTP 401, HTTP 403 without `retry-after`,
      or a `FORBIDDEN`/`INSUFFICIENT_SCOPES` GraphQL error. Context is
      `%{http: integer()}` or the raw errors list.
  """
  @type graphql_error ::
          {:github_api_request, term()}
          | {:github_api_status, %{http: integer(), body: binary() | term()}}
          | {:github_rate_limited, %{retry_after_seconds: pos_integer() | nil}}
          | {:github_graphql_errors, [map()]}
          | {:github_unknown_payload, binary()}
          | {:tracker_permission_denied, %{http: integer()} | [map()]}

  @spec graphql(String.t(), map(), opts()) ::
          {:ok, map()} | {:error, graphql_error()}
  def graphql(query, variables, opts) when is_binary(query) and is_map(variables) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    token = Keyword.fetch!(opts, :token)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    body = Jason.encode!(%{"query" => query, "variables" => variables})

    headers = [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/json"},
      {"x-github-next-global-id", "1"},
      {"user-agent", @user_agent}
    ]

    request =
      Req.new(
        url: endpoint,
        method: :post,
        headers: headers,
        body: body,
        receive_timeout: timeout,
        retry: false
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        body |> decode_body() |> handle_200()

      {:ok, %Req.Response{status: 401}} ->
        {:error, {:tracker_permission_denied, %{http: 401}}}

      {:ok, %Req.Response{status: 403, headers: headers}} ->
        handle_403(headers)

      {:ok, %Req.Response{status: 429, headers: headers}} ->
        rate_limited(headers)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_api_status, %{http: status, body: truncate(body)}}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_body(body), do: body

  defp handle_200(%{"errors" => [_ | _] = errors}) do
    if Enum.any?(errors, &forbidden?/1) do
      {:error, {:tracker_permission_denied, errors}}
    else
      {:error, {:github_graphql_errors, errors}}
    end
  end

  defp handle_200(%{"data" => _} = body), do: {:ok, body}
  defp handle_200(_other), do: {:error, {:github_unknown_payload, "missing data and errors"}}

  defp forbidden?(%{"type" => type}) when type in ["FORBIDDEN", "INSUFFICIENT_SCOPES"], do: true
  defp forbidden?(_), do: false

  defp handle_403(headers) do
    case fetch_header(headers, "retry-after") do
      nil -> {:error, {:tracker_permission_denied, %{http: 403}}}
      value -> {:error, {:github_rate_limited, %{retry_after_seconds: parse_int(value)}}}
    end
  end

  defp rate_limited(headers) do
    seconds =
      headers
      |> fetch_header("retry-after")
      |> parse_int()

    {:error, {:github_rate_limited, %{retry_after_seconds: seconds || 60}}}
  end

  # Req >= 0.4 normalizes response headers to a map of lowercased string keys
  # to lists of values. The public surface only ever sees this shape.
  defp fetch_header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 1_000)
  defp truncate(other), do: other |> inspect() |> String.slice(0, 1_000)
end
