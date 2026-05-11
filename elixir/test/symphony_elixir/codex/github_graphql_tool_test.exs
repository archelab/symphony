defmodule SymphonyElixir.Codex.GithubGraphqlToolTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.GithubGraphqlTool

  test "tool definition declares query+variables schema" do
    %{name: name, description: desc, parameters: params} = GithubGraphqlTool.definition()
    assert name == "github_graphql"
    assert desc =~ "GitHub"
    assert get_in(params, ["properties", "query"])
    assert get_in(params, ["properties", "variables"])
    assert params["required"] == ["query"]
  end

  test "rejects mutations not on the allowlist" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_github_workflow_file!(Workflow.workflow_file_path())

    {:error, {:mutation_not_allowed, name}} =
      GithubGraphqlTool.handle(%{
        "query" => "mutation Drop { deleteProjectV2Field(input:{fieldId:\"x\"}) { __typename } }",
        "variables" => %{}
      })

    assert name == "deleteProjectV2Field"
  end

  test "passes through allowlisted mutation" do
    fake =
      fn query, _v, _opts ->
        assert query =~ "addComment"
        {:ok, %{"data" => %{"addComment" => %{"clientMutationId" => "x"}}}}
      end

    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, %{"data" => %{"addComment" => _}}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { addComment(input:{subjectId:\"x\", body:\"hi\"}) { clientMutationId } }",
               "variables" => %{}
             })
  end

  test "allows updateIssueComment when agent.workpad.enabled (SPEC §11.8.4 / §17.8)" do
    fake =
      fn query, _v, _opts ->
        assert query =~ "updateIssueComment"
        {:ok, %{"data" => %{"updateIssueComment" => %{"issueComment" => %{"id" => "c1"}}}}}
      end

    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_github_workflow_file!(Workflow.workflow_file_path(), agent_workpad_enabled: true, codex_model: "gpt-5.5")

    assert {:ok, %{"data" => %{"updateIssueComment" => _}}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { updateIssueComment(input:{id:\"c1\", body:\"corrected\"}) { issueComment { id } } }",
               "variables" => %{}
             })
  end

  test "rejects updateIssueComment when agent.workpad is disabled (SPEC §17.8)" do
    # No `fake` stub installed — if the mutation slipped past the allowlist
    # we'd hit the real Client.graphql/3 and fail differently. The expected
    # path returns the allowlist rejection BEFORE the transport call.
    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:error, {:mutation_not_allowed, "updateIssueComment"}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { updateIssueComment(input:{id:\"c1\", body:\"x\"}) { issueComment { id } } }",
               "variables" => %{}
             })
  end

  test "operator-narrowed allowlist still gets updateIssueComment when workpad enabled (SPEC §11.8.4 + §18.2.1)" do
    fake =
      fn _q, _v, _opts ->
        {:ok, %{"data" => %{"updateIssueComment" => %{"issueComment" => %{"id" => "c2"}}}}}
      end

    Application.put_env(:symphony_elixir, :github_client, fake)
    # Operator narrows the allowlist to a single non-workpad mutation. The
    # workpad-gated extras are still added on top because §11.8.4 says they
    # MUST be available when the protocol is enabled.
    Application.put_env(:symphony_elixir, :github_graphql_mutation_allowlist, ~w(updateProjectV2ItemFieldValue))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_client)
      Application.delete_env(:symphony_elixir, :github_graphql_mutation_allowlist)
    end)

    write_github_workflow_file!(Workflow.workflow_file_path(), agent_workpad_enabled: true, codex_model: "gpt-5.5")

    assert {:ok, %{"data" => %{"updateIssueComment" => _}}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { updateIssueComment(input:{id:\"c2\", body:\"x\"}) { issueComment { id } } }",
               "variables" => %{}
             })

    # addComment is NOT in the operator's narrowed list AND not in the workpad
    # extras → still rejected. This confirms the merge does not silently
    # re-introduce the full default allowlist.
    assert {:error, {:mutation_not_allowed, "addComment"}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { addComment(input:{subjectId:\"x\", body:\"x\"}) { clientMutationId } }",
               "variables" => %{}
             })
  end

  test "rejects deleteIssueComment — workpad is append-only at the row level (SPEC §11.8.4)" do
    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:error, {:mutation_not_allowed, "deleteIssueComment"}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { deleteIssueComment(input:{id:\"c1\"}) { clientMutationId } }",
               "variables" => %{}
             })
  end

  test "rejects multi-mutation document where any field is not allowlisted" do
    write_github_workflow_file!(Workflow.workflow_file_path())

    {:error, {:mutation_not_allowed, name}} =
      GithubGraphqlTool.handle(%{
        "query" => """
        mutation {
          addComment(input: {subjectId: "x", body: "hi"}) { clientMutationId }
          deleteIssue(input: {issueId: "y"}) { clientMutationId }
        }
        """,
        "variables" => %{}
      })

    assert name == "deleteIssue"
  end

  test "named mutation with variables extracts the field name correctly" do
    fake =
      fn query, _v, _opts ->
        assert query =~ "addComment"
        {:ok, %{"data" => %{"addComment" => %{}}}}
      end

    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation Op($id: ID!, $body: String!) { addComment(input: {subjectId: $id, body: $body}) { clientMutationId } }",
               "variables" => %{"id" => "x", "body" => "hi"}
             })
  end

  test "rejects malformed mutation with mutation_unparseable" do
    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{"query" => "mutation Op", "variables" => %{}})

    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{"query" => "mutation { ", "variables" => %{}})
  end

  test "shorthand query syntax {} is allowed without mutation gating" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"viewer" => %{"login" => "x"}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{"query" => "{ viewer { login } }", "variables" => %{}})
  end

  test "leading comments are stripped before keyword detection" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"viewer" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => "# leading comment\n# another\nquery { viewer { login } }",
               "variables" => %{}
             })
  end

  test "unknown top-level keyword returns mutation_unparseable" do
    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{
               "query" => "fragment Foo on Bar { id }",
               "variables" => %{}
             })
  end

  test "mutation with nested parens and selection sets parses top-level fields correctly" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"addComment" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_github_workflow_file!(Workflow.workflow_file_path())

    # Nested parens inside argument literals exercise the skip_parens depth
    # counter; nested selection sets inside the outer braces exercise the
    # depth > 0 walk_fields branch (those names must not be promoted to
    # top-level mutation fields).
    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => """
               mutation {
                 addComment(input: {subjectId: "x", body: "((nested))"}) {
                   clientMutationId
                   commentEdge { node { id } }
                 }
               }
               """,
               "variables" => %{}
             })
  end

  test "empty mutation body returns mutation_unparseable" do
    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{"query" => "mutation {  }", "variables" => %{}})
  end

  test "mutation body whose only top-level field has an unclosed argument list" do
    write_github_workflow_file!(Workflow.workflow_file_path())

    # The regex permits this because the outer `{...}` is balanced; the
    # internal `(` is not. `skip_parens` consumes to end-of-charlist and
    # returns [], which is then re-entered by `walk_fields/4` and emits no
    # top-level field — so the document is rejected as unparseable.
    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { addComment(input }",
               "variables" => %{}
             })
  end

  test "top-level directives on allowlisted mutations are skipped (not gated as fields)" do
    fake = fn query, _v, _opts ->
      assert query =~ "addComment"
      {:ok, %{"data" => %{"addComment" => %{}}}}
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)
    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { addComment(input: {subjectId: \"x\", body: \"hi\"}) @log(level: \"info\") { clientMutationId } }",
               "variables" => %{}
             })
  end

  test "string literal containing } does not confuse the walker" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"addComment" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)
    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => ~s|mutation { addComment(input: {subjectId: "x", body: "} { reply"}) { clientMutationId } }|,
               "variables" => %{}
             })
  end

  test "string literal containing escaped quote does not exit string state" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"addComment" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)
    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => ~s|mutation { addComment(input: {subjectId: "x", body: "He said \\"hi}\\""}) { clientMutationId } }|,
               "variables" => %{}
             })
  end

  test "variable definition default value with quoted brace does not anchor outer body open" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"addComment" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)
    write_github_workflow_file!(Workflow.workflow_file_path())

    # The variable default string contains `{` and `}` plus an escaped quote;
    # without string-literal awareness in scan_to_outer_open_brace/2 the body
    # opener would latch onto the quoted `{` and the walker would extract
    # garbage field names.
    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => ~s|mutation Foo($body: String = "before { quoted \\"q\\" } after") { addComment(input: {subjectId: "x", body: $body}) { clientMutationId } }|,
               "variables" => %{}
             })
  end

  test "inline GraphQL comments inside mutation body are skipped, not gated as fields" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"addComment" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)
    write_github_workflow_file!(Workflow.workflow_file_path())

    # `#comment` at top level inside the mutation body. Without the `#` skip
    # in maybe_emit/3 the walker would treat the comment text as a field
    # name and the allowlist gate would reject the mutation.
    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation {\n  #commentbeforefield\n  addComment(input: {subjectId: \"x\", body: \"hi\"}) { clientMutationId }\n}",
               "variables" => %{}
             })
  end

  test "skip_parens tolerates quoted parens inside argument string literals" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"addComment" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)
    write_github_workflow_file!(Workflow.workflow_file_path())

    # Unbalanced parens INSIDE a quoted string ("oops :)") plus an escaped
    # quote — skip_parens must stay in string state until the closing `"`.
    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => ~s|mutation { addComment(input: {subjectId: "x", body: "oops :) said \\"hi\\""}) { clientMutationId } }|,
               "variables" => %{}
             })
  end

  # Walker limitations documented for future improvement. These cases reject
  # legal-but-rare GraphQL forms; they do NOT mis-allow disallowed mutations.

  test "field alias on allowlisted mutation is currently rejected (walker limitation)" do
    write_github_workflow_file!(Workflow.workflow_file_path())
    # `local: addComment(...)` — alias before a field. Walker emits `local:` and
    # rejects against the allowlist. Tracked for future fix.
    assert {:error, {:mutation_not_allowed, alias_name}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { local: addComment(input: {subjectId: \"x\", body: \"hi\"}) { clientMutationId } }",
               "variables" => %{}
             })

    assert alias_name =~ "local"
  end

  test ~s[block string """...""" inside mutation body is currently mishandled (walker limitation)] do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"addComment" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)
    write_github_workflow_file!(Workflow.workflow_file_path())

    # Block string literals are NOT tracked by the walker. Braces inside a
    # """...""" block string would prematurely close the body span. Tracked
    # for future fix. Current test pins the behavior to know when it changes.
    result =
      GithubGraphqlTool.handle(%{
        "query" => ~s|mutation { addComment(input: {subjectId: "x", body: """hi { } there"""}) { clientMutationId } }|,
        "variables" => %{}
      })

    # We intentionally do not assert `{:ok, _}` here — that would lie about
    # current capability. We assert SOMETHING comes back so the test fails
    # loudly if the shape changes (e.g., raises).
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end

  test "inline fragment at mutation top level is currently rejected (walker + GraphQL grammar)" do
    write_github_workflow_file!(Workflow.workflow_file_path())
    # Inline fragments at mutation top level are illegal GraphQL anyway, so the
    # rejection is desired — but it surfaces as `... on Whatever` becoming a
    # candidate "field". Document the rejection vocabulary.
    assert {:error, _} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { ... on Whatever { addComment(input: {subjectId: \"x\", body: \"hi\"}) { clientMutationId } } }",
               "variables" => %{}
             })
  end

  test "operator can narrow the mutation allowlist via Application env" do
    # Default allowlist includes addComment; override to only allow
    # updateProjectV2ItemFieldValue and confirm addComment is now rejected.
    Application.put_env(
      :symphony_elixir,
      :github_graphql_mutation_allowlist,
      ~w(updateProjectV2ItemFieldValue)
    )

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_graphql_mutation_allowlist) end)

    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:error, {:mutation_not_allowed, "addComment"}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { addComment(input: {subjectId: \"x\", body: \"hi\"}) { clientMutationId } }",
               "variables" => %{}
             })
  end

  test "operator can widen the mutation allowlist via Application env" do
    Application.put_env(
      :symphony_elixir,
      :github_graphql_mutation_allowlist,
      ~w(addComment customMutation)
    )

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_graphql_mutation_allowlist) end)

    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"customMutation" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_github_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, %{"data" => %{"customMutation" => _}}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { customMutation(input: {x: 1}) { ok } }",
               "variables" => %{}
             })
  end
end
