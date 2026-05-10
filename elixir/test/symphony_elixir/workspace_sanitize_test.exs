defmodule SymphonyElixir.WorkspaceSanitizeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workspace

  test "replaces / and # in GitHub identifier" do
    assert Workspace.workspace_key("archelab/symphony#42") == "archelab_symphony_42"
  end

  test "replaces / and # in cross-repo PR identifier" do
    assert Workspace.workspace_key("archelab/arche#1234") == "archelab_arche_1234"
  end

  test "preserves dashes and dots" do
    assert Workspace.workspace_key("myorg/my-repo.x#1") == "myorg_my-repo.x_1"
  end

  test "passes through draft identifier" do
    assert Workspace.workspace_key("draft:AF6gQ123") == "draft_AF6gQ123"
  end

  test "no path separator survives" do
    refute String.contains?(Workspace.workspace_key("a/b#c"), "/")
    refute String.contains?(Workspace.workspace_key("a/b#c"), "#")
  end

  test "control chars and whitespace are replaced" do
    assert Workspace.workspace_key("a\tb c\n#1") == "a_b_c__1"
  end

  test "dot-only identifier survives sanitizer (spec §4.2 allows .)" do
    # `.` and `..` are intentionally not stripped here. Spec §9.5 path-prefix
    # containment is the defense in depth — every workspace path computed from
    # the result of workspace_key/1 must pass through PathSafety.canonicalize/1
    # and a workspace-root prefix check before any filesystem operation.
    assert Workspace.workspace_key("..") == ".."
    assert Workspace.workspace_key(".") == "."
  end
end
