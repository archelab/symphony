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

  @spec graphql(String.t(), map(), opts()) ::
          {:ok, map()} | {:error, {atom(), term()}}
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
  # to lists of values. Linear-style list-of-tuples and uppercase-key shapes
  # were dropped along with that dead clause; the public surface only ever
  # sees this shape.
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
