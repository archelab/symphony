defmodule SymphonyElixir.Workpad.Protocol do
  @moduledoc """
  Agent Workpad Protocol constants (SPEC §11.8).
  Single source of truth for marker strings, supported versions, and protocol defaults.
  """

  @supported_versions ~w(v1)
  @default_version "v1"
  @default_max_sessions_visible 20
  @default_update_throttle_turns 3

  # SPEC §11.8.5 / §11.8.9 — the five Liquid variables the orchestrator MUST
  # emit when the workpad protocol is active, and that a workpad-enabled
  # workflow template MUST reference at least one of. Single source of truth:
  # `PromptBuilder` reads this list to emit the prompt context map, and
  # `Workflow.load/1` reads it to validate the operator's prompt template
  # references the protocol bridge before booting.
  @prompt_variables ~w(thread_id subject_id prior_sessions dispatched_at model)

  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc """
  Canonical list of Liquid variable names the workpad protocol exposes to the
  workflow prompt template (SPEC §11.8.5 / §11.8.9). Shared between
  `SymphonyElixir.PromptBuilder` (emission) and `SymphonyElixir.Workflow`
  (template validation).
  """
  @spec prompt_variables() :: [String.t()]
  def prompt_variables, do: @prompt_variables

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
