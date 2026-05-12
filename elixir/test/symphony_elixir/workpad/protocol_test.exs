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
    # SPEC §11.8.9 (PR4 amendment): workpad enabled by default.
    assert w.enabled
  end

  # ── Per-session summary protocol (SPEC §11.8.10) ─────────────────────────

  test "session_summary_marker_open/2 embeds thread_id + version verbatim (SPEC §11.8.10)" do
    assert Protocol.session_summary_marker_open("v1", "thr-abc123") ==
             "<!-- symphony-session-summary:thr-abc123:v1 -->"
  end

  test "session_summary_marker_close/2 mirrors the opener with a leading slash" do
    assert Protocol.session_summary_marker_close("v1", "thr-abc123") ==
             "<!-- /symphony-session-summary:thr-abc123:v1 -->"
  end

  test "session_summary_marker_open/close round-trip on distinct thread_ids produces distinct markers" do
    a = Protocol.session_summary_marker_open("v1", "thr-aaaa")
    b = Protocol.session_summary_marker_open("v1", "thr-bbbb")

    assert a != b
    assert a =~ "thr-aaaa"
    assert b =~ "thr-bbbb"

    # The thread_id-scoped marker is the §11.8.10 distinguishing feature
    # vs. §11.8.1's `<!-- symphony-workpad:v1 -->` — the latter is a single
    # comment per issue, the former is one comment per session.
    refute Protocol.marker_open("v1") =~ "thr-"
  end

  test "session_summary_supported_versions/0 contains v1" do
    assert "v1" in Protocol.session_summary_supported_versions()
  end

  test "session_summary_default_version/0 returns v1" do
    assert Protocol.session_summary_default_version() == "v1"
  end

  test "session_summary_header_fields/0 lists the §11.8.10 RFC822 keys in render order" do
    fields = Protocol.session_summary_header_fields()

    assert fields == [:Session, :Attempt, :Dispatched, :Completed, :Duration, :Model, :"Stop reason"]
    assert Enum.all?(fields, &is_atom/1)
  end

  test "SessionSummary schema defaults match Protocol session-summary defaults" do
    s = struct(SymphonyElixir.Config.Schema.Agent.SessionSummary)
    assert s.version == Protocol.session_summary_default_version()
    # SPEC §11.8.10: independent of workpad, opt-in by default.
    refute s.enabled
  end
end
