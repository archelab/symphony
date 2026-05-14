defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  Compatibility wrapper for observability dashboard updates.
  """

  alias SymphonyElixir.Observability.Notifications

  @spec subscribe(atom()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(pubsub \\ SymphonyElixir.PubSub), do: Notifications.subscribe(pubsub)

  @spec broadcast_update(atom()) :: :ok | {:error, term()}
  def broadcast_update(pubsub \\ SymphonyElixir.PubSub), do: Notifications.broadcast_update(pubsub)
end
