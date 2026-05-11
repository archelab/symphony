defmodule SymphonyElixir.ObservabilityPubSubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.ObservabilityPubSub

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    # Use a unique, unregistered PubSub name so we exercise the no-op branch
    # without touching the global SymphonyElixir.PubSub registry. Terminating
    # the global PubSub child would race with other test modules running in
    # parallel (mix test_strict max_cases=8) that call subscribe/broadcast,
    # causing `ArgumentError: unknown registry: SymphonyElixir.PubSub` and
    # cascading supervisor failures.
    missing_pubsub = :"missing_pubsub_#{System.unique_integer([:positive])}"

    refute Process.whereis(missing_pubsub)

    assert :ok = ObservabilityPubSub.broadcast_update(missing_pubsub)
  end
end
