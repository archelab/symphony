defmodule SymphonyElixir.Observability.Notifications do
  @moduledoc """
  Runtime observability notifications shared by terminal and web observers.
  """

  @default_pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated

  @spec subscribe(atom()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(pubsub \\ @default_pubsub) do
    Phoenix.PubSub.subscribe(pubsub, @topic)
  end

  @spec broadcast_update(atom()) :: :ok | {:error, term()}
  def broadcast_update(pubsub \\ @default_pubsub) do
    case Process.whereis(pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end
end
