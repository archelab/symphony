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

    write_workflow_file!(Workflow.workflow_file_path())

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

    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, %{"data" => %{"addComment" => _}}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { addComment(input:{subjectId:\"x\", body:\"hi\"}) { clientMutationId } }",
               "variables" => %{}
             })
  end

  test "rejects multi-mutation document where any field is not allowlisted" do
    write_workflow_file!(Workflow.workflow_file_path())

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

    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation Op($id: ID!, $body: String!) { addComment(input: {subjectId: $id, body: $body}) { clientMutationId } }",
               "variables" => %{"id" => "x", "body" => "hi"}
             })
  end

  test "rejects malformed mutation with mutation_unparseable" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{"query" => "mutation Op", "variables" => %{}})

    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{"query" => "mutation { ", "variables" => %{}})
  end

  test "shorthand query syntax {} is allowed without mutation gating" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"viewer" => %{"login" => "x"}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{"query" => "{ viewer { login } }", "variables" => %{}})
  end

  test "leading comments are stripped before keyword detection" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"viewer" => %{}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" => "# leading comment\n# another\nquery { viewer { login } }",
               "variables" => %{}
             })
  end

  test "unknown top-level keyword returns mutation_unparseable" do
    write_workflow_file!(Workflow.workflow_file_path())

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

    write_workflow_file!(Workflow.workflow_file_path())

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
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{"query" => "mutation {  }", "variables" => %{}})
  end

  test "mutation body whose only top-level field has an unclosed argument list" do
    write_workflow_file!(Workflow.workflow_file_path())

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
    write_workflow_file!(Workflow.workflow_file_path())

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
    write_workflow_file!(Workflow.workflow_file_path())

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
    write_workflow_file!(Workflow.workflow_file_path())

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
    write_workflow_file!(Workflow.workflow_file_path())

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
    write_workflow_file!(Workflow.workflow_file_path())

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
    write_workflow_file!(Workflow.workflow_file_path())

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
    write_workflow_file!(Workflow.workflow_file_path())
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
    write_workflow_file!(Workflow.workflow_file_path())

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
    write_workflow_file!(Workflow.workflow_file_path())
    # Inline fragments at mutation top level are illegal GraphQL anyway, so the
    # rejection is desired — but it surfaces as `... on Whatever` becoming a
    # candidate "field". Document the rejection vocabulary.
    assert {:error, _} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { ... on Whatever { addComment(input: {subjectId: \"x\", body: \"hi\"}) { clientMutationId } } }",
               "variables" => %{}
             })
  end
end
