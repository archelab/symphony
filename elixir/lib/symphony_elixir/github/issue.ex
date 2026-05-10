defmodule SymphonyElixir.Github.Issue do
  @moduledoc """
  Normalized GitHub issue/PR/draft-issue record. Spec §4.1.1.
  """

  defmodule Repository do
    @moduledoc false
    @enforce_keys [:owner, :name, :name_with_owner]
    defstruct [:owner, :name, :name_with_owner, :default_branch]

    @type t :: %__MODULE__{
            owner: String.t(),
            name: String.t(),
            name_with_owner: String.t(),
            default_branch: String.t() | nil
          }
  end

  defmodule Blocker do
    @moduledoc false
    defstruct [:id, :identifier, :state]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            identifier: String.t() | nil,
            state: String.t() | nil
          }
  end

  defmodule PR do
    @moduledoc """
    Tier 1 PR fields (spec §4.1.1). Tier 2 fields land in Phase 2.
    """
    defstruct [
      :state,
      :merged,
      :merged_at,
      :closed_at,
      :is_draft,
      :base_ref_name
    ]

    @type t :: %__MODULE__{
            state: String.t(),
            merged: boolean(),
            merged_at: String.t() | nil,
            closed_at: String.t() | nil,
            is_draft: boolean(),
            base_ref_name: String.t()
          }
  end

  defstruct [
    :id,
    :identifier,
    :kind,
    :title,
    :description,
    :priority,
    :state,
    :repository,
    :number,
    :branch_name,
    :url,
    :labels,
    :blocked_by,
    :pr,
    :issue_state,
    :created_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          identifier: String.t(),
          kind: String.t(),
          title: String.t(),
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t(),
          repository: Repository.t() | nil,
          number: integer() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          labels: [String.t()],
          blocked_by: [Blocker.t()],
          pr: PR.t() | nil,
          issue_state: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: Map.fetch!(attrs, :id),
      identifier: Map.fetch!(attrs, :identifier),
      kind: Map.fetch!(attrs, :kind),
      title: Map.get(attrs, :title, ""),
      description: Map.get(attrs, :description),
      priority: Map.get(attrs, :priority),
      state: Map.fetch!(attrs, :state),
      repository: build_repository(Map.get(attrs, :repository)),
      number: Map.get(attrs, :number),
      branch_name: Map.get(attrs, :branch_name),
      url: Map.get(attrs, :url),
      labels: Map.get(attrs, :labels, []),
      blocked_by: Enum.map(Map.get(attrs, :blocked_by, []), &build_blocker/1),
      pr: build_pr(Map.get(attrs, :pr)),
      issue_state: Map.get(attrs, :issue_state),
      created_at: Map.get(attrs, :created_at),
      updated_at: Map.get(attrs, :updated_at)
    }
  end

  defp build_repository(nil), do: nil
  defp build_repository(%Repository{} = repo), do: repo
  defp build_repository(%{} = m), do: struct!(Repository, m)

  defp build_blocker(%Blocker{} = b), do: b
  defp build_blocker(%{} = m), do: struct!(Blocker, m)

  defp build_pr(nil), do: nil
  defp build_pr(%PR{} = pr), do: pr
  defp build_pr(%{} = m), do: struct!(PR, m)
end
