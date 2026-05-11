defmodule SymphonyElixir.Config.WorkpadTest do
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

  test "agent.workpad defaults to disabled" do
    assert {:ok, settings} = parse(%{})
    assert settings.agent.workpad.enabled == false
    assert settings.agent.workpad.version == "v1"
    assert settings.agent.workpad.max_sessions_visible == 20
    assert settings.agent.workpad.update_throttle_turns == 3
  end

  test "agent.workpad accepts enabled override" do
    assert {:ok, settings} =
             parse(%{"agent" => %{"workpad" => %{"enabled" => true}}})

    assert settings.agent.workpad.enabled == true
  end

  test "agent.workpad accepts custom limits" do
    assert {:ok, settings} =
             parse(%{
               "agent" => %{
                 "workpad" => %{
                   "max_sessions_visible" => 5,
                   "update_throttle_turns" => 0
                 }
               }
             })

    assert settings.agent.workpad.max_sessions_visible == 5
    assert settings.agent.workpad.update_throttle_turns == 0
  end

  test "agent.workpad rejects unknown version" do
    assert {:error, {:invalid_workflow_config, msg}} =
             parse(%{"agent" => %{"workpad" => %{"version" => "v99"}}})

    assert msg =~ "workpad.version"
  end

  test "agent.workpad rejects non-positive max_sessions_visible" do
    assert {:error, {:invalid_workflow_config, _msg}} =
             parse(%{"agent" => %{"workpad" => %{"max_sessions_visible" => 0}}})
  end

  test "agent.workpad rejects negative update_throttle_turns" do
    assert {:error, {:invalid_workflow_config, _msg}} =
             parse(%{"agent" => %{"workpad" => %{"update_throttle_turns" => -1}}})
  end

  test "codex.model defaults to nil" do
    assert {:ok, settings} = parse(%{})
    assert settings.codex.model == nil
  end

  test "codex.model accepts an explicit string" do
    assert {:ok, settings} = parse(%{"codex" => %{"model" => "gpt-5.5"}})
    assert settings.codex.model == "gpt-5.5"
  end

  test "agent.workpad.enabled requires codex.model to be set (SPEC §11.8.5)" do
    assert {:error, {:invalid_workflow_config, msg}} =
             parse(%{"agent" => %{"workpad" => %{"enabled" => true}}})

    assert msg =~ "codex.model"
    assert msg =~ "§11.8.5"
  end

  test "agent.workpad.enabled accepts a config that also sets codex.model (SPEC §11.8.5)" do
    assert {:ok, settings} =
             parse(%{
               "agent" => %{"workpad" => %{"enabled" => true}},
               "codex" => %{"model" => "gpt-5.5"}
             })

    assert settings.agent.workpad.enabled == true
    assert settings.codex.model == "gpt-5.5"
  end
end
