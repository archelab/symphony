defmodule SymphonyElixir.Config.SessionSummaryTest do
  @moduledoc """
  SPEC §11.8.10 — `agent.session_summary` configuration matrix.

  The session-summary protocol is independent of the workpad protocol: each
  has its own `enabled` flag, its own cross-validation, and its own template
  validation when enabled. These tests cover the four-quadrant matrix
  `(workpad on/off) × (summary on/off)` and the cross-validation that fires
  whenever `agent.session_summary.enabled: true` but `codex.model` is unset.
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  defp parse(attrs) do
    base = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "test-token",
        "owner" => "archelab",
        "project_number" => 1,
        "repo" => "symphony"
      }
    }

    Schema.parse(Map.merge(base, attrs))
  end

  test "agent.session_summary defaults to disabled (SPEC §11.8.10 opt-in)" do
    assert {:ok, settings} =
             parse(%{
               "agent" => %{"workpad" => %{"enabled" => false}}
             })

    assert settings.agent.session_summary.enabled == false
    assert settings.agent.session_summary.version == "v1"
  end

  test "agent.session_summary accepts explicit enabled: false" do
    assert {:ok, settings} =
             parse(%{
               "agent" => %{
                 "workpad" => %{"enabled" => false},
                 "session_summary" => %{"enabled" => false}
               }
             })

    assert settings.agent.session_summary.enabled == false
  end

  test "agent.session_summary rejects unknown version" do
    assert {:error, {:invalid_workflow_config, msg}} =
             parse(%{
               "agent" => %{
                 "workpad" => %{"enabled" => false},
                 "session_summary" => %{"enabled" => false, "version" => "v99"}
               }
             })

    assert msg =~ "session_summary.version"
  end

  test "agent.session_summary.enabled requires codex.model (SPEC §11.8.10 cross-validation)" do
    # SPEC §11.8.10: the `Model:` header field MUST match the agent's
    # self-reported model. Empty Model in an append-only audit comment is
    # a data-integrity bug, so we refuse boot.
    assert {:error, {:invalid_workflow_config, msg}} =
             parse(%{
               "agent" => %{
                 "workpad" => %{"enabled" => false},
                 "session_summary" => %{"enabled" => true}
               }
             })

    assert msg =~ "session_summary"
    assert msg =~ "codex.model"
    assert msg =~ "§11.8.10"
  end

  # ── (workpad on/off) × (summary on/off) matrix ───────────────────────────
  #
  # Per coordinator guidance: session_summary is *independent* of workpad.
  # Every quadrant must be reachable from a valid Schema.parse call.

  test "matrix: workpad on + summary on requires codex.model (both cross-validations satisfied)" do
    assert {:ok, settings} =
             parse(%{
               "agent" => %{
                 "workpad" => %{"enabled" => true},
                 "session_summary" => %{"enabled" => true}
               },
               "codex" => %{"model" => "gpt-5.5"}
             })

    assert settings.agent.workpad.enabled == true
    assert settings.agent.session_summary.enabled == true
  end

  test "matrix: workpad off + summary on is valid (independent features)" do
    assert {:ok, settings} =
             parse(%{
               "agent" => %{
                 "workpad" => %{"enabled" => false},
                 "session_summary" => %{"enabled" => true}
               },
               "codex" => %{"model" => "gpt-5.5"}
             })

    assert settings.agent.workpad.enabled == false
    assert settings.agent.session_summary.enabled == true
  end

  test "matrix: workpad on + summary off is valid (independent features)" do
    assert {:ok, settings} =
             parse(%{
               "agent" => %{
                 "workpad" => %{"enabled" => true},
                 "session_summary" => %{"enabled" => false}
               },
               "codex" => %{"model" => "gpt-5.5"}
             })

    assert settings.agent.workpad.enabled == true
    assert settings.agent.session_summary.enabled == false
  end

  test "matrix: workpad off + summary off requires no codex.model (both cross-validations skipped)" do
    assert {:ok, settings} =
             parse(%{
               "agent" => %{
                 "workpad" => %{"enabled" => false},
                 "session_summary" => %{"enabled" => false}
               }
             })

    assert settings.agent.workpad.enabled == false
    assert settings.agent.session_summary.enabled == false
    assert settings.codex.model == nil
  end
end
