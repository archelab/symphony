defmodule SymphonyElixir.Github.RateLimitGateTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Github.RateLimitGate

  setup do
    RateLimitGate.clear()
    on_exit(&RateLimitGate.clear/0)
    :ok
  end

  test "secondary signal gates subsequent reads" do
    :ok = RateLimitGate.record_secondary(60)
    assert {:gated, ms} = RateLimitGate.gated?()
    assert ms > 50_000 and ms <= 60_000
  end

  test "primary signal gates until resetAt" do
    future = DateTime.utc_now() |> DateTime.add(30, :second) |> DateTime.to_iso8601()
    :ok = RateLimitGate.record_primary(future)
    assert {:gated, _} = RateLimitGate.gated?()
  end

  test "longer of two signals wins (max gate)" do
    :ok = RateLimitGate.record_secondary(10)
    far_future = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601()
    :ok = RateLimitGate.record_primary(far_future)
    assert {:gated, ms} = RateLimitGate.gated?()
    assert ms > 200_000
  end

  test "clear resets gate" do
    :ok = RateLimitGate.record_secondary(60)
    RateLimitGate.clear()
    assert :open = RateLimitGate.gated?()
  end

  # Coverage gates ----------------------------------------------------

  test "record_primary(nil) is a no-op" do
    assert :ok = RateLimitGate.record_primary(nil)
    assert :open = RateLimitGate.gated?()
  end

  test "record_primary with malformed ISO is a no-op" do
    assert :ok = RateLimitGate.record_primary("not-an-iso-timestamp")
    assert :open = RateLimitGate.gated?()
  end

  test "record_primary in the past does not gate" do
    past = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.to_iso8601()
    assert :ok = RateLimitGate.record_primary(past)
    assert :open = RateLimitGate.gated?()
  end
end
