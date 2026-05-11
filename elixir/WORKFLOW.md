---
tracker:
  kind: github
  api_token: $GITHUB_TOKEN
  owner: archelab
  owner_type: organization
  project_number: 1
  repo: symphony
  status_field: Status
  include_kinds: [issue, pull_request]
  active_states: ["Agent Ready", "In Progress", "Rework"]
  terminal_states: ["Done"]
  dependency_gating_states: ["Agent Ready"]
  cross_repo_blockers: false
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/archelab/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 4
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on GitHub item `{{ issue.identifier }}` in project Symphony.

{% if attempt %}
## Continuation context

This is dispatch attempt #{{ attempt }}.{% if last_run_completed_at %} Prior session ended at {{ last_run_completed_at }}.{% endif %}
Resume from the existing workspace state. Do not redo investigation
unnecessarily. Read the latest tracker feedback before changing code.
{% endif %}

## Item context

- Identifier: {{ issue.identifier }}
- Kind: {{ issue.kind }}
- Title: {{ issue.title }}
- Current Project Status: {{ issue.state }}
- Labels: {{ issue.labels | join: ", " }}
- URL: {{ issue.url }}
{% if issue.kind == "pull_request" %}
- PR state: {{ issue.pr.state }} (merged={{ issue.pr.merged }}, draft={{ issue.pr.is_draft }})
- Base branch: {{ issue.pr.base_ref_name }}
- Head branch: {{ issue.branch_name }}
{% endif %}

## Description

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Tools available

- `gh` CLI is on PATH and authenticated via `$GITHUB_TOKEN`.{% if issue.repository %} The default repo is **{{ issue.repository.name_with_owner }}**.{% endif %}
- The `github_graphql` tool is registered in this Codex session for tracker
  reads/writes that need raw GraphQL.

## Reading feedback

{% if issue.kind == "pull_request" %}
- Read PR conversation and review comments:
  `gh pr view {{ issue.number }} -R {{ issue.repository.name_with_owner }} --comments`
- Read unresolved review threads via `github_graphql`:
  ```
  query { repository(owner:"{{ issue.repository.owner }}", name:"{{ issue.repository.name }}") {
    pullRequest(number: {{ issue.number }}) {
      reviewThreads(first:50) { nodes { isResolved isOutdated comments(first:20) { nodes { body path line author { login } } } } }
    }
  } }
  ```
{% elsif issue.kind == "issue" %}
- Read issue conversation:
  `gh issue view {{ issue.number }} -R {{ issue.repository.name_with_owner }} --comments`
{% else %}
- Draft Issues have no GitHub conversation. The Project item description
  ({{ issue.description | default: "(empty)" }}) is the only context;
  promote the draft before requesting more.
{% endif %}

## Writing tracker updates

Use `gh issue comment`, `gh pr comment`, `gh pr review`, or the
`github_graphql` tool. To move this item to a new Status option, use the
`updateProjectV2ItemFieldValue` mutation; the project + status field IDs
are pre-resolved by Symphony but you can re-derive them via
`gh project field-list 1 --owner archelab`.

## Branch policy (derived from GitHub, not hardcoded)

{% if issue.kind == "pull_request" %}
Do NOT push directly to `{{ issue.pr.base_ref_name }}`. Update via the PR
head branch `{{ issue.branch_name }}` and open additional commits on it.
{% elsif issue.kind == "draft_issue" %}
This is a Draft Issue — project-only, with no GitHub repository attached
yet. Before any code work, promote it to a real Issue (or create one in
the appropriate repository), then continue against that repo's default
branch. The `github_graphql` tool's `convertProjectV2DraftIssueItemToIssue`
mutation handles the promotion; ask which repository to target if the
project does not make it obvious.
{% else %}
Open work on a feature branch and submit a Pull Request against
`{{ issue.repository.default_branch }}`. Do not commit to
`{{ issue.repository.default_branch }}` directly.
{% endif %}

Both `pr.base_ref_name` and `repository.default_branch` come straight from
GitHub via the candidate query, so this guidance updates automatically if
the protected branch changes upstream.

## Stopping conditions

This is an unattended orchestration session. Stop early only for:
- missing required auth/permissions/secrets
- the item entering a terminal state mid-run
- explicit handoff to a human (move Status to "In Review" or "Blocked")
