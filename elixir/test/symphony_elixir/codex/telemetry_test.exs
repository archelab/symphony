defmodule SymphonyElixir.Codex.TelemetryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Telemetry

  defp event(method, params \\ %{}) do
    %{event: :notification, message: %{"method" => method, "params" => params}}
  end

  test "extract_token_delta prefers absolute thread totals and computes deltas from prior reported values" do
    running_entry = %{
      codex_last_reported_input_tokens: 10,
      codex_last_reported_output_tokens: 4,
      codex_last_reported_total_tokens: 14
    }

    update = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{
              "inputTokens" => 15,
              "outputTokens" => 6,
              "totalTokens" => 21
            }
          }
        }
      }
    }

    assert %{
             input_tokens: 5,
             output_tokens: 2,
             total_tokens: 7,
             reported_input_tokens: 15,
             reported_output_tokens: 6,
             reported_total_tokens: 21
           } = Telemetry.extract_token_delta(running_entry, update)
  end

  test "extract_token_delta preserves prior reported values when no token usage is present" do
    running_entry = %{
      codex_last_reported_input_tokens: 3,
      codex_last_reported_output_tokens: 4,
      codex_last_reported_total_tokens: 7
    }

    assert %{
             input_tokens: 0,
             output_tokens: 0,
             total_tokens: 0,
             reported_input_tokens: 3,
             reported_output_tokens: 4,
             reported_total_tokens: 7
           } = Telemetry.extract_token_delta(running_entry, %{payload: %{}})
  end

  test "extract_token_delta accepts direct turn-completed usage maps and string counts" do
    update = %{
      payload: %{
        "method" => "turn/completed",
        "usage" => %{"prompt_tokens" => "9", "completion_tokens" => "3", "total_tokens" => "12"}
      }
    }

    assert %{
             input_tokens: 9,
             output_tokens: 3,
             total_tokens: 12,
             reported_input_tokens: 9,
             reported_output_tokens: 3,
             reported_total_tokens: 12
           } = Telemetry.extract_token_delta(%{}, update)
  end

  test "extract_token_delta accepts nested turn-completed params usage" do
    update = %{
      payload: %{
        "method" => "turn/completed",
        "params" => %{"usage" => %{"input_tokens" => 4, "output_tokens" => 1, "total_tokens" => 5}}
      }
    }

    assert %{input_tokens: 4, output_tokens: 1, total_tokens: 5} =
             Telemetry.extract_token_delta(%{}, update)

    atom_update = %{
      payload: %{
        method: :turn_completed,
        params: %{usage: %{input_tokens: 2, output_tokens: 2, total_tokens: 4}}
      }
    }

    assert %{total_tokens: 4} = Telemetry.extract_token_delta(%{}, atom_update)

    malformed = %{payload: %{"method" => "turn/completed", "params" => "bad"}}
    assert %{input_tokens: 0, output_tokens: 0, total_tokens: 0} = Telemetry.extract_token_delta(%{}, malformed)

    invalid_number = %{usage: %{"input_tokens" => "bad", "total_tokens" => "also bad"}}
    assert %{input_tokens: 0, total_tokens: 0} = Telemetry.extract_token_delta(%{}, invalid_number)

    malformed_absolute = %{payload: %{"params" => "bad"}}
    assert %{input_tokens: 0, total_tokens: 0} = Telemetry.extract_token_delta(%{}, malformed_absolute)

    invalid_absolute = %{
      payload: %{"params" => %{"msg" => %{"info" => %{"total_token_usage" => %{"input_tokens" => "bad"}}}}}
    }

    assert %{input_tokens: 0, total_tokens: 0} = Telemetry.extract_token_delta(%{}, invalid_absolute)
  end

  test "extract_rate_limits finds nested rate limit payloads" do
    update = %{
      payload: %{
        "params" => %{
          "result" => %{
            "rateLimit" => %{
              "remaining" => 42,
              "resetAt" => "2026-05-14T12:00:00Z"
            }
          }
        }
      }
    }

    assert %{"remaining" => 42, "resetAt" => "2026-05-14T12:00:00Z"} =
             Telemetry.extract_rate_limits(update)
  end

  test "extract_rate_limits accepts direct, top-level, and list-wrapped snapshots" do
    direct = %{"rate_limits" => %{"limit_id" => "main", "primary" => %{"usedPercent" => 25, "windowDurationMins" => 10}}}
    assert %{"primary" => %{"usedPercent" => 25}} = Telemetry.extract_rate_limits(direct)

    basic = %{rate_limits: %{remaining: 5, resetAt: "2026-05-14T12:00:00Z"}}
    assert %{remaining: 5, resetAt: "2026-05-14T12:00:00Z"} = Telemetry.extract_rate_limits(basic)

    nested = %{payload: [%{ignored: true}, %{limit_id: "main", primary: %{usedPercent: 10}}]}
    assert %{limit_id: "main", primary: %{usedPercent: 10}} = Telemetry.extract_rate_limits(nested)

    assert is_nil(Telemetry.extract_rate_limits(%{payload: [:nope, %{other: []}]}))
  end

  test "humanize_message returns stable labels for known Codex notifications" do
    assert Telemetry.humanize_message(%{
             event: :notification,
             message: %{"method" => "codex/event/task_started"}
           }) == "task started"

    assert Telemetry.humanize_message(%{
             event: :turn_completed,
             message: %{"method" => "turn/completed"}
           }) == "turn completed (completed)"
  end

  test "humanize_message covers codex event envelopes and fallback payload shapes" do
    long = String.duplicate("x", 200)

    cases = [
      {nil, "no codex message yet"},
      {%{event: :session_started, message: %{session_id: "thread-1"}}, "session started (thread-1)"},
      {%{event: :session_started, message: %{}}, "session started"},
      {%{event: :turn_input_required, message: %{}}, "turn blocked: waiting for user input"},
      {%{event: :turn_ended_with_error, message: %{reason: %{"message" => "bad"}}}, "turn ended with error: bad"},
      {%{event: :turn_ended_with_error, message: %{}}, "turn ended with error:"},
      {%{event: :startup_failed, message: %{reason: %{message: "boot"}}}, "startup failed: boot"},
      {%{event: :startup_failed, message: %{reason: :boot_failed}}, "startup failed: :boot_failed"},
      {%{event: :startup_failed, message: "raw failure"}, "startup failed: \"raw failure\""},
      {%{event: :turn_failed, message: %{"method" => "turn/failed"}}, "turn failed"},
      {%{event: :turn_cancelled, message: %{}}, "turn cancelled"},
      {%{event: :malformed, message: %{}}, "malformed JSON event from codex"},
      {%{message: %{"session_id" => "thread-2"}}, "session started (thread-2)"},
      {%{message: %{"error" => %{"message" => "oops"}}}, "error: oops"},
      {%{message: %{foo: "bar"}}, "foo"},
      {"line1\n\u001B[31mline2", "line1 line2"},
      {42, "42"},
      {long, String.slice(long, 0, 80)}
    ]

    Enum.each(cases, fn {message, expected} ->
      assert Telemetry.humanize_message(message) =~ expected
    end)
  end

  test "humanize_message covers approval and user-input fallbacks" do
    approval = %{
      event: :approval_auto_approved,
      message: %{
        "payload" => %{"method" => "item/commandExecution/requestApproval", "params" => %{"command" => ["mix", "test"]}},
        "decision" => "accept"
      }
    }

    assert Telemetry.humanize_message(approval) =~ "mix test"
    assert Telemetry.humanize_message(approval) =~ "auto-approved"

    assert Telemetry.humanize_message(%{event: :approval_auto_approved, message: %{}}) ==
             "approval request auto-approved"

    assert Telemetry.humanize_message(%{event: :tool_input_auto_answered, message: %{}}) ==
             "tool requires user input (auto-answered)"
  end

  test "humanize_message covers codex app-server methods and wrapper methods" do
    cases = [
      {event("thread/started", %{"thread" => %{"id" => "thread-1"}}), "thread started (thread-1)"},
      {event("thread/started"), "thread started"},
      {%{event: :notification, message: %{"method" => "thread/started", "params" => "bad"}}, "thread started"},
      {event("turn/started"), "turn started"},
      {event("turn/completed", %{"usage" => %{"inputTokens" => 1200}}), "in 1,200"},
      {event("turn/completed", %{"usage" => %{}}), "turn completed (completed)"},
      {event("turn/completed", %{"usage" => %{"input_tokens" => "bad"}}), "turn completed (completed)"},
      {event("turn/failed", %{"error" => %{"message" => "bad turn"}}), "turn failed: bad turn"},
      {event("turn/cancelled"), "turn cancelled"},
      {event("turn/diff/updated"), "turn diff updated"},
      {event("turn/plan/updated", %{"plan" => "not-list"}), "plan updated"},
      {event("turn/plan/updated", %{plan: [%{}]}), "plan updated (1 steps)"},
      {event("turn/plan/updated", %{"steps" => [%{}, %{}]}), "plan updated (2 steps)"},
      {event("turn/plan/updated", %{items: [%{}, %{}, %{}]}), "plan updated (3 steps)"},
      {event("thread/tokenUsage/updated"), "thread token usage updated"},
      {event("item/commandExecution/requestApproval"), "command approval requested"},
      {event("item/commandExecution/requestApproval", %{"parsedCmd" => %{"command" => "mix", "args" => ["test"]}}), "command approval requested (mix test)"},
      {event("item/commandExecution/requestApproval", %{"parsedCmd" => %{"cmd" => "mix test"}}), "command approval requested (mix test)"},
      {event("item/fileChange/requestApproval"), "file change approval requested"},
      {event("item/tool/requestUserInput", %{"prompt" => ""}), "tool requires user input"},
      {event("tool/requestUserInput", %{"prompt" => "Need value?"}), "tool requires user input: Need value?"},
      {event("item/tool/requestUserInput", %{question: "Atom question?"}), "tool requires user input: Atom question?"},
      {event("account/updated", %{"authMode" => "chatgpt"}), "account updated (auth chatgpt)"},
      {event("account/updated"), "account updated (auth unknown)"},
      {event("account/rateLimits/updated"), "rate limits updated: n/a"},
      {event("account/rateLimits/updated", %{"rateLimits" => "bad"}), "rate limits updated: n/a"},
      {event("account/chatgptAuthTokens/refresh"), "account auth token refresh requested"},
      {event("item/tool/call"), "dynamic tool call requested"},
      {%{event: :tool_call_completed, message: %{payload: %{"method" => "noop"}}}, "dynamic tool call completed"},
      {%{event: :tool_call_completed, message: %{payload: %{"params" => %{"tool" => " "}}}}, "dynamic tool call completed"},
      {event("unknown/method", %{"msg" => %{"type" => "custom"}}), "unknown/method (custom)"},
      {event("unknown/method"), "unknown/method"}
    ]

    Enum.each(cases, fn {message, expected} ->
      assert Telemetry.humanize_message(message) =~ expected
    end)
  end

  test "humanize_message covers rate-limit summaries and wrapper details" do
    rate_limits = %{
      "primary" => %{"usedPercent" => 50, "windowDurationMins" => 5},
      "secondary" => %{"usedPercent" => 20}
    }

    cases = [
      {event("account/rateLimits/updated", %{"rateLimits" => rate_limits}), "primary 50% / 5m; secondary 20% used"},
      {event("account/rateLimits/updated", %{"rateLimits" => %{"primary" => %{}}}), "n/a"},
      {event("codex/event/mcp_startup_update", %{"msg" => %{"server" => "github", "status" => %{"state" => "ready"}}}), "mcp startup: github ready"},
      {%{
         event: :notification,
         message: %{
           "method" => "codex/event/mcp_startup_update",
           params: %{msg: %{server: "agent", status: %{state: "ready"}}}
         }
       }, "mcp startup: agent ready"},
      {event("codex/event/mcp_startup_complete"), "mcp startup complete"},
      {event("codex/event/user_message"), "user message received"},
      {event("codex/event/item_started", %{"msg" => %{"payload" => %{"type" => "token_count"}}}), "token count update"},
      {event("codex/event/item_started", %{"msg" => %{"payload" => %{"type" => "agentMessage"}}}), "item started (agent message)"},
      {event("codex/event/item_completed"), "item completed"},
      {event("codex/event/item_completed", %{"msg" => %{"payload" => %{"type" => "token_count"}}}), "token count update"},
      {event("codex/event/item_completed", %{"msg" => %{"payload" => %{"type" => "commandExecution"}}}), "item completed (command execution)"},
      {event("codex/event/item_started"), "item started"},
      {event("codex/event/agent_message_content_delta", %{"msg" => %{"payload" => %{"delta" => "text"}}}), "agent message content streaming: text"},
      {event("codex/event/agent_reasoning_delta", %{"msg" => %{"payload" => %{"delta" => "think"}}}), "reasoning streaming: think"},
      {event("codex/event/reasoning_content_delta"), "reasoning content streaming"},
      {event("codex/event/agent_reasoning_section_break"), "reasoning section break"},
      {event("codex/event/turn_diff"), "turn diff updated"},
      {event("codex/event/exec_command_begin"), "command started"},
      {event("codex/event/exec_command_begin", %{"msg" => %{"parsed_cmd" => ["git", "status"]}}), "git status"},
      {event("codex/event/exec_command_end", %{"msg" => %{"exit_code" => 2}}), "command completed (exit 2)"},
      {event("codex/event/exec_command_end"), "command completed"},
      {event("codex/event/exec_command_output_delta"), "command output streaming"},
      {event("codex/event/mcp_tool_call_begin"), "mcp tool call started"},
      {event("codex/event/mcp_tool_call_end"), "mcp tool call completed"},
      {event("codex/event/token_count", %{"msg" => %{"payload" => %{"info" => %{"total_token_usage" => %{total: 8}}}}}), "token count update (total 8)"},
      {event("codex/event/other", %{"msg" => %{"type" => "notice"}}), "other (notice)"}
    ]

    Enum.each(cases, fn {message, expected} ->
      assert Telemetry.humanize_message(message) =~ expected
    end)

    assert Telemetry.humanize_message(%{event: :notification, message: %{"method" => "codex/event/other"}}) ==
             "other"

    assert Telemetry.humanize_message(%{
             event: :notification,
             message: %{"method" => "codex/event/other", params: %{msg: %{type: "atom-notice"}}}
           }) == "other (atom-notice)"
  end

  test "humanize_message covers item lifecycle fallback details" do
    cases = [
      {event("item/started"), "item started: item"},
      {event("item/started", %{"item" => %{}}), "item started: item"},
      {%{event: :notification, message: %{"method" => "item/started", params: %{item: %{type: "fileChange"}}}}, "item started: file change"},
      {event("item/started", %{"item" => %{"id" => "short", "type" => 123}}), "item started: 123 (short)"},
      {event("item/completed", %{item: %{type: "agentMessage", status: nil}}), "item completed: agent message"}
    ]

    Enum.each(cases, fn {message, expected} ->
      assert Telemetry.humanize_message(message) =~ expected
    end)
  end
end
