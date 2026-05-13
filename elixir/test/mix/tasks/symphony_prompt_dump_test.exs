defmodule Mix.Tasks.Symphony.Prompt.DumpTest do
  use SymphonyElixir.TestSupport

  alias Mix.Tasks.Symphony.Prompt.Dump

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("symphony.prompt.dump")
    previous_fetcher = Application.get_env(:symphony_elixir, :prompt_dump_issue_fetcher)

    on_exit(fn ->
      Mix.Task.reenable("symphony.prompt.dump")

      if previous_fetcher do
        Application.put_env(:symphony_elixir, :prompt_dump_issue_fetcher, previous_fetcher)
      else
        Application.delete_env(:symphony_elixir, :prompt_dump_issue_fetcher)
      end
    end)

    :ok
  end

  test "prints help" do
    output = capture_io(fn -> Dump.run(["--help"]) end)
    assert output =~ "mix symphony.prompt.dump --issue archelab/symphony#210"
  end

  test "fails on invalid options, unexpected args, and missing issue" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Dump.run(["--wat"])
    end

    assert_raise Mix.Error, ~r/Unexpected argument\(s\): issue/, fn ->
      Dump.run(["issue", "--issue", "archelab/symphony#210"])
    end

    assert_raise Mix.Error, ~r/Missing required option --issue/, fn ->
      Dump.run([])
    end
  end

  test "raises when issue lookup fails" do
    Application.put_env(:symphony_elixir, :prompt_dump_issue_fetcher, fn _issue_ref ->
      {:error, :not_found}
    end)

    assert_raise Mix.Error, ~r/Unable to dump Symphony prompt: :not_found/, fn ->
      Dump.run(["--issue", "archelab/symphony#404"])
    end
  end

  test "prints dump to stdout" do
    configure_fetcher()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "never",
      codex_model: "gpt-5.5",
      codex_turn_sandbox_policy: %{"type" => "workspaceWrite", "networkAccess" => true},
      prompt: "Prompt for {{ issue.identifier }}"
    )

    output =
      capture_io(fn ->
        Dump.run([
          "--issue",
          "archelab/symphony#210",
          "--thread-id",
          "thread-task",
          "--dispatched-at",
          "2026-05-13T22:10:37Z",
          "--attempt",
          "2",
          "--workspace",
          "/tmp/prompt-dump-task"
        ])
      end)

    assert output =~ "# Symphony Prompt Dump"
    assert output =~ "- `cwd`: `/tmp/prompt-dump-task`"
    assert output =~ "Prompt for archelab/symphony#210"
  end

  test "writes dump to a file" do
    configure_fetcher()
    path = Path.join(System.tmp_dir!(), "symphony-prompt-dump-#{System.unique_integer([:positive])}.md")

    try do
      output =
        capture_io(fn ->
          Dump.run(["--issue", "archelab/symphony#210", "--output", path])
        end)

      assert output =~ "Wrote #{path}"
      assert File.read!(path) =~ "# Symphony Prompt Dump"
    after
      File.rm(path)
    end
  end

  defp configure_fetcher do
    Application.put_env(:symphony_elixir, :prompt_dump_issue_fetcher, fn "archelab/symphony#210" ->
      {:ok, sample_issue()}
    end)
  end

  defp sample_issue do
    Issue.new(%{
      id: "PVTI_210",
      content_id: "I_210",
      identifier: "archelab/symphony#210",
      kind: "issue",
      title: "Dump startup prompt",
      description: "Document the startup payload.",
      state: "Agent Ready",
      repository: %{
        owner: "archelab",
        name: "symphony",
        name_with_owner: "archelab/symphony",
        default_branch: "main"
      },
      number: 210,
      url: "https://github.com/archelab/symphony/issues/210",
      labels: [],
      blocked_by: [],
      issue_state: "OPEN"
    })
  end
end
