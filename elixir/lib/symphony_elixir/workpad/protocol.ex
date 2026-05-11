defmodule SymphonyElixir.Workpad.Protocol do
  @moduledoc """
  Agent Workpad Protocol constants (SPEC §11.8).
  Single source of truth for marker strings, supported versions, and protocol defaults.
  """

  @supported_versions ~w(v1)
  @default_version "v1"
  @default_max_sessions_visible 20
  @default_update_throttle_turns 3

  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @spec default_version() :: String.t()
  def default_version, do: @default_version

  @spec default_max_sessions_visible() :: 20
  def default_max_sessions_visible, do: @default_max_sessions_visible

  @spec default_update_throttle_turns() :: 3
  def default_update_throttle_turns, do: @default_update_throttle_turns

  @doc "Opening HTML-comment marker for a given protocol version (SPEC §11.8.1)."
  @spec marker_open(String.t()) :: String.t()
  def marker_open(version) when is_binary(version), do: "<!-- symphony-workpad:#{version} -->"

  @doc "Closing HTML-comment marker for a given protocol version (SPEC §11.8.1)."
  @spec marker_close(String.t()) :: String.t()
  def marker_close(version) when is_binary(version), do: "<!-- /symphony-workpad:#{version} -->"

  @doc "True iff the given version string is in the supported set."
  @spec supported?(String.t()) :: boolean()
  def supported?(version) when is_binary(version), do: version in @supported_versions
  def supported?(_), do: false
end
