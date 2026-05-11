---
tracker:
  kind: github
  api_token: $GITHUB_TOKEN
  owner: archelab
  owner_type: organization
  project_number: 1
  repo: symphony
  status_field: Status
  include_kinds: [issue, pull_request, draft_issue]
  active_states: ["Agent Ready", "In Progress", "Rework"]
  terminal_states: ["Done"]
  dependency_gating_states: ["Agent Ready"]
  cross_repo_blockers: false
  gate_running_on_dependencies: true
polling:
  interval_ms: 5000
workspace:
  root: /tmp/symphony-smoke-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/archelab/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 3
  max_turns: 1
  # SPEC §11.8.9 (PR4 amendment): the schema default for
  # `agent.workpad.enabled` is `true`. The smoke harness explicitly opts out
  # so e2e-1..e2e-9 keep behaving as pre-PR4 (no workpad bridge, no
  # `codex.model` requirement, no §11.8.9 template validation). e2e-10's
  # awk transform flips this single line back to `true` for its workpad
  # round-trip case.
  workpad:
    enabled: false
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.4-mini"' --config model_reasoning_effort=minimal app-server
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

## Smoke-test mode

This Symphony orchestrator is running in **e2e smoke-test mode**. Do exactly
one thing and stop:

- If the issue body contains explicit AGENT INSTRUCTIONS, follow them precisely.
- Otherwise, do not make code changes. Print "ack smoke" and end the turn.

Do not push code, do not create PRs, and do not move Status unless explicitly told.

## Stopping conditions

- missing required auth/permissions/secrets
- the item entering a terminal state mid-run
- explicit handoff to a human (move Status to "In Review" or "Blocked")
