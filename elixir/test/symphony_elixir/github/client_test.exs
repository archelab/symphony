defmodule SymphonyElixir.Github.ClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Github.Client

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}/graphql"}
  end

  test "sends Bearer token and Next-Global-ID header", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      assert ["Bearer ghp_test"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["1"] = Plug.Conn.get_req_header(conn, "x-github-next-global-id")
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")

      Plug.Conn.resp(conn, 200, ~s({"data": {"viewer": {"login": "x"}}}))
    end)

    assert {:ok, %{"data" => %{"viewer" => %{"login" => "x"}}}} =
             Client.graphql(
               "query { viewer { login } }",
               %{},
               endpoint: url,
               token: "ghp_test"
             )
  end

  test "maps HTTP 401 to tracker_permission_denied", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"message": "Bad credentials"}))
    end)

    assert {:error, {:tracker_permission_denied, _}} =
             Client.graphql("query { viewer { login } }", %{}, endpoint: url, token: "ghp_x")
  end

  test "maps HTTP 429 with Retry-After to github_rate_limited", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "60")
      |> Plug.Conn.resp(429, "")
    end)

    assert {:error, {:github_rate_limited, %{retry_after_seconds: 60}}} =
             Client.graphql("query { viewer { login } }", %{}, endpoint: url, token: "ghp_x")
  end

  test "maps HTTP 200 with FORBIDDEN GraphQL error to tracker_permission_denied",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      body = ~s({"errors":[{"type":"FORBIDDEN","message":"Read access denied"}]})
      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:error, {:tracker_permission_denied, _}} =
             Client.graphql("query { viewer { login } }", %{}, endpoint: url, token: "ghp_x")
  end

  test "maps HTTP 200 with primary rate limit exhaustion", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      body =
        ~s({"data":{"rateLimit":{"remaining":0,"resetAt":"2026-05-10T12:00:00Z"}}})

      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:ok, %{"data" => %{"rateLimit" => rl}}} =
             Client.graphql("query { rateLimit { remaining resetAt } }", %{},
               endpoint: url,
               token: "ghp_x"
             )

    assert rl["remaining"] == 0
    assert rl["resetAt"] == "2026-05-10T12:00:00Z"
  end

  test "returns github_graphql_errors when top-level errors are not FORBIDDEN",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      body = ~s({"errors":[{"type":"NOT_FOUND","message":"thing not found"}]})
      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:error, {:github_graphql_errors, [%{"type" => "NOT_FOUND"}]}} =
             Client.graphql("query { thing { id } }", %{}, endpoint: url, token: "ghp_x")
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Coverage gates — not new requirements, just hit the remaining branches in
  # SymphonyElixir.Github.Client to keep the new module at 100% under
  # `mix test_strict`. PLAN's 6 tests above leave several private clauses
  # unexercised; these 11 tests close that gap.
  # ──────────────────────────────────────────────────────────────────────────

  test "maps HTTP 403 without Retry-After to tracker_permission_denied",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message":"Forbidden"}))
    end)

    assert {:error, {:tracker_permission_denied, %{http: 403}}} =
             Client.graphql("query { x }", %{}, endpoint: url, token: "t")
  end

  test "maps HTTP 403 with Retry-After to github_rate_limited", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "30")
      |> Plug.Conn.resp(403, "")
    end)

    assert {:error, {:github_rate_limited, %{retry_after_seconds: 30}}} =
             Client.graphql("query { x }", %{}, endpoint: url, token: "t")
  end

  test "maps non-401/403/429 non-200 to github_api_status", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      Plug.Conn.resp(conn, 500, "internal server error")
    end)

    assert {:error, {:github_api_status, %{http: 500, body: "internal server error"}}} =
             Client.graphql("query { x }", %{}, endpoint: url, token: "t")
  end

  test "maps transport failure to github_api_request", %{bypass: bypass} do
    Bypass.down(bypass)

    assert {:error, {:github_api_request, _reason}} =
             Client.graphql(
               "query { x }",
               %{},
               endpoint: "http://localhost:#{bypass.port}/graphql",
               token: "t"
             )
  end

  test "maps 200 missing data and errors to github_unknown_payload",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"weird":"shape"}))
    end)

    assert {:error, {:github_unknown_payload, _}} =
             Client.graphql("query { x }", %{}, endpoint: url, token: "t")
  end

  test "treats INSUFFICIENT_SCOPES top-level error as tracker_permission_denied",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      body = ~s({"errors":[{"type":"INSUFFICIENT_SCOPES","message":"need repo scope"}]})
      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:error, {:tracker_permission_denied, _}} =
             Client.graphql("query { x }", %{}, endpoint: url, token: "t")
  end

  test "maps HTTP 429 without Retry-After to github_rate_limited with 60s default",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      Plug.Conn.resp(conn, 429, "")
    end)

    assert {:error, {:github_rate_limited, %{retry_after_seconds: 60}}} =
             Client.graphql("query { x }", %{}, endpoint: url, token: "t")
  end

  # Req auto-decodes application/json bodies into maps, so a 500 response
  # with a JSON content-type returns a map body, not a binary. The truncate/1
  # fallback handles that.
  test "truncate fallback handles non-binary response body",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(500, ~s({"message":"server error"}))
    end)

    assert {:error, {:github_api_status, %{http: 500, body: body}}} =
             Client.graphql("query { x }", %{}, endpoint: url, token: "t")

    assert is_binary(body)
  end

  # Req auto-decodes application/json bodies into maps; on a 200 the body
  # arrives already decoded, exercising the non-binary clause of decode_body/1.
  test "200 with application/json content-type is auto-decoded by Req",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, ~s({"data":{"viewer":{"login":"y"}}}))
    end)

    assert {:ok, %{"data" => %{"viewer" => %{"login" => "y"}}}} =
             Client.graphql("query { viewer { login } }", %{}, endpoint: url, token: "t")
  end

  # Hits the Jason.decode error branch of decode_body/1: 200 with a binary
  # body that is not valid JSON (no application/json header, so Req leaves
  # the raw string in place).
  test "200 with malformed JSON body falls through to github_unknown_payload",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      Plug.Conn.resp(conn, 200, "not json {{{")
    end)

    assert {:error, {:github_unknown_payload, _}} =
             Client.graphql("query { x }", %{}, endpoint: url, token: "t")
  end

  # Hits the Integer.parse failure clause of parse_int/1: 429 with a
  # non-numeric Retry-After should fall back to the 60-second default.
  test "429 with non-numeric Retry-After defaults to 60s",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "soon")
      |> Plug.Conn.resp(429, "")
    end)

    assert {:error, {:github_rate_limited, %{retry_after_seconds: 60}}} =
             Client.graphql("query { x }", %{}, endpoint: url, token: "t")
  end
end
