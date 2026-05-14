defmodule SymphonyElixir.Observability.NotificationsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Observability.Notifications

  test "broadcast_update notifies subscribers when pubsub is running" do
    assert :ok = Notifications.subscribe()
    assert :ok = Notifications.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    missing_pubsub = :"missing_pubsub_#{System.unique_integer([:positive])}"

    refute Process.whereis(missing_pubsub)

    assert :ok = Notifications.broadcast_update(missing_pubsub)
  end
end
