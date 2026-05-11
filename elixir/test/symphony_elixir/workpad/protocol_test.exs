defmodule SymphonyElixir.Workpad.ProtocolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workpad.Protocol

  test "marker_open/marker_close interpolate the version verbatim" do
    assert Protocol.marker_open("v1") == "<!-- symphony-workpad:v1 -->"
    assert Protocol.marker_close("v1") == "<!-- /symphony-workpad:v1 -->"
  end

  test "supported_versions/0 contains v1" do
    assert "v1" in Protocol.supported_versions()
  end

  test "supported?/1 accepts known, rejects unknown" do
    assert Protocol.supported?("v1")
    refute Protocol.supported?("v2")
    refute Protocol.supported?(nil)
    refute Protocol.supported?(:v1)
  end

  test "defaults are positive integers and v1 version" do
    assert Protocol.default_max_sessions_visible() == 20
    assert Protocol.default_update_throttle_turns() == 3
    assert Protocol.default_version() == "v1"
  end

  test "prompt_variables/0 lists the five workpad Liquid variables (SPEC §11.8.5)" do
    vars = Protocol.prompt_variables()
    assert vars == ~w(thread_id subject_id prior_sessions dispatched_at model)
    assert Enum.all?(vars, &is_binary/1)
    assert length(vars) == 5
  end

  test "Workpad.Protocol defaults match Config.Schema.Agent.Workpad defaults" do
    w = struct(SymphonyElixir.Config.Schema.Agent.Workpad)
    assert w.version == Protocol.default_version()
    assert w.max_sessions_visible == Protocol.default_max_sessions_visible()
    assert w.update_throttle_turns == Protocol.default_update_throttle_turns()
    refute w.enabled
  end
end
