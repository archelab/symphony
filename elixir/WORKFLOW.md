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
  workpad:
    enabled: true
    version: v1
    max_sessions_visible: 20
    update_throttle_turns: 3
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  model: "gpt-5.5"
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on GitHub item `{{ issue.identifier }}` in project Symphony.

{% if attempt %}
## Continuation context

This is dispatch attempt #{{ attempt }}.{% if last_run_completed_at %} Prior session ended at {{ last_run_completed_at }}.{% endif %}

BEFORE touching code:
1. `gh issue view {{ issue.number }} --repo {{ issue.repository.name_with_owner }} --comments` and read every comment posted after {{ last_run_completed_at }}.
2. {% if issue.kind == "pull_request" %}`gh pr view {{ issue.number }} --repo {{ issue.repository.name_with_owner }} --json reviews,reviewThreads` and resolve every unresolved thread.{% endif %}
3. Summarize the requested changes in your workpad comment before editing.
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

<!-- The markers below MUST stay in lock-step with SymphonyElixir.Workpad.Protocol.marker_open/marker_close. -->

## Agent Workpad Protocol (SPEC §11.8)

You have a cross-session workpad — a single GitHub Issue/PullRequest comment
identified by an HTML marker. Manage it via the `github_graphql` tool.

**Find or create the workpad:**

1. Query comments on the underlying {{ issue.kind }} (subject_id `{{ subject_id }}`),
   paginating with `comments(first: 100, after: $cursor)` until you find a comment
   whose trimmed body starts with `<!-- symphony-workpad:v1 -->` OR `pageInfo.hasNextPage`
   is false.
2. If no match: post a new workpad with `addComment(input: { subjectId: "{{ subject_id }}", body: $body })`.
3. If exactly one match: capture its node id and use `updateIssueComment(input: { id: $node_id, body: $body })`.
4. If multiple matches: operate on the newest by `(createdAt DESC, databaseId DESC)`.

The comment body MUST begin with `<!-- symphony-workpad:v1 -->` and end with
`<!-- /symphony-workpad:v1 -->` so future dispatches can find it.

**On first turn, append your row to the sessions table:**

| `{{ thread_id }}` | {{ attempt }} | {{ dispatched_at }} | — | — | {{ model }} | — |

{% if prior_sessions %}
**Prior sessions** (most recent first; orchestrator-authoritative — do not invent values):

{% for s in prior_sessions %}
- `{{ s.thread_id }}` attempt={{ s.attempt }} dispatched={{ s.dispatched_at }} completed={{ s.completed_at }} duration_ms={{ s.duration_ms }} model={{ s.model }} stop_reason={{ s.stop_reason }}
{% endfor %}
{% endif %}

On voluntary final-turn completion: update your row's Ended/Duration/Stop reason
(use `agent_exit_normal` unless you know otherwise) AND archive your "Current session"
body under a `### Session {{ thread_id }} notes` heading.

**Rate-limit handling (SPEC §11.8.6):** the workpad is best-effort. If `addComment` or
`updateIssueComment` returns a secondary-throttle `Retry-After` header, honour it and
SKIP the workpad write for the current turn rather than retrying in a tight loop. On
primary-quota exhaustion (`rateLimit.resetAt`), wait for reset before the next attempt.
The orchestrator's §13.1 structured logs remain the authoritative session record while
the workpad is unwritable.

## Stopping conditions

This is an unattended orchestration session. Stop early only for:
- missing required auth/permissions/secrets
- the item entering a terminal state mid-run
- explicit handoff to a human (move Status to "In Review" or "Blocked")
