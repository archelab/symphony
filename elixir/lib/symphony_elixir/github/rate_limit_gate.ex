defmodule SymphonyElixir.Github.RateLimitGate do
  @moduledoc """
  In-process gate that records GitHub rate-limit signals and short-circuits
  subsequent calls until the gate clears. Spec §11.2 / §11.4.
  """

  @key {__MODULE__, :until_ms}

  @spec record_secondary(non_neg_integer()) :: :ok
  def record_secondary(retry_after_seconds) when is_integer(retry_after_seconds) do
    until = System.monotonic_time(:millisecond) + retry_after_seconds * 1_000
    update_gate(until)
  end

  @spec record_primary(String.t() | nil) :: :ok
  def record_primary(nil), do: :ok

  def record_primary(reset_at_iso) when is_binary(reset_at_iso) do
    case DateTime.from_iso8601(reset_at_iso) do
      {:ok, dt, _} ->
        delta_ms = max(0, DateTime.diff(dt, DateTime.utc_now(), :millisecond))
        until = System.monotonic_time(:millisecond) + delta_ms
        update_gate(until)

      _ ->
        :ok
    end
  end

  @spec gated?() :: {:gated, non_neg_integer()} | :open
  def gated? do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@key, :open) do
      until when is_integer(until) and until > now -> {:gated, until - now}
      _ -> :open
    end
  end

  @spec clear() :: :ok
  def clear do
    :persistent_term.put(@key, :open)
    :ok
  end

  defp update_gate(until) do
    case :persistent_term.get(@key, :open) do
      current when is_integer(current) ->
        :persistent_term.put(@key, max(current, until))

      _ ->
        :persistent_term.put(@key, until)
    end

    :ok
  end
end
