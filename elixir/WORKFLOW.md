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
  session_summary:
    enabled: false
codex:
  command: codex --search --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=medium app-server
  model: "gpt-5.5"
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
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

- `gh` CLI is on PATH and authenticated via `$GH_TOKEN` and `$GITHUB_TOKEN`.{% if issue.repository %} The default repo is **{{ issue.repository.name_with_owner }}**.{% endif %}
- Run shell commands directly from this prepared environment; do not prefix
  commands with `source ~/.zshrc`.
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
When opening the PR, include an official closing/linking keyword in the PR body
so GitHub links the PR to this issue, for example: `Closes #{{ issue.number }}`.
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

## Status-transition rituals

You only ever flip the Project Status. Before doing so, ALWAYS execute the
ritual for the destination state. Do not flip Status first.

### Status → Blocked

When you decide you cannot continue (missing auth / permissions / scope,
mutation not allowlisted, sandbox refusing a path, dependency missing on
the host, etc.):

1. Post a NEW issue comment headed `## Blocker report` containing:
   - **What I tried** — the operations you attempted, in order.
   - **What failed** — exact error messages, verbatim.
   - **Suggested operator action** — what changes would unblock you
     (allowlist additions, scope changes, missing secrets, sandbox
     policy adjustment, etc.).
2. Close your workpad row: set Ended, Duration, and Stop reason; archive
   your Current-session body under a `### Session {{ thread_id }} notes`
   heading.
3. THEN flip Status to Blocked via `updateProjectV2ItemFieldValue`.

### Status → In Review

When the work is ready for a human:

1. Decide whether the reviewer needs context beyond what the PR diff and
   commit messages already make obvious. Things that warrant a comment:
   non-obvious decisions, deferred work, partial test coverage, areas
   you want the reviewer to scrutinize, known caveats, things you would
   have done differently with more time. Things that do NOT warrant a
   comment: a routine refactor or bugfix that reads cleanly from the
   diff. Use your own judgment.
2. IF you decided yes, post a NEW issue comment headed `## Reviewer notes`
   as a short bulleted list. Be terse; the reviewer values signal over
   volume.
3. Close your workpad row (same as Blocked).
4. THEN flip Status to In Review.

### Status → Done (existing)

1. Close your workpad row.
2. Flip Status to Done.

Note: the workpad is the default visible state. The Blocker report and
Reviewer notes above are SEPARATE comments, intentional human-facing prose,
posted by you while you're still alive — the orchestrator may SIGTERM you the
moment Status goes inactive, so writing them after the Status flip is too late.

## Stopping conditions

This is an unattended orchestration session. Stop early only for:
- missing required auth/permissions/secrets
- the item entering a terminal state mid-run
- explicit handoff to a human (move Status to "In Review" or "Blocked")
