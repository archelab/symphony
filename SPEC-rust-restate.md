# Symphony Service Specification — Rust + Restate Edition

Status: Draft v1 (Rust + Restate + Codex target)

Purpose: Define a Rust implementation of Symphony built on Restate (Virtual Objects, Workflows,
Services, awakeables, durable promises, durable timers) that orchestrates Codex coding-agent
sessions across many tenants, supports long-horizon workflows, achieves audit-grade durability,
and treats human-in-the-loop interaction as a first-class concern.

This specification is **self-contained**: an engineer reading only this document MUST have
enough information to implement Symphony. It is a parallel/alternative specification to the
language-agnostic edition; this edition pins the runtime language to Rust and the durable
execution substrate to Restate.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this
specification does not prescribe one universal policy. Implementations MUST document the
selected behavior.

## 1. Problem Statement

Symphony is a long-running automation service that orchestrates Codex coding-agent sessions
against work tracked in GitHub Projects v2. One Symphony deployment serves **many tenants**
(organizations, projects, or product lines), supports **long-horizon workflows** spanning
hours or days (decompose epic → file sub-issues → execute sub-issues in parallel → integration
test → human handoff), produces an **audit-grade durable journal** of every retry, every tool
call, and every state transition, and treats **human-in-the-loop** (pause/resume, approvals,
multi-step gating) as a first-class durable construct rather than a best-effort in-memory
feature.

The four headline goals are reflected throughout this specification:

- **Multi-tenant** (Section 15): one Symphony cluster serves N tenants, each with their own
  GitHub Project v2, GitHub App installation, status field configuration, concurrency caps, and
  audit boundary. Per-tenant resource isolation is enforced via key-prefixed Restate Virtual
  Objects on a shared cluster, or per-tenant clusters when hard isolation is required.

- **Long-horizon workflows** (Section 16): an `Epic` Restate Workflow decomposes a parent issue
  into sub-issues, fans out `IssueAgent.dispatch` invocations, gathers their outcomes, runs
  integration tests, and waits on a durable `handoff` promise that a human resolves via the
  comment control plane (Appendix B) or Restate's awakeable HTTP endpoint. The workflow
  survives restart, redeploys, and weeks of wall-clock time.

- **Audit-grade durability** (Section 12): every `ctx.run` step in every handler is journaled
  with timestamps, inputs, outputs, and retry counts. Operators query the journal via
  `restate sql` and `restate invocations describe`. Every Codex `dynamicToolCall` is a
  separate journal entry keyed by `call_id`, so the audit trail captures exactly which tool
  the agent invoked, when, with what arguments, and what the result was.

- **Heavy human-in-the-loop** (Sections 7, 16, Appendix B): pause/resume is implemented via
  `ctx.awakeable()` — when an issue is paused, the dispatch loop suspends on the awakeable at
  zero compute cost and resumes when an operator (or a workflow command) resolves it.
  Multi-step approvals are chained durable promises. None of this state is lost on
  orchestrator restart.

The tracker model in this specification version treats GitHub Issues, Pull Requests, and
GitHub Projects v2 items that point to either as the primary unit of work. Symphony reads each
tenant's configured GitHub Project v2 (via webhooks first, polling as a safety net),
normalizes its items into a stable Issue model (Section 4), and runs Codex sessions for items
whose project Status is in the configured active states.

The service solves four operational problems:

- It turns issue execution into a repeatable, durable workflow instead of manual scripts.
- It isolates Codex execution in per-issue workspaces so agent commands run only inside
  per-issue workspace directories, with the workspace path stored in the
  `IssueAgent` Virtual Object's state.
- It keeps the workflow policy in-repo (`WORKFLOW.md`) so teams version the agent prompt and
  runtime settings with their code.
- It provides operator-grade observability through Restate's Admin UI, SQL surface, and
  invocation journal.

Important boundary:

- Symphony is a Codex orchestrator and tracker reader.
- Issue and Pull Request writes (Status field updates, comments, labels, PR linkage,
  sub-issue filing) are typically performed by Codex itself using the `github_graphql`
  client-side tool (Section 10).
- A successful run can end at a workflow-defined handoff state (for example `Human Review`),
  not necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Serve many tenants from one Symphony deployment with per-tenant GitHub App installations,
  status field configuration, and concurrency caps.
- Support long-horizon workflows (hours, days, weeks) via Restate Workflows with durable
  promises, awakeables, and `ctx.sleep(...)` timers that survive restart.
- Produce an audit-grade journal of every state transition, retry, tool call, and approval,
  queryable via `restate sql` against `sys_invocation`, `sys_journal`, and `sys_state`.
- Treat human-in-the-loop pause/resume and multi-step approvals as first-class durable
  primitives, not best-effort in-memory state.
- Drive dispatch by GitHub webhooks (Appendix A) with periodic polling reconciliation as a
  safety net, both implemented as Restate Virtual Objects.
- Maintain a single authoritative orchestrator state per `(tenant, issue)` pair via
  Restate's exclusive-handler-per-key serialization for Virtual Objects (one exclusive
  handler runs at a time per key; shared handlers may run concurrently).
- Create deterministic per-tenant per-issue workspaces on a shared filesystem and preserve
  them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures via Restate's per-step retry policy with exponential
  backoff and durable timers.
- Load runtime behavior from a repository-owned `WORKFLOW.md` contract.
- Expose operator observability through Restate Admin and OPTIONAL Symphony-specific REST
  endpoints.
- Survive Symphony worker restart, Restate Server restart, and Symphony deployment
  redeploys without losing scheduled work, retry timers, paused issues, or in-flight
  Codex sessions.

### 2.2 Non-Goals

- Built-in business logic for how Codex edits Issues, Pull Requests, project items, or
  comments. (That logic lives in the workflow prompt and the `github_graphql` tool.)
- A general-purpose workflow engine. Restate is the workflow engine; Symphony is its tenant.
- Mandating a single approval, sandbox, or operator-confirmation posture for all
  implementations.
- A rich web UI. Operators use Restate's Admin UI, `restate sql`, and an OPTIONAL Symphony
  JSON snapshot endpoint. A custom Symphony dashboard is out of scope.
- SSH-based remote execution. Multi-host scaling in this version is via horizontally-scaled
  Symphony Rust workers behind a load balancer with shared filesystem; not via SSH workers.
- Non-Codex coding agents are explicitly out of scope. Codex is the only agent runtime
  supported by this specification.
- Hard tenant isolation on a shared Restate cluster. Soft tenant isolation (key-prefixed
  Virtual Objects, per-tenant credentials, per-tenant audit views) is supported on a shared
  cluster; hard isolation requires per-tenant clusters (Section 15.4).

## 3. System Overview

### 3.1 Architecture Diagram

```
                       ┌──────────────────────────────────────────────────┐
                       │        Restate Server (HA Raft cluster)          │
                       │  Admin :9070   Ingress :8080                     │
                       │  Durable journal (RocksDB or Postgres)           │
                       │  Virtual Object state, awakeables, promises,     │
                       │    durable timers, sys_invocation/sys_journal    │
                       └──────────────────────────────────────────────────┘
                          ▲ HTTP/2 service registration & invocation
                          │
                          │ HTTP/2 ingress (webhooks)
                          ▲
┌─────────────────────────┴────────────────────────────────────────────────┐
│                  Symphony Rust application (stateless)                   │
│                                                                          │
│   restate-sdk handlers exposed over HTTP/2 on :9080                      │
│                                                                          │
│   ┌────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐      │
│   │  Tenant    │ │ IssueAgent   │ │ SymphonyCron │ │ ReconcileCron│ VO   │
│   └────────────┘ └──────────────┘ └──────────────┘ └──────────────┘      │
│                                                                          │
│   ┌────────────┐ ┌──────────────────┐                                    │
│   │   Epic     │ │ ApprovalWorkflow │   Workflows                        │
│   └────────────┘ └──────────────────┘                                    │
│                                                                          │
│   ┌────────────────┐ ┌──────────────┐ ┌────────────┐ ┌────────────────┐  │
│   │WebhookReceiver │ │ CommentRouter│ │GitHubAdapter│ │ AgentRuntime   │  │
│   └────────────────┘ └──────────────┘ └────────────┘ └────────────────┘  │
│                                                                          │
│                Stateless services (no per-key serialization)             │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ tokio::process::Command (per-turn)
                               ▼
                ┌──────────────────────────────────┐
                │  codex app-server  (per turn,    │
                │    spawned and torn down)        │
                │                                  │
                │  thread state in JSONL on disk   │
                │  workspace cwd in shared FS      │
                └──────────────────────────────────┘

   Shared filesystem (NFS/EFS or equivalent):
     /<root>/<tenant_id>/workspaces/<workspace_key>/
     /<root>/<tenant_id>/threads/<thread_id>.jsonl
```

### 3.2 Main Components

The Symphony Rust application is a single stateless process exposing Restate handlers over
HTTP/2. All durable state lives in Restate Server. Components below are Restate
**Services**, **Virtual Objects** (exclusive-handler-per-key serialization: at most one
exclusive handler executes at a time per key, while shared handlers may run
concurrently), or **Workflows** (exactly-once per workflow ID; the `run` handler executes
at most once successfully per ID).

1. `Tenant` (Virtual Object, key = `tenant_id`)
   - Per-tenant configuration (resolved `WORKFLOW.md` plus environment-bound credentials).
   - GitHub App installation ID, project resolution metadata, status field, active/terminal
     states, dependency-gating states, concurrency caps, webhook secret reference, comment
     control plane configuration.
   - Handlers: `init(ConfigReq)`, `config()` (shared), `update_config(ConfigReq)`,
     `rotate_app_token()`.

2. `IssueAgent` (Virtual Object, key = `<tenant_id>:<issue_node_id>`)
   - Per-issue dispatch authority. Replaces the language-agnostic spec's in-memory
     `Unclaimed | Claimed | Running | RetryQueued | Released` enum with the implicit "is
     there a non-terminal `dispatch` invocation for this VO?".
   - State: `workspace_path`, `codex_thread_id`, `turn_count`, `last_event`,
     `pause_awakeable_id`, `pause_reason`, `current_attempt`.
   - Handlers: `dispatch(DispatchReq)`, `pause(reason)`, `resume()`, `stop()`,
     `status()` (shared).

3. `SymphonyCron` (Virtual Object, key = `tenant_id`)
   - Self-rescheduling polling cron. Schedules the next tick **before** doing work to remain
     crash-safe.
   - State: `cron_slot_state`, `last_run_at`, `next_invocation_id`, `last_run_summary`.
   - Handlers: `init()`, `tick()`, `cancel()`, `info()` (shared).

4. `ReconcileCron` (Virtual Object, key = `tenant_id`)
   - Self-rescheduling reconciliation cron. Independent failure domain from `SymphonyCron`
     so that polling drift in one does not block reconciliation in the other.
   - Handlers mirror `SymphonyCron`.

5. `Epic` (Workflow, key = `<tenant_id>:<epic_issue_node_id>`)
   - The canonical long-horizon workflow. Decompose → fan-out sub-issues → integration test
     → handoff. Days or weeks long. See Section 16.

6. `ApprovalWorkflow` (Workflow, key = `<tenant_id>:<request_id>`)
   - Multi-step durable approvals chained via named `ctx.promise::<T>(name)` keys with
     timeouts via `ctx.sleep`.

7. `WebhookReceiver` (Service, stateless)
   - Verifies HMAC-SHA256 over the raw body, deduplicates by `X-GitHub-Delivery`, optional
     IP allowlist via `/meta`, routes events to `IssueAgent`, `SymphonyCron`, `Epic`, or
     `CommentRouter`.

8. `CommentRouter` (Service, stateless)
   - Parses `@<bot_login> retry|pause|resume|stop|status` commands, authorizes the comment
     author via `GET /repos/{owner}/{repo}/collaborators/{login}/permission`, dispatches to
     the relevant `IssueAgent` handler.

9. `GitHubAdapter` (Service, stateless)
   - Paginated GraphQL against Projects v2. Status field probe. Primary and secondary
     rate-limit handling. GitHub App installation token minting.

10. `AgentRuntime` (Service, stateless)
    - Driver-agnostic interface around Codex. The driver is invoked **per tool call** from
      `IssueAgent.dispatch` via `ctx.run(...).name("tool:<call_id>")`. There is no long-lived
      Codex subprocess managed by this service.

### 3.3 Abstraction Levels

1. `Policy Layer` (repo-defined) — `WORKFLOW.md` prompt body and per-team rules.
2. `Configuration Layer` (per-tenant, in `Tenant` VO state).
3. `Coordination Layer` (Restate Virtual Objects: `IssueAgent`, `SymphonyCron`,
   `ReconcileCron`).
4. `Workflow Layer` (Restate Workflows: `Epic`, `ApprovalWorkflow`).
5. `Execution Layer` (Codex subprocess per turn + `ctx.run` per tool call + shared FS
   workspaces).
6. `Integration Layer` (`GitHubAdapter` service for GraphQL; `WebhookReceiver` for ingress).
7. `Observability Layer` (Restate Admin UI, `restate sql`, optional `/api/v1/state` REST).

### 3.4 External Dependencies

- Restate Server v1.4 or newer (any deployment topology — single node, HA Raft cluster, or
  Restate Cloud).
- Rust toolchain (stable, edition 2021 or newer).
- `restate-sdk` Rust crate v0.10 or newer.
- GitHub GraphQL API (`https://api.github.com/graphql` for SaaS, GHES at
  `https://<host>/api/graphql`).
- Per-tenant GitHub App installation (RECOMMENDED) or per-tenant fine-grained PAT
  (acceptable for single-tenant or low-volume deployments).
- Shared filesystem accessible to every Symphony Rust worker — for workspaces and Codex
  thread JSONL state. NFS, EFS, or any POSIX-compatible network filesystem qualifies.
- Codex CLI (`codex app-server`) installed and on `$PATH` of every Symphony worker host.
- Codex version pinned per deployment because `dynamicToolCall` is marked experimental in the
  Codex protocol.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

An `Issue` MAY be backed by:

- a GitHub Project v2 item whose underlying content is a GitHub Issue,
- a GitHub Project v2 item whose underlying content is a Pull Request,
- a GitHub Project v2 item whose underlying content is a Draft Issue.

Fields:

- `tenant_id` (string)
  - Identifier of the owning tenant. MUST appear as the prefix of every Restate VO/Workflow
    key for this issue.
- `id` (string)
  - Stable tracker-internal ID. For GitHub: the Project v2 item node ID (`PVTI_*`).
  - This MUST be the value used in the `IssueAgent` VO key as
    `<tenant_id>:<id>`.
- `identifier` (string)
  - Human-readable identifier used in logs, prompts, and workspace naming.
  - For GitHub Issues and Pull Requests: `<owner>/<repo>#<number>` (example:
    `openai/symphony#42`).
  - For Draft Issues: `draft:<short>` where `<short>` is the last 8 characters of the
    Project item node ID (example: `draft:AF6gQ123`).
- `kind` (string)
  - One of `issue`, `pull_request`, `draft_issue`. Normalized from the GraphQL
    `ProjectV2ItemType` enum (`ISSUE`, `PULL_REQUEST`, `DRAFT_ISSUE`).
- `title` (string)
- `description` (string or null) — Markdown body.
- `priority` (integer or null) — lower numbers sort first.
- `state` (string)
  - Effective project state from
    `fieldValueByName(name: <tenant.status_field>).name`. If unset, the sentinel
    `<no status>` (lowercased before comparison).
- `repository` (object or null)
  - Populated for `issue` and `pull_request`; null for `draft_issue`.
  - Fields: `owner`, `name`, `name_with_owner`.
- `number` (integer or null) — GitHub Issue or PR number.
- `branch_name` (string or null)
  - For `pull_request`: PR head branch (`headRefName`).
  - For `issue` and `draft_issue`: null by default. Implementations MAY populate a
    deterministic suggested branch name as an extension; if they do, it MUST be
    consistent across all normalization paths (Section 11.3).
- `url` (string or null)
- `labels` (list of strings) — lowercased; empty for `draft_issue`.
- `blocked_by` (list of blocker refs)
  - Each ref: `id`, `identifier`, `state` (`OPEN` or `CLOSED`), `repository.name_with_owner`.
  - Derived from `Issue.trackedIssues` for items whose underlying content is an Issue.
- `pr` (object or null) — populated only for `pull_request`. Fields:
  - `state` — `OPEN`, `CLOSED`, or `MERGED`.
  - `merged` (boolean), `merged_at`, `closed_at`, `is_draft`, `base_ref_name`.
  - `review_decision` — `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or `null`.
    `null` MUST NOT be coerced to `REVIEW_REQUIRED`.
  - `mergeable` — `MERGEABLE`, `CONFLICTING`, `UNKNOWN`.
  - `merge_state_status` — one of `BEHIND`, `BLOCKED`, `CLEAN`, `DIRTY`, `DRAFT`,
    `HAS_HOOKS`, `UNKNOWN`, `UNSTABLE`. Diagnostic.
  - `check_state` — `EXPECTED`, `ERROR`, `FAILURE`, `PENDING`, `SUCCESS`, or null.
  - `unresolved_review_threads` (integer) — count of `reviewThreads` with
    `isResolved == false && isOutdated == false`.
  - `latest_opinionated_reviews` (list, descending by `submitted_at`) — entries:
    `{state, author_login, submitted_at}` from
    `latestOpinionatedReviews(first: 50, writersOnly: true)`.
  - `requested_reviewers` (list of strings) — `User.login`, `Team.slug`, or
    `Mannequin.login`, deduplicated.
- `issue_state` (string or null)
  - For `issue`: `OPEN` or `CLOSED`.
  - For `pull_request`: same as `pr.state`.
  - For `draft_issue`: null.
- `created_at` / `updated_at` (timestamp or null) — ISO-8601.

#### 4.1.2 Tenant Configuration

Per-tenant configuration record stored in `Tenant` VO state. Resolved from a
tenant-supplied `WORKFLOW.md` plus environment-bound credentials.

Fields:

- `tenant_id` (string)
- `display_name` (string)
- `github_app_installation_id` (integer, REQUIRED for GitHub App auth) **or**
  `github_pat_secret_ref` (string, name of an environment variable holding a fine-grained
  PAT).
- `project_id` or (`project_number` + `owner` + `owner_type`) — Section 5.3.1 semantics.
- `status_field` (string) — default `Status`.
- `priority_field` (string) — default `Priority`.
- `priority_mapping` (map) — default per Section 5.3.1.
- `include_kinds` — default `["issue", "pull_request"]`.
- `active_states` — default `["Todo", "In Progress"]`.
- `terminal_states` — default `["Done"]`.
- `dependency_gating_states` — default `["Todo"]`.
- `gate_running_on_dependencies` (boolean) — default `false`.
- `cross_repo_blockers` (boolean) — default `true`.
- `pr_dispatch_signals`, `pr_block_signals`, `pr_self_reviewer_logins` — Section 11.7.
- `max_concurrent_agents` (integer) — default `10`.
- `max_concurrent_agents_by_state` (map of state → positive int).
- `max_turns` (positive integer) — default `20`.
- `max_retry_backoff_ms` (integer) — default `300000` (5 minutes).
- `webhook_secret_ref` (string) — name of an environment variable holding the webhook
  HMAC secret.
- `comment_commands` (object) — Appendix B.
- `codex` (object) — Section 5.3.6.

#### 4.1.3 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map) — YAML front-matter root object.
- `prompt_template` (string) — Markdown body after front matter, trimmed.

#### 4.1.4 Workspace

Filesystem workspace assigned to one tenant + issue identifier pair.

Fields (logical):

- `tenant_id` (string)
- `path` (absolute workspace path on shared filesystem)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean) — used to gate `after_create` hook.

#### 4.1.5 Run Attempt

One execution attempt for one issue, materialized as a single `IssueAgent.dispatch`
invocation in Restate.

Fields (logical):

- `tenant_id`, `issue_id`, `issue_identifier`
- `attempt` (integer or null; null on first run, ≥1 on retries/continuation)
- `workspace_path`
- `codex_thread_id` (string or null)
- `started_at` (timestamp)
- `status` (`Running`, `Succeeded`, `Failed`, `TimedOut`, `Stalled`,
  `CanceledByReconciliation`, `Paused`)
- `error` (OPTIONAL string)

The Run Attempt is **identified** by the Restate invocation ID of the
`IssueAgent.dispatch` call. Operators query `restate invocations describe <id>` to see the
full journal.

#### 4.1.6 Codex Session Metadata

State tracked while a Codex subprocess is running for one turn.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string) — stable across turns within one run attempt.
- `turn_id` (string)
- `codex_app_server_pid` (integer or null)
- `last_codex_event` (enum string or null)
- `last_codex_timestamp` (timestamp or null)
- `last_codex_message` (string)
- `codex_input_tokens`, `codex_output_tokens`, `codex_total_tokens` (integers)
- `last_reported_input_tokens`, `last_reported_output_tokens`,
  `last_reported_total_tokens` (integers, deltas tracking).
- `turn_count` (integer)

This metadata is **journaled into the dispatch invocation** rather than stored as VO
state — each turn's session_started/turn_completed events are written via `ctx.run` and
become part of the audit trail.

#### 4.1.7 Tool Invocation Record

One Codex `dynamicToolCall` and its outcome. Materialized as a single `ctx.run` step keyed
`tool:<call_id>`.

Fields:

- `call_id` (string) — stable across replay; primary idempotency key.
- `tool_name` (string)
- `arguments` (JSON value)
- `result` (JSON value or error envelope)
- `duration_ms` (integer)

The `call_id` is provided by Codex as `item.id` in the `item/started` event for the tool
call. The implementation MUST use it verbatim as the `ctx.run` step name. See Section
10.3 for the journaling contract.

#### 4.1.8 Approval Record

One Codex `requestApproval` (command execution or file change) and its outcome.

Fields:

- `call_id` (string) — Codex-provided.
- `kind` (`command_execution` or `file_change`).
- `payload` (JSON value).
- `decision` (one of `accept`, `acceptForSession`, `decline`, `cancel`,
  `acceptWithExecpolicyAmendment`).
- `decided_by` (`auto:<policy>` or `operator:<login>` or `awakeable:<id>`).

Materialized as `ctx.run(...).name("approval:<call_id>")` in the dispatch journal.

#### 4.1.9 Pause Record

One pause acquired against an `IssueAgent`. Stored in VO state; durable across restart.

Fields:

- `awakeable_id` (string) — Restate awakeable handle.
- `reason` (string).
- `requested_by` (string).
- `requested_at` (timestamp).

### 4.2 Stable Identifiers and Normalization Rules

- `Tenant ID` — opaque string, unique within the Symphony deployment. Conventionally a slug
  like `acme-prod` or `openai-research`.
- `Restate VO Key` — `<tenant_id>:<resource_id>` for every per-tenant resource. The
  `tenant_id` MUST be the longest prefix up to the first `:`. This convention enables the
  multi-tenant audit query in Section 12.
- `Issue ID` — Project v2 item node ID (`PVTI_*`). Used as the suffix of the
  `IssueAgent` VO key.
- `Issue Identifier` — human-readable; used in logs, prompts, and workspace naming.
- `Workspace Key` — derive from `issue.identifier` by replacing any character not in
  `[A-Za-z0-9._-]` with `_`. Implementations MUST NOT use the canonical identifier directly
  as a path segment (`/` and `#` are not permitted in workspace directory names).
  - Examples: `openai/symphony#42` → `openai_symphony_42`,
    `myorg/my-repo#1234` → `myorg_my-repo_1234`,
    `draft:AF6gQ123` → `draft_AF6gQ123`.
- `Workspace Path` — `<shared_fs_root>/<tenant_id>/workspaces/<workspace_key>` (absolute,
  normalized).
- `Codex Thread JSONL Path` —
  `<shared_fs_root>/<tenant_id>/threads/<thread_id>.jsonl`.
- `Normalized Issue State` — compare states after `lowercase`.
- `Session ID` — `<thread_id>-<turn_id>`.
- `Tool Call Step Name` — `tool:<codex_call_id>` exactly. The `call_id` is Codex's
  `item.id` for the tool-call item.
- `Approval Step Name` — `approval:<codex_call_id>`.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Each tenant supplies a `WORKFLOW.md`. Symphony does not assume one global `WORKFLOW.md`
because the deployment is multi-tenant.

Per-tenant resolution:

1. Stored in tenant configuration (a `workflow_file_ref` field) that points to a file path,
   a Git URL + revision, or an inline Markdown blob.
2. The `Tenant.init` handler MUST fetch the workflow content, parse it (Section 5.2), and
   persist the parsed `config` and `prompt_template` into VO state.
3. `Tenant.update_config` re-runs the same parse/persist on every reload.

Loader behavior:

- If the file/blob cannot be read or parsed, return `missing_workflow_file` or
  `workflow_parse_error`. The `Tenant` VO refuses dispatch until the tenant's workflow is
  fixed.

Single-tenant local-development convenience: implementations MAY treat the absence of
explicit per-tenant `workflow_file_ref` configuration as a request to load
`./WORKFLOW.md` from the current working directory, mirroring the original Symphony
behavior. Production deployments MUST require per-tenant `workflow_file_ref` and SHOULD
reject CWD fallback at startup (e.g. via a `SYMPHONY_ALLOW_CWD_WORKFLOW_FALLBACK` env
flag that defaults to `false`).

### 5.2 File Format

`WORKFLOW.md` is a Markdown file with OPTIONAL YAML front matter.

Parsing rules:

- If file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config
  map.
- YAML front matter MUST decode to a map/object; non-map YAML is `workflow_front_matter_not_a_map`.
- Prompt body is trimmed before use.

### 5.3 Front Matter Schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`
- `restate` (new in this edition; see Section 5.3.7)

Unknown keys SHOULD be ignored for forward compatibility.

#### 5.3.1 `tracker` (object)

Same fields as the language-agnostic edition with one addition. The `tenant_id` is supplied
out-of-band to `Tenant.init`, not in the YAML.

Fields:

- `kind` — REQUIRED. Currently `github`.
- `endpoint` — default `https://api.github.com/graphql`. For GHES, set to
  `https://<host>/api/graphql`.
- `auth` (object, REQUIRED)
  - `mode` — one of `github_app` or `pat`.
  - For `github_app`: `installation_id` (positive integer) **or** `installation_id_ref`
    (env var name). The Symphony-side App credentials (App ID, private key) are deployment
    config, not tenant config; the tenant only declares which installation it owns.
  - For `pat`: `token_ref` (env var name; default `GITHUB_TOKEN`).
- `owner`, `owner_type`, `project_number`, `project_id`, `repo`, `status_field`,
  `priority_field`, `priority_mapping`, `include_kinds`, `active_states`,
  `terminal_states`, `dependency_gating_states`, `gate_running_on_dependencies`,
  `cross_repo_blockers`, `pr_dispatch_signals`, `pr_block_signals`,
  `pr_self_reviewer_logins` — semantics identical to the language-agnostic edition.

The `tracker.endpoint` and `tracker.auth` together select the credentials minted at runtime
by `GitHubAdapter.mint_installation_token` (Section 11) for App auth, or read from the
referenced env var for PAT auth.

#### 5.3.2 `polling` (object)

- `interval_ms` (integer) — default `30000`.
  - Translates into the wait between `SymphonyCron.tick` self-rescheduling. Changes
    apply on the next `tick` after `Tenant.update_config` is called.
- `reconcile_interval_ms` (integer) — default `60000`.
  - Drives `ReconcileCron.tick` cadence.

#### 5.3.3 `workspace` (object)

- `root_ref` (string) — name of an env var holding the absolute path to the **shared
  filesystem root**. Required. Symphony uses
  `<root>/<tenant_id>/workspaces/<workspace_key>` as the per-issue workspace path.
- `relative_root` (string, OPTIONAL) — additional path component appended to
  `<root>/<tenant_id>/workspaces/`. Useful for tenants that namespace by product line.

Notes:

- The shared filesystem MUST be writable from every Symphony worker. NFS, EFS, GCSFuse,
  Lustre, or any POSIX-compatible filesystem qualifies. See Section 9.6.
- `~` is expanded only inside `relative_root`, never inside `root_ref`'s resolved value.

#### 5.3.4 `hooks` (object)

Same fields as the language-agnostic edition: `after_create`, `before_run`, `after_run`,
`before_remove`, `timeout_ms` (default `60000`).

Hooks run as `bash -lc <script>` with `cwd = workspace_path` on whichever Symphony worker is
handling the current `IssueAgent.dispatch` invocation. The `ctx.run` step that invokes a
hook is named `hook:<name>:<turn>` so each hook execution is journaled separately.

Portability: `bash -lc` triggers the login-shell initialization sequence
(`/etc/profile`, `~/.bash_profile` / `~/.bash_login` / `~/.profile`, then `~/.bashrc`
through interactive paths), which is convenient for pulling in PATH and developer env
vars. Hosts where bash is not the login shell, where `~/.bashrc` is locked down, or
where the login-shell init sources `set -u`/`set -e` aggressively MAY require a
different invocation. RECOMMENDED alternatives:

- `bash -c <script>` (non-login, non-interactive) for hosts that pre-populate PATH
  for service users via systemd or container env.
- `sh -c <script>` for POSIX-only environments (the script body MUST then avoid
  bashisms).

Implementations MUST document which shell invocation they use. Per-tenant override is
implementation-defined.

Failure semantics:

- `after_create` failure: `TerminalError` (workspace creation aborts).
- `before_run` failure: `TerminalError` (dispatch attempt fails, retry per Restate policy
  applies).
- `after_run` failure: logged and ignored (the `ctx.run` step is wrapped to convert
  failures into a logged warning).
- `before_remove` failure: logged and ignored.

#### 5.3.5 `agent` (object)

- `max_concurrent_agents` (integer) — default `10`. Per-tenant concurrency cap; enforced
  via the per-tenant counter VO described in Section 15.3.
- `max_turns` (positive integer) — default `20`. Limit per `IssueAgent.dispatch`
  invocation.
- `max_retry_backoff_ms` (integer) — default `300000`. Maximum exponential backoff for
  Restate's `RunRetryPolicy` on transient errors. Translated into
  `RunRetryPolicy::default().exponentiation_factor(2.0).max_delay(...)`.
- `max_concurrent_agents_by_state` (map) — same as language-agnostic edition.

#### 5.3.6 `codex` (object)

- `command` (string) — default `codex app-server`. Launched via
  `tokio::process::Command::new("bash").arg("-lc").arg(&command)` with `cwd =
  workspace_path`.
- `approval_policy` (Codex `AskForApproval` value) — default
  implementation-defined; see Section 10.5.
- `thread_sandbox` (Codex `SandboxMode` value) — default implementation-defined.
- `turn_sandbox_policy` (Codex `SandboxPolicy` value) — default implementation-defined.
- `turn_timeout_ms` (integer) — default `3600000`.
- `read_timeout_ms` (integer) — default `5000`.
- `stall_timeout_ms` (integer) — default `300000`. If `<= 0`, stall detection is disabled.
- `version_pin` (string, RECOMMENDED) — exact Codex CLI version this workflow was tested
  with. The Symphony worker MUST log a warning if the running `codex --version` does not
  match `version_pin`. `dynamicToolCall` is experimental at the time of this specification
  and a Codex upgrade can break the contract.

For Codex-owned config values (`approval_policy`, `thread_sandbox`,
`turn_sandbox_policy`), supported values are defined by the targeted Codex app-server
version. To inspect the installed schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions
referenced by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`.

#### 5.3.7 `restate` (object) — Rust + Restate edition only

- `service_name` (string) — default `symphony`. Used as the Restate service registration
  name.
- `cron_jitter_ms` (integer) — default `1000`. Maximum jitter window (in milliseconds)
  added to each `SymphonyCron`/`ReconcileCron` self-reschedule to avoid thundering-herd
  ticks across many tenants. Jitter is **additive only** (`+jitter`, not `±jitter`):
  the next-tick delay is `polling.interval_ms + uniform_random(0..cron_jitter_ms)`.
  Implementations MUST NOT subtract jitter (which would produce sub-interval-ms
  scheduling and risk tight loops).
- `tool_run_retry_max_attempts` (integer) — default `5`. Maximum retries for a
  `ctx.run(...).name("tool:<call_id>")` step before surfacing as a non-terminal error to the
  agent's tool-result reply.
- `tool_run_retry_initial_delay_ms` (integer) — default `500`. Initial backoff for
  tool-run retries.
- `tool_run_retry_max_delay_ms` (integer) — default `30000` (30 seconds). Maximum
  backoff for tool-run retries.
- `awakeable_pause_ttl_ms` (integer or null) — default `null` (no TTL). When set, a
  pause that has not been resumed within this duration is auto-resolved with a
  `pause_ttl_expired` reason. `null` means the pause persists indefinitely.
- `epic_handoff_timeout_days` (integer) — default `7`. Default timeout for
  `Epic.handoff`. Workflows MAY override this per invocation.

### 5.4 Prompt Template Contract

The Markdown body of `WORKFLOW.md` is the per-issue prompt template. Rendered by a strict
Liquid-compatible engine.

Rendering requirements:

- Strict variable checking: unknown variables fail rendering.
- Strict filter checking: unknown filters fail rendering.

Template input variables:

- `issue` (object) — Section 4.1.1.
- `attempt` (integer or null) — null on first run, ≥1 on retries/continuation.
- `tenant` (object) — `{tenant_id, display_name}` (no credentials).

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime MAY use a minimal default prompt
  (`You are working on a GitHub issue.`).
- Workflow file read/parse failures are configuration errors and SHOULD NOT silently fall
  back to a prompt.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error`
- `template_render_error`
- `tenant_credentials_missing`
- `tenant_workflow_invalid`

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches **for that tenant** until fixed
  (other tenants are unaffected).
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

Per tenant:

1. `Tenant.init(ConfigReq)` is invoked with the workflow source (path, Git URL, or inline
   blob).
2. Symphony fetches the workflow content, parses YAML front matter into a raw config map.
3. Symphony applies built-in defaults for missing OPTIONAL fields.
4. Symphony resolves `*_ref` env-var indirection for credential and root-path fields. The
   resolved values are **never** persisted into VO state; only the `*_ref` names are.
5. Symphony coerces and validates typed values (Section 6.3).
6. The validated config (without resolved credentials) is persisted in `Tenant` VO state.

Symphony-deployment-level configuration (env vars, not in `WORKFLOW.md`):

- `SYMPHONY_RESTATE_INGRESS_URL` — Restate ingress URL for inbound calls (typically
  `http://restate-server:8080`).
- `SYMPHONY_BIND_ADDR` — `0.0.0.0:9080` by default.
- `SYMPHONY_SHARED_FS_ROOT` — required if any tenant references it via `workspace.root_ref`.
- `SYMPHONY_GITHUB_APP_ID`, `SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH` — for GitHub App auth.
- `SYMPHONY_LOG_FORMAT` — `json` (default) or `text`.

### 6.2 Dynamic Reload Semantics

- `Tenant.update_config(ConfigReq)` re-parses, re-validates, and writes the new config to
  VO state.
- After a successful reload, the next `SymphonyCron.tick` and `ReconcileCron.tick` for that
  tenant will use the new config.
- In-flight `IssueAgent.dispatch` invocations are NOT restarted automatically. They finish
  the current turn under the old config and pick up the new config on the next turn or the
  next dispatch.
- Invalid reloads MUST NOT mutate `Tenant` state — the previous valid config remains in
  effect, and `update_config` returns a `TerminalError`.

### 6.3 Dispatch Preflight Validation

Two validation surfaces with different cadences:

- **Startup / reload-only checks** run inside `Tenant.init` and
  `Tenant.update_config`. The status-field probe (`tracker.status_field` existence)
  belongs here — it is expensive (a GraphQL round-trip) and the field rarely changes.
- **Every-tick checks** run at the top of each `SymphonyCron.tick` to catch external
  drift (e.g. `installation_id` revoked, env-var-backed token wiped). These are local,
  inexpensive validations: presence of credentials, `tracker.kind == "github"`, basic
  config typing.

Validation checks (combined; each item below is annotated with its cadence):

- Workflow content can be loaded and parsed. (every tick — local)
- `tracker.kind` is present and supported (`github`). (every tick — local)
- `tracker.auth.mode` is one of `github_app` or `pat`. (every tick — local)
- For `github_app`: `installation_id` is resolvable. (every tick — local)
- For `pat`: `token_ref` env var is set and non-empty. (every tick — local)
- For `tracker.kind == "github"`:
  - At least one of `tracker.project_id` or `tracker.project_number` is present.
    (every tick — local)
  - When `tracker.project_number` is used, `tracker.owner` is present. (every tick —
    local)
  - `tracker.owner_type`, when set, is one of `organization` or `user`. (every
    tick — local)
  - `tracker.include_kinds`, when set, contains only `issue`, `pull_request`, or
    `draft_issue`. (every tick — local)
  - The implementation MUST probe the project for the configured `tracker.status_field`
    (Section 11.2.4) at startup and on reloads that change project identifier or
    status field. A missing field raises `tracker_status_field_missing`. (**startup /
    reload only** — does not run on every tick because it requires a GraphQL round-trip)
- `codex.command` is present and non-empty. (every tick — local)
- `restate.tool_run_retry_max_attempts` is a positive integer. (every tick — local)
- For tenants enabling Appendix B (comment commands), `comment_commands.bot_login` and
  the resolved webhook secret are validated. (every tick — local; the
  collaborator-permission probe in §11.6 is **startup / reload only**)

### 6.4 Core Config Fields Summary (Cheat Sheet)

This section is intentionally redundant. Implementations MUST recognize every field listed
here, apply defaults per Section 5.3, and emit a typed validation error on invalid values.

Tracker:

- `tracker.kind`: string, REQUIRED, currently `github`
- `tracker.endpoint`: string, default `https://api.github.com/graphql`
- `tracker.auth.mode`: string, REQUIRED, one of `github_app` or `pat`
- `tracker.auth.installation_id` or `tracker.auth.installation_id_ref`: integer / env var
  name (REQUIRED for `github_app`)
- `tracker.auth.token_ref`: env var name (REQUIRED for `pat`; default `GITHUB_TOKEN`)
- `tracker.owner`: string, REQUIRED unless `tracker.project_id` is set
- `tracker.owner_type`: string, default `organization`
- `tracker.project_number`: positive integer, REQUIRED when `tracker.project_id` is unset
- `tracker.project_id`: string, OPTIONAL alternative
- `tracker.repo`: string, OPTIONAL
- `tracker.status_field`: string, default `Status`
- `tracker.priority_field`: string, default `Priority`
- `tracker.priority_mapping`: map, default per Section 5.3.1
- `tracker.include_kinds`: list of strings, default `["issue", "pull_request"]`
- `tracker.active_states`: list of strings, default `["Todo", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Done"]`
- `tracker.dependency_gating_states`: list of strings, default `["Todo"]`
- `tracker.gate_running_on_dependencies`: boolean, default `false`
- `tracker.cross_repo_blockers`: boolean, default `true`
- `tracker.pr_dispatch_signals`: list, default `[]` (Section 11.7)
- `tracker.pr_block_signals`: list, default `[]`
- `tracker.pr_self_reviewer_logins`: list, default `[]`

Polling and reconciliation:

- `polling.interval_ms`: integer, default `30000`
- `polling.reconcile_interval_ms`: integer, default `60000`

Workspace:

- `workspace.root_ref`: env var name, REQUIRED
- `workspace.relative_root`: string, OPTIONAL

Hooks:

- `hooks.after_create`: shell script or null
- `hooks.before_run`: shell script or null
- `hooks.after_run`: shell script or null
- `hooks.before_remove`: shell script or null
- `hooks.timeout_ms`: integer, default `60000`

Agent / Codex:

- `agent.max_concurrent_agents`: integer, default `10`
- `agent.max_turns`: integer, default `20`
- `agent.max_retry_backoff_ms`: integer, default `300000`
- `agent.max_concurrent_agents_by_state`: map, default `{}`
- `codex.command`: shell command, default `codex app-server`
- `codex.approval_policy`: implementation-defined Codex value
- `codex.thread_sandbox`: implementation-defined Codex value
- `codex.turn_sandbox_policy`: implementation-defined Codex value
- `codex.turn_timeout_ms`: integer, default `3600000`
- `codex.read_timeout_ms`: integer, default `5000`
- `codex.stall_timeout_ms`: integer, default `300000`
- `codex.version_pin`: string, RECOMMENDED

Restate-specific:

- `restate.service_name`: string, default `symphony`
- `restate.cron_jitter_ms`: integer, default `1000`
- `restate.tool_run_retry_max_attempts`: integer, default `5`
- `restate.tool_run_retry_initial_delay_ms`: integer, default `500`
- `restate.tool_run_retry_max_delay_ms`: integer, default `30000`
- `restate.awakeable_pause_ttl_ms`: integer or null, default null
- `restate.epic_handoff_timeout_days`: integer, default `7`

Webhooks (MANDATORY in this edition — see Appendix A):

- `webhook.enabled`: boolean, default `true` (this edition)
- `webhook.bind`: string, default `0.0.0.0` (Restate ingress fronts it)
- `webhook.port`: integer, default `8080` (Restate ingress port)
- `webhook.path`: string, default `/WebhookReceiver/github`
- `webhook.secret_ref`: env var name, REQUIRED
- `webhook.events`: list, default per §A.5
- `webhook.allowlist_cidrs`: list, default empty
- `webhook.delivery_dedup_ttl_ms`: integer, default `86400000`
- `webhook.max_payload_bytes`: integer, default `26214400` (25 MB)

Comment commands (Appendix B, OPTIONAL):

- `comment_commands.enabled`: boolean, default `false`
- `comment_commands.bot_login`: string, REQUIRED when enabled
- `comment_commands.allowed_permissions`: list, default
  `["ADMIN","MAINTAIN","WRITE"]`
- `comment_commands.allowed_authors`: list, default empty
- `comment_commands.commands`: list, default all canonical commands
- `comment_commands.reaction_acknowledge`: string or null, default null

## 7. Restate Architecture

This section is the heart of this edition. Symphony is built on Restate primitives —
Virtual Objects, Workflows, Services, awakeables, durable promises, durable timers — and
the choice of which primitive a component uses is load-bearing.

### 7.1 Service / Virtual Object / Workflow Decomposition

Restate exposes three handler shapes. The choice between them affects concurrency,
persistence, and idempotency semantics:

- **Service** — stateless; many invocations may run concurrently. Use for stateless RPC
  surfaces (`WebhookReceiver`, `CommentRouter`, `GitHubAdapter`, `AgentRuntime`).
- **Virtual Object** — exclusive-handler-per-key serialization. At most one exclusive
  handler runs at a time per key; shared handlers may run concurrently per key (and
  with the active exclusive handler) but cannot mutate state. Use whenever a logical
  entity needs a serialized authoritative state machine: tenants (`Tenant`), per-issue
  dispatch authority (`IssueAgent`), per-tenant cron clocks (`SymphonyCron`,
  `ReconcileCron`).
- **Workflow** — exactly-once per workflow ID. The `run` handler executes at most once
  successfully per ID; reuse of the ID is rejected. Shared handlers on the workflow may
  be invoked many times. Use for long-horizon orchestrations whose identity is
  naturally one-shot: `Epic`, `ApprovalWorkflow`.

#### 7.1.1 Tenant (Virtual Object)

- Key: `tenant_id`.
- Exclusive handlers:
  - `init(ConfigReq) -> ()` — first-time provisioning. Parses workflow, validates,
    persists config. MUST fail if the tenant already exists with non-empty state, unless
    `req.allow_reinit == true`.
  - `update_config(ConfigReq) -> ()` — reload. See Section 6.2.
  - `rotate_app_token() -> ()` — invalidate the cached installation token; the next mint
    call refreshes from GitHub.
- Shared handlers:
  - `config() -> TenantConfig` — read-only snapshot used by every other component for
    routing decisions.
- State keys: `config`, `cached_installation_token`,
  `cached_installation_token_expires_at`.

#### 7.1.2 IssueAgent (Virtual Object)

- Key: `<tenant_id>:<issue_node_id>` — for example
  `acme-prod:PVTI_lADOBcd_eM4AF6gQzgKZ1aw`.
- Exclusive handlers:
  - `dispatch(DispatchReq) -> DispatchOutcome` — the agent run loop. Section 10.
  - `pause(PauseReq) -> ()` — set the `pause_reason` flag in VO state. The next
    `dispatch` iteration creates and awaits its own awakeable; this handler does NOT
    create the awakeable itself. See §B.7 for the durable-across-restart design.
  - `resume() -> ()` — clear the `pause_reason` flag and, if `pause_awakeable_id` is
    set in state (because dispatch already reached its pause check), resolve it.
  - `stop() -> ()` — request that the in-flight `dispatch` invocation (if any) exit at
    its next safe checkpoint, and set a `stopped_at` marker so the next webhook-
    triggered tick skips this issue until explicitly retried. Cancellation is
    **cooperative** (see §10.9 for semantics): `stop` sets a `stop_requested` flag in
    VO state, and the `dispatch` loop polls that flag at every safe checkpoint
    (between turns). When the flag is observed, dispatch terminates the Codex
    subprocess gracefully and returns `DispatchOutcome::Stopped`.
- Shared handlers:
  - `status() -> IssueAgentStatus` — current VO state plus the most recent invocation ID
    of `dispatch`.
- State keys: `workspace_path`, `codex_thread_id`, `turn_count`, `last_event`,
  `pause_awakeable_id`, `pause_reason`, `pause_requested_by`, `pause_requested_at`,
  `current_attempt`, `current_dispatch_invocation_id`, `stop_requested`, `stopped_at`.

#### 7.1.3 SymphonyCron (Virtual Object)

- Key: `tenant_id`.
- Exclusive handlers:
  - `init() -> ()` — schedule the first `tick`. Idempotent.
  - `tick() -> TickSummary` — see Section 8.1. Self-reschedules **before** doing work.
  - `cancel() -> ()` — clear `next_invocation_id` so the next scheduled tick becomes a
    no-op when it fires.
- Shared handlers:
  - `info() -> CronInfo` — last run, next scheduled run, last summary.
- State keys: `cron_slot_state` (`Idle | Scheduled | Running`), `last_run_at`,
  `next_invocation_id`, `last_run_summary`.

The crash-safety invariant: `tick` MUST schedule its own next invocation **before**
performing any tracker fetches or dispatch decisions. If the worker crashes mid-tick,
Restate will replay; the rescheduling step is journaled and will not double-schedule.

#### 7.1.4 ReconcileCron (Virtual Object)

Same shape as `SymphonyCron`. Separate VO so a stuck reconciliation cycle does not block
fresh polling and vice versa.

#### 7.1.5 Epic (Workflow)

- Key: `<tenant_id>:<epic_issue_node_id>`.
- `run(EpicRequest) -> EpicResult` — the long-horizon orchestration. Section 16.
- Shared handler: `submit_handoff(approver_login)` — resolves the `handoff` durable
  promise.

#### 7.1.6 ApprovalWorkflow (Workflow)

- Key: `<tenant_id>:<request_id>`.
- `run(ApprovalRequest) -> ApprovalOutcome` — chains
  `ctx.promise::<Decision>(stage_name)` for each stage.
- Shared handler: `submit_decision(stage_name, decision)`.

#### 7.1.7 WebhookReceiver (Service)

- `github(WebhookReq) -> ()` — Section 9 / Appendix A.

#### 7.1.7a WebhookDedup (Virtual Object)

- Key: `tenant_id`.
- Backs the dedup window referenced in Appendix A.4 step 7.
- State: a sliding-window set of `X-GitHub-Delivery` UUIDs keyed by their delivery
  timestamp; entries older than `webhook.delivery_dedup_ttl_ms` are evicted lazily on
  each access (or by a periodic compaction tick — implementation-defined).
- Exclusive handlers:
  - `check_and_record(delivery_id, ttl_ms) -> bool` — returns `true` if the delivery
    was already seen within the TTL window; otherwise records it and returns `false`.
- Shared handlers:
  - `count() -> usize` — diagnostic; current window size.

The receiver invokes `WebhookDedup.check_and_record` via
`ctx.object_client::<WebhookDedupClient>(tenant_id).check_and_record(req).call().await?`.
Centralizing the dedup state in a per-tenant VO keeps the exclusive-handler-per-key
serialization guarantee for atomicity, makes the sliding window observable as VO state
across restarts, and avoids leaking dedup data across tenants.

#### 7.1.8 CommentRouter (Service)

- `route(CommentEvent) -> ()` — Appendix B.

#### 7.1.9 GitHubAdapter (Service)

- `mint_installation_token(tenant_id) -> InstallationToken`
- `fetch_candidate_issues(tenant_id) -> Vec<Issue>`
- `fetch_issue_states_by_ids(tenant_id, ids) -> Vec<IssueRef>`
- `fetch_issues_by_states(tenant_id, states) -> Vec<Issue>`
- `probe_status_field(tenant_id) -> StatusFieldInfo`
- `resolve_collaborator_permission(tenant_id, owner, repo, login) -> Permission`
- `execute_graphql(tenant_id, query, variables) -> GraphQlResponse` — used by Codex's
  `github_graphql` tool.

#### 7.1.10 AgentRuntime (Service)

- `start_codex_subprocess(StartReq) -> SubprocessHandle` — internal, called only from
  `IssueAgent.dispatch` via `ctx.run`.
- `execute_tool(tenant_id, call_id, tool_name, args) -> ToolResult` — the per-tool-call
  side-effect runner. Idempotency at the `(tenant_id, call_id)` boundary is the caller's
  job (Section 10.4).

### 7.2 Key Namespacing for Multi-Tenancy

Every per-tenant resource key MUST start with `<tenant_id>:`. The conventions:

| Resource | Key |
|---|---|
| `Tenant` VO | `<tenant_id>` |
| `IssueAgent` VO | `<tenant_id>:<project_v2_item_node_id>` |
| `SymphonyCron` VO | `<tenant_id>` |
| `ReconcileCron` VO | `<tenant_id>` |
| `Epic` Workflow | `<tenant_id>:<epic_issue_node_id>` |
| `ApprovalWorkflow` Workflow | `<tenant_id>:<request_id>` |

Operators can audit per-tenant activity via:

```sql
SELECT id, target, status, created_at
FROM sys_invocation
WHERE target_key LIKE 'acme-prod:%'
   OR (target_service IN ('Tenant','SymphonyCron','ReconcileCron') AND target_key = 'acme-prod')
ORDER BY created_at DESC
LIMIT 100;
```

Soft tenant isolation on a shared cluster relies entirely on this convention. Any handler
that writes to or reads from VO state MUST use the caller's tenant ID and MUST refuse to
operate cross-tenant. The compiler does not enforce this; code review and tests must.
Hard tenant isolation requires per-tenant Restate clusters (Section 15.4).

### 7.3 Per-Tenant Credential Model

Credentials are NEVER persisted in VO state. They are minted on demand and cached only
inside Restate's journal where Restate's storage encryption / at-rest controls apply.

GitHub App auth (RECOMMENDED):

- Symphony is registered as a GitHub App. Its App ID and private key live in deployment
  env vars (`SYMPHONY_GITHUB_APP_ID`, `SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH`).
- Each tenant supplies its `installation_id` in `tracker.auth`.
- `GitHubAdapter.mint_installation_token(tenant_id)`:
  1. Loads `tenant.config.tracker.auth.installation_id` via `Tenant.config()`.
  2. Builds a JWT signed with the App's private key (10-minute expiry).
  3. Calls `POST /app/installations/<id>/access_tokens` to receive a 1-hour installation
     token.
  4. Returns the token. The result is journaled inside the calling handler's
     `ctx.run(...).name("mint:<tenant_id>")` step, so on replay the same token is reused
     until expiry.
- A 401 response from any GitHub call MUST trigger
  `Tenant.rotate_app_token()` followed by a single retry of the original call.

PAT auth (acceptable for single-tenant or low-volume):

- The tenant declares `tracker.auth.token_ref`. The Symphony worker reads the env var on
  every mint call and returns the value.
- `Tenant.rotate_app_token` is a no-op for PAT tenants (rotation is operator-driven).

In both modes, the **token value** never appears in VO state. Only the
`installation_id` (App) or `token_ref` (PAT) is persisted.

### 7.4 Restate Rust SDK Idiomatic Patterns

Implementations MUST use `restate-sdk` v0.10 or newer.

#### 7.4.1 Trait + struct shape

Every Service / VO / Workflow is declared as a trait with `#[restate_sdk::service]`,
`#[restate_sdk::object]`, or `#[restate_sdk::workflow]`, then implemented on a struct.

```rust
use restate_sdk::prelude::*;

#[restate_sdk::object]
pub trait IssueAgent {
    async fn dispatch(req: Json<DispatchReq>) -> Result<Json<DispatchOutcome>, HandlerError>;

    async fn pause(req: Json<PauseReq>) -> Result<(), HandlerError>;

    async fn resume() -> Result<(), HandlerError>;

    async fn stop() -> Result<(), HandlerError>;

    #[shared]
    async fn status() -> Result<Json<IssueAgentStatus>, HandlerError>;
}

pub struct IssueAgentImpl {
    deps: Arc<SymphonyDeps>,
}

impl IssueAgent for IssueAgentImpl {
    async fn dispatch(
        &self,
        ctx: ObjectContext<'_>,
        req: Json<DispatchReq>,
    ) -> Result<Json<DispatchOutcome>, HandlerError> {
        // ...
    }

    // ...
}
```

#### 7.4.2 `ctx.run` for side effects

Every observable side effect MUST be inside a `ctx.run(...)` block so it is journaled and
replayed correctly. The Rust SDK takes a `RunClosure` (typically `|| async move { ... }`),
and the step name is attached via the `.name("...")` builder method on the returned
`RunFuture`:

```rust
let token = ctx
    .run(|| async move {
        github_adapter::mint_installation_token(tenant_id).await
    })
    .name("mint_installation_token")
    .await?;
```

The closure receives no `ctx` — nesting `ctx.run` inside `ctx.run` is forbidden.

#### 7.4.3 Per-step retry policy

```rust
use std::time::Duration;
use restate_sdk::context::{RunFuture, RunRetryPolicy};

let token = ctx
    .run(|| async move {
        github_adapter::mint_installation_token(tenant_id).await
    })
    .name("mint_installation_token")
    .retry_policy(
        RunRetryPolicy::default()
            .initial_delay(Duration::from_millis(500))
            .exponentiation_factor(2.0)
            .max_delay(Duration::from_secs(30))
            .max_attempts(5),
    )
    .await?;
```

Per-step retry is the foundation of audit-grade durability: every retry is journaled with
its attempt count, error, and timing.

**Closure-capture caveat**: when the closure passed to `ctx.run` borrows variables from
its environment AND the call has `retry_policy(...)` with `max_attempts > 1`, the
closure must be re-invokable. Use the canonical clone-in-factory shape so the closure
implements `Fn`/`FnMut` rather than being consumed on the first attempt:

```rust
let call_id = call_id.clone();
let tool_name = tool_name.clone();
let args = args.clone();
ctx.run(move || {
    let call_id = call_id.clone();
    let tool_name = tool_name.clone();
    let args = args.clone();
    async move {
        agent_runtime::execute_tool(tenant_id, &call_id, &tool_name, &args).await
    }
})
.name(format!("tool:{call_id}"))
.retry_policy(RunRetryPolicy::default().max_attempts(5))
.await?;
```

If the inputs are `Copy` (e.g. integers), the inner `let ... = ....clone()` lines are
unnecessary. Implementations SHOULD prefer borrowing read-only references that are
`'static` over cloning when possible, but the clone-in-factory shape is the safe default
when the borrow checker complains.

#### 7.4.4 Terminal vs transient errors

- `TerminalError::new("...")` — surfaced to the caller; **does not retry**. Use for
  business failures (invalid config, unauthorized, missing resource).
- Any other `Result::Err(_)` — retried per the run's retry policy. Use for transient
  failures (network, 5xx, rate limit).

```rust
if !req.tenant_exists {
    return Err(TerminalError::new("tenant not initialized").into());
}
```

#### 7.4.5 Awakeables

An awakeable is a durable promise scoped to the invocation that creates it. The id is a
stable string; any party that knows the id may resolve or reject it. The creator awaits
the promise, suspending its invocation durably (zero compute, journaled).

```rust
// Generic shape: an external system callback waits for confirmation.
let (awakeable_id, awakeable_promise) = ctx.awakeable::<CallbackPayload>();
ctx.run(|| async move { post_id_to_external_system(awakeable_id.clone()).await })
    .name("notify_external_system")
    .await?;
let payload: CallbackPayload = awakeable_promise.await?;  // suspends durably
```

Resolution can come from another handler (`ctx.resolve_awakeable(&id, value)`) or via
HTTP `POST /restate/awakeables/<id>/resolve`. **Important**: the creating invocation
MUST remain alive (suspended on `.await`) for the resolution to take effect — once the
creating invocation returns, the awakeable handle is dropped. The pause/resume design in
§B.7 follows this rule by creating the awakeable inside the running `dispatch`
invocation, never inside the `pause` handler.

#### 7.4.6 Durable promises (Workflows only)

```rust
let approver: String = ctx
    .promise::<String>("handoff")
    .value()
    .await?;
```

Multiple `ctx.promise::<T>(name)` calls with the same `name` deliver the same value to all
awaiters. Resolved via the workflow's shared handlers (e.g.
`Epic.submit_handoff(approver_login)`).

#### 7.4.7 Durable timers, parallel calls, and selection

```rust
ctx.sleep(Duration::from_secs(30)).await?;

// Static N (small fixed set): use the restate::select! macro for first-of branches.
// For a small fixed set of parallel awaits, await each individually after kicking them off
// (the SDK has no `gather!` macro). For dynamic-N parallelism, see DurableFuturesUnordered
// below.
let fut_a = ctx.object_client::<IssueAgentClient>(key_a).dispatch(req_a).call();
let fut_b = ctx.object_client::<IssueAgentClient>(key_b).dispatch(req_b).call();
let fut_c = ctx.object_client::<IssueAgentClient>(key_c).dispatch(req_c).call();
let a = fut_a.await?;
let b = fut_b.await?;
let c = fut_c.await?;

// First-of selection across heterogeneous durable futures.
let outcome = restate::select! {
    approval = ctx.promise::<String>("alice").value() => SelectResult::Approval(approval?),
    _ = ctx.sleep(Duration::from_secs(7 * 86_400)) => SelectResult::Timeout,
};

// Dynamic N (collection of in-flight calls): DurableFuturesUnordered.
// Note: handler return types use Json<T>, so unwrap with .into_inner() consistently
// across the codebase (matches §16.2's Epic.run sub-issue collection).
use restate_sdk::context::DurableFuturesUnordered;
let mut futures = DurableFuturesUnordered::new();
for key in &keys {
    futures.push(
        ctx.object_client::<IssueAgentClient>(key.clone())
            .dispatch(req_for(key))
            .call(),
    );
}
let mut results = Vec::with_capacity(keys.len());
while let Some((index, result)) = futures.next().await? {
    results.push((index, result?.into_inner()));
}
```

#### 7.4.8 Reading the raw HTTP request

Used by `WebhookReceiver` for HMAC verification:

```rust
let req_meta = ctx.request();
let signature = req_meta
    .headers
    .get("x-hub-signature-256")
    .ok_or_else(|| TerminalError::new("missing signature"))?;
let raw_body: &[u8] = req_meta.body.as_ref();
```

#### 7.4.9 Object, service, and workflow calls

The Rust SDK exposes calls through generated `*Client` types (auto-emitted by the
`#[restate_sdk::service]`, `#[restate_sdk::object]`, and `#[restate_sdk::workflow]`
attribute macros: trait `Foo` produces `FooClient`). Build a client with
`ctx.service_client::<C>()` / `ctx.object_client::<C>(key)` /
`ctx.workflow_client::<C>(key)`; each handler method returns a builder that ends in
`.call().await?` (request-response), `.send()` (fire-and-forget), or
`.send_after(duration)` (delayed fire-and-forget):

```rust
// Request-response on a Virtual Object.
ctx.object_client::<IssueAgentClient>(format!("{tenant}:{id}"))
    .dispatch(Json(req))
    .call()
    .await?;

// Fire-and-forget on a Virtual Object (the send is journaled).
ctx.object_client::<SymphonyCronClient>(tenant_id.to_string())
    .tick()
    .send();

// Request-response on a Service.
ctx.service_client::<GitHubAdapterClient>()
    .fetch_candidate_issues(Json(tenant_id))
    .call()
    .await?;

// Delayed fire-and-forget (replaces the older "send with delay" pattern).
ctx.object_client::<SymphonyCronClient>(tenant_id.to_string())
    .tick()
    .send_after(Duration::from_secs(60));

// Workflow send.
ctx.workflow_client::<EpicClient>(workflow_key)
    .submit_handoff(Json(approver))
    .send();
```

### 7.5 Endpoint Registration

Every Symphony worker registers all handlers with Restate Server at startup:

```rust
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let deps = Arc::new(SymphonyDeps::from_env()?);

    let endpoint = Endpoint::builder()
        .bind(TenantImpl::new(deps.clone()).serve())
        .bind(IssueAgentImpl::new(deps.clone()).serve())
        .bind(SymphonyCronImpl::new(deps.clone()).serve())
        .bind(ReconcileCronImpl::new(deps.clone()).serve())
        .bind(EpicImpl::new(deps.clone()).serve())
        .bind(ApprovalWorkflowImpl::new(deps.clone()).serve())
        .bind(WebhookReceiverImpl::new(deps.clone()).serve())
        .bind(CommentRouterImpl::new(deps.clone()).serve())
        .bind(GitHubAdapterImpl::new(deps.clone()).serve())
        .bind(AgentRuntimeImpl::new(deps.clone()).serve())
        .build();

    HttpServer::new(endpoint)
        .listen_and_serve(deps.bind_addr)
        .await?;
    Ok(())
}
```

## 8. Polling, Scheduling, and Reconciliation

This section replaces the in-memory poll loop of the language-agnostic edition with
self-rescheduling Restate Virtual Objects. **Webhooks are mandatory** in this edition (see
Appendix A); polling is the safety net for missed events, GitHub delivery failures, and
out-of-order deliveries.

### 8.1 SymphonyCron Tick

`SymphonyCron.tick` runs once per `polling.interval_ms` per tenant. The tick sequence:

```
fn tick(ctx, tenant_id):
  // 1. Reschedule next tick BEFORE doing work (crash-safe).
  let next_delay = jitter(polling.interval_ms, restate.cron_jitter_ms)
  let handle = ctx.object_client::<SymphonyCronClient>(tenant_id)
                   .tick()
                   .send_after(next_delay)
  let next_id = handle.invocation_id().await?     // InvocationHandle
  ctx.set("next_invocation_id", next_id)
  ctx.set("cron_slot_state", Running)

  // 2. Validate config; on failure, log and exit (next tick will retry).
  let cfg = ctx.object_client::<TenantClient>(tenant_id).config().call().await?
  let validation = validate_dispatch_config(cfg)
  if validation is not ok:
    ctx.set("last_run_summary", { error: validation })
    ctx.set("cron_slot_state", Idle)
    return TickSummary::ValidationFailed

  // 3. Fetch candidate issues from tracker.
  let issues = ctx
    .run(|| async move { github_adapter::fetch_candidate_issues(tenant_id).await })
    .name("fetch_candidates")
    .await?

  // 4. Sort by dispatch priority.
  let sorted = sort_for_dispatch(issues, cfg)

  // 5. For each candidate, check eligibility and dispatch.
  let mut dispatched = 0
  for issue in sorted:
    if !candidate_eligible(issue, cfg):
      continue                              // dependency gate, terminal-OR, etc.
    if !concurrency_slot_available(tenant_id, cfg):
      break

    // Fire-and-forget; IssueAgent.dispatch handles its own claim semantics.
    ctx.object_client::<IssueAgentClient>(format!("{tenant_id}:{issue.id}"))
       .dispatch(DispatchReq::from_polling(issue))
       .send()
    dispatched += 1

  ctx.set("last_run_at", now)
  ctx.set("last_run_summary", TickSummary::Ok(dispatched))
  ctx.set("cron_slot_state", Scheduled)
  return TickSummary::Ok(dispatched)
```

Notes:

- The "claimed" check is implicit: `IssueAgent.dispatch` is exclusive-per-key, so a fresh
  `dispatch` invocation against an `IssueAgent` whose previous `dispatch` is still running
  will queue behind it. The implementation MUST avoid queueing a redundant dispatch by
  checking `IssueAgent.status()` — a shared handler — before sending.
- Slot availability is checked via the per-tenant counter VO described in Section 15.3.
- `fetch_candidate_issues` is wrapped in `ctx.run(...).name("fetch_candidates")` so the
  GraphQL call is journaled and retried per the run policy (Section 7.4.3).

### 8.2 Candidate Selection Rules

An issue is dispatch-eligible only if all are true:

- It has `id`, `identifier`, `title`, and `state`.
- Its state is in `active_states` and not in `terminal_states` (terminal-OR rule, Section
  11.2.1).
- It is not currently in a non-terminal `IssueAgent.dispatch` invocation (checked via
  `IssueAgent.status()` shared handler).
- Per-tenant concurrency slot is available.
- Per-state concurrency slot is available (when configured).
- Dependency gate passes (Section 8.2.1, Appendix D).
- For PR items, `pr_dispatch_signals`/`pr_block_signals` evaluation passes (Section 11.7).

Sorting order (stable):

1. `priority` ascending (lower numbers first; `null` sorts last).
2. `created_at` oldest first.
3. `identifier` lexicographic.

#### 8.2.1 Dependency Gate

See Appendix D for the full algorithm. In this edition, the gate is applied inside
`SymphonyCron.tick` before the eligibility check above. Items that fail the gate are
skipped; the snapshot view (Section 12) reports them in the `gated` bucket so operators
can see why they are sitting still.

### 8.3 Concurrency Control

The per-tenant concurrency cap is enforced via a per-tenant counter Virtual Object,
`TenantSlots` (key = `tenant_id`):

- `acquire(state) -> bool` — exclusive handler. Increments `running_count` and per-state
  count if both caps allow; returns false otherwise.
- `release(state) -> ()` — exclusive handler. Decrements both counts.

`IssueAgent.dispatch` calls `acquire` at the top and `release` in a guard cleanup. Crash
recovery: on dispatch invocation cancellation by Restate, the cleanup step still runs
because Restate replays the journal.

### 8.4 Retry and Backoff

Retry semantics are implemented via Restate's per-step `RunRetryPolicy`, not an
orchestrator-level retry queue. The retry queue from the language-agnostic edition is
removed entirely.

Three classes of "retry":

1. **Step-level transient retry** — the `RunRetryPolicy` on every `ctx.run` step. A
   network failure inside `mint_installation_token` retries with exponential backoff up
   to `agent.max_retry_backoff_ms` (mapped to `RunRetryPolicy::max_delay`). Note that
   `restate-sdk` v0.10 is pre-1.0; method names (`max_delay`, `initial_delay`,
   `exponentiation_factor`) MAY shift across minor versions, so deployments MUST pin the
   exact `restate-sdk` version in `Cargo.toml`.

2. **Continuation retry** — when `IssueAgent.dispatch` finishes a turn cleanly and the
   issue is still active, the loop runs another turn within the same dispatch
   invocation. No retry timer; the loop is just a `for turn in 1..=max_turns`.

3. **Webhook-driven re-dispatch** — when a relevant webhook event arrives,
   `WebhookReceiver` sends a fresh `IssueAgent.dispatch` (or `SymphonyCron.tick`)
   invocation. Restate's exclusive-per-key serialization queues it behind any in-flight
   work.

There is no separate "retry queue" data structure. The journal IS the retry record.

### 8.5 Active Run Reconciliation

`ReconcileCron.tick` runs every `polling.reconcile_interval_ms`. It performs three checks
across all running issues for the tenant.

```
fn tick(ctx, tenant_id):
  reschedule_next_tick()

  let cfg = ctx.object_client::<TenantClient>(tenant_id).config().call().await?
  let running_ids = ctx
    .run(|| async move { list_in_flight_issue_agent_invocations(tenant_id).await })
    .name("list_running")
    .await?

  if running_ids.is_empty():
    return ReconcileSummary::NothingToDo

  // Part A: Stall detection.
  for id in running_ids:
    let status = ctx.object_client::<IssueAgentClient>(id.clone()).status().call().await?
    if elapsed_since(status.last_event_at) > cfg.codex.stall_timeout_ms && cfg.codex.stall_timeout_ms > 0:
      ctx.object_client::<IssueAgentClient>(id).stop().send()

  // Part B: Tracker state refresh.
  let refreshed = ctx
    .run(|| async move { github_adapter::fetch_issue_states_by_ids(tenant_id, ids).await })
    .name("refresh_states")
    .await?

  for issue in refreshed:
    if issue.state in cfg.terminal_states OR underlying closed:
      ctx.object_client::<IssueAgentClient>(issue.key()).stop().send()
      schedule_workspace_cleanup(issue)
    else if issue.state in cfg.active_states:
      pass
    else:
      ctx.object_client::<IssueAgentClient>(issue.key()).stop().send()

  // Part C: Dependency-gate refresh (when gate_running_on_dependencies = true).
  if cfg.gate_running_on_dependencies:
    for issue in refreshed where state in cfg.dependency_gating_states:
      if !dependency_gate_passes(issue, cfg):
        ctx.object_client::<IssueAgentClient>(issue.key()).stop().send()
        emit_log("dependencies_reopened", issue)
```

Termination via Part C does NOT schedule a retry — see Appendix D.

### 8.6 Startup Terminal Workspace Cleanup

When a tenant is initialized via `Tenant.init`:

1. Schedule `SymphonyCron.init` (which schedules the first tick).
2. Schedule `ReconcileCron.init`.
3. Run a one-shot `cleanup_terminal_workspaces` step:
   - Query tracker for issues in terminal states.
   - For each, remove the workspace directory if it exists.
   - Failure of this step is non-fatal (logged, continue).

This cleanup also runs on `Tenant.update_config` only if `terminal_states` changed.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Per-tenant workspace root:

- `<SHARED_FS_ROOT>/<tenant_id>/workspaces/`
- Plus `relative_root` if configured: `<SHARED_FS_ROOT>/<tenant_id>/<relative_root>/workspaces/`.

Per-issue workspace path:

- `<tenant_workspace_root>/<sanitized_issue_identifier>` (absolute).

Per-tenant Codex thread state directory:

- `<SHARED_FS_ROOT>/<tenant_id>/threads/`

Workspace persistence:

- Workspaces are reused across runs for the same `(tenant, issue)` pair.
- Successful runs do not auto-delete workspaces.
- Codex thread JSONL files persist across `dispatch` invocations so that
  `thread/resume` works on the next run.

### 9.2 Workspace Creation and Reuse

Inside `IssueAgent.dispatch`:

```rust
let workspace = ctx
    .run(|| async move {
        let path = compute_workspace_path(tenant_id, issue.identifier())?;
        let created = std::fs::create_dir_all(&path).map(|_| !path.was_already_dir())?;
        Ok(Workspace { path, created_now: created })
    })
    .name("ensure_workspace")
    .await?;
```

The `ctx.run` step is journaled, so on replay the `created_now` flag is reused — preventing
the `after_create` hook from running twice.

If `created_now == true`, run the `after_create` hook in the same `ctx.run` step or a
chained one named `hook:after_create`.

### 9.3 OPTIONAL Workspace Population

The spec does not require any built-in VCS / repository bootstrap behavior. Implementations
typically do this via `after_create` and `before_run` hooks (e.g. `git clone`, `bun
install`).

Failure handling:

- Workspace population failures return a non-terminal error from the relevant `ctx.run`
  step; Restate retries per the run policy.
- If the `after_create` hook fails and the workspace was newly created, the hook's
  `ctx.run` MAY remove the partially-created directory before propagating the error.
- Reused workspaces SHOULD NOT be destructively reset on population failure.

### 9.4 Workspace Hooks

Each hook execution is a separate `ctx.run` step:

- `hook:after_create` — runs once on workspace creation. Failure: `TerminalError`
  (workspace creation aborts).
- `hook:before_run:<turn>` — runs before each turn's Codex spawn. Failure: non-terminal
  retry, then `TerminalError` after retries exhausted.
- `hook:after_run:<turn>` — runs after each turn (success or failure). Failure: logged
  and ignored.
- `hook:before_remove` — runs before workspace deletion. Failure: logged and ignored.

Execution contract:

- `bash -lc <script>` with `cwd = workspace.path`.
- Hook timeout: `hooks.timeout_ms` (default `60000`).
- Hook output truncated in logs to 4 KB unless `SYMPHONY_LOG_HOOK_FULL_OUTPUT=1`.

### 9.5 Safety Invariants

Invariant 1 — Codex cwd MUST equal the per-issue workspace path.

```rust
let mut child = tokio::process::Command::new("bash")
    .arg("-lc")
    .arg(&codex_command)
    .current_dir(&workspace.path)   // REQUIRED
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()?;
```

Invariant 2 — Workspace path MUST stay inside the tenant workspace root.

- Both paths normalized to absolute via `std::fs::canonicalize`.
- The implementation MUST refuse to launch Codex if `workspace_path` does not have
  `<SHARED_FS_ROOT>/<tenant_id>/` as a prefix directory (after canonicalization). This
  is the multi-tenant containment check.

Invariant 3 — Workspace key sanitization.

- Only `[A-Za-z0-9._-]` characters allowed in the directory name segment. All others are
  replaced with `_`.

Invariant 4 — Tenant cross-talk prohibited.

- A worker handling `IssueAgent` for tenant A MUST NOT spawn Codex with a workspace path
  under tenant B's root. The validation in Invariant 2 is the structural enforcement.

### 9.6 Shared Filesystem Requirements

This edition requires a shared filesystem when more than one Symphony worker is deployed:

- Multiple Symphony workers run in front of one Restate cluster. Restate routes a given
  `IssueAgent` invocation to whichever worker happens to be available at the time. The
  worker MUST be able to read and write that issue's workspace and thread JSONL.

Requirements:

- POSIX-semantics for read, write, create, rename, fsync.
- Visibility: a write from worker A MUST be visible to worker B before the next
  `IssueAgent.dispatch` invocation begins (typically after `fsync` + close). NFSv4 with
  default mount options qualifies; AWS EFS, FSx for Lustre, GCSFuse with `--implicit-dirs
  --file-mode=600 --dir-mode=700` qualify.
- Locking is NOT required because Restate guarantees exclusive `IssueAgent.dispatch`
  per key.

NFS close-to-open coherence caveat: standard NFS implementations only guarantee
visibility of a writer's data to other clients after the writer `close(2)`s the file and
the reader subsequently `open(2)`s it. A reader that already has the file open when the
writer flushes will not see new bytes until reopen. For Codex thread JSONL files passed
between workers across an `IssueAgent.dispatch` boundary, implementations MUST:

- Open thread JSONL files with `O_SYNC` (or perform an explicit `fsync` followed by
  `close` after every JSONL append) so the bytes hit shared storage before the dispatch
  invocation completes.
- Treat the start of the next `IssueAgent.dispatch` as a fresh open — never carry an
  open file descriptor across a `ctx.run` boundary.
- Before issuing `thread/resume`, perform a verify-then-resume step that re-stats and
  re-opens the JSONL file to confirm the expected length and trailing record (this also
  catches the corruption scenario in §10.8.2).

This guidance is normative for any deployment using NFS or NFS-derivative storage; it is
RECOMMENDED even on stronger filesystems (EFS, FSx) for defense in depth.

Single-worker deployments MAY use local filesystem.

Implementation-defined: how Symphony detects a stale workspace lock left by a crashed
worker (e.g. abandoned `git index.lock` files). RECOMMENDED: a `before_run` hook that
detects and removes such stale locks per the team's VCS conventions.

## 10. Codex Agent Integration

This section is the heart of the document. Every Codex turn is driven from inside an
`IssueAgent.dispatch` Restate invocation; every observable side effect — subprocess spawn,
tool execution, approval handling — is journaled via `ctx.run`. The audit trail captures
exactly what happened, in order, with timestamps.

### 10.1 Codex App-Server Protocol Summary

Codex exposes an "app-server" mode over stdio that speaks JSON-RPC 2.0 (newline-delimited;
the `"jsonrpc":"2.0"` field is omitted on the wire by convention; implementations MUST
accept it both ways).

Lifecycle:

1. `initialize` — handshake; declares client capabilities and tools.
2. `thread/start` (first turn) or `thread/resume <thread_id>` (continuation turn).
3. `turn/start` — begins one turn; the orchestrator supplies the prompt for the first
   turn or continuation guidance for later turns.
4. Stream of events: `item/started`, `item/.../delta`, `item/completed`, plus telemetry
   (`thread/tokenUsage/updated`, `account/rateLimits/updated`).
5. `turn/completed` — turn is done. Subprocess exits or stays alive for the next
   `turn/start`.

Two flavors of tool calls:

- **`mcpToolCall`** — auto-executed by Codex (outside Symphony's journal). Visible in
  events but not requiring orchestrator action.
- **`dynamicToolCall`** — server→client request `item/tool/call` carrying `call_id`,
  `tool_name`, and `arguments`. The orchestrator computes the result and replies. **This
  is Symphony's natural Restate journal point.**

Approvals — explicit server→client requests:

- `item/commandExecution/requestApproval` — Codex wants to run a shell command.
- `item/fileChange/requestApproval` — Codex wants to write a file.

Responses:

- `accept`, `acceptForSession`, `decline`, `cancel`,
  `acceptWithExecpolicyAmendment`.

Approval policy enum (Codex `AskForApproval`):

- `never` — auto-accept everything.
- `onRequest` — Codex asks per command.
- `unlessTrusted` — Codex auto-accepts trusted commands and asks for the rest.

Sandbox enum (Codex `SandboxMode`):

- `dangerFullAccess`, `readOnly`, `workspaceWrite`, `externalSandbox`.

Errors carry `codexErrorInfo` enum (`ContextWindowExceeded`, `UsageLimitExceeded`,
`ModelOverloaded`, etc.). Recommended max line size on stdio: 10 MB.

Authoritative source: the Codex protocol page at
`https://developers.openai.com/codex/app-server/`. Pin a Codex version per deploy because
`dynamicToolCall` is currently labelled experimental.

### 10.2 Subprocess Lifecycle: Per-Turn, Not Per-Issue

Symphony spawns Codex **once per turn**, not once per issue. The subprocess is torn down
when the turn ends. Thread state survives via the on-disk JSONL file plus
`thread/resume`.

Rationale:

- A long-running subprocess across many turns is fragile under Restate replay. If the
  Symphony worker is restarted between turns, the subprocess is gone but the journal says
  the next step is "send `turn/start` to that subprocess." Per-turn lifecycle eliminates
  the live-subprocess assumption.
- Codex's JSONL persistence + `thread/resume` is the supported way to pick up context
  across turns; using it explicitly aligns with Codex's design.

The flow inside one turn:

```rust
// Spawn the child OUTSIDE ctx.run; only journal the serializable session metadata.
let mut child = spawn_codex(&workspace.path, &codex_cfg)?;
let session: SessionMeta = ctx
    .run(|| async move {
        let session_id = handshake(&mut child).await?;
        let thread_id = match prior_thread_id {
            Some(tid) => resume_thread(&mut child, &tid).await?,
            None => start_thread(&mut child).await?,
        };
        Ok(SessionMeta { pid: child.id(), session_id, thread_id })
    })
    .name(format!("turn:{turn_n}:start_subprocess"))
    .await?;
// `child` remains in scope locally for the duration of this turn.
```

`tokio::process::Child` is **not** serializable and cannot cross a `ctx.run` boundary.
The `child` handle is held in a local variable for the duration of the turn; only the
serializable `SessionMeta { pid, session_id, thread_id }` is journaled. The handshake
itself is performed inside the `ctx.run` closure so it is journaled exactly once on
success; the spawn step lives outside (a journaled "spawned PID N" alone is not
meaningful across worker crashes — see the spawn-vs-record race below).

Honest gap: the spawn step itself is NOT exactly-once across worker crashes. If the
worker crashes after spawning but before journaling the result, Restate will replay and
spawn a second subprocess. Codex tolerates this — a stale subprocess holding a JSONL
write will be killed when the worker restarts (subprocess inherits the worker's lifetime
via `tokio::process::Command`'s default `kill_on_drop`-ish semantics; implementations
SHOULD set `Command::kill_on_drop(true)` explicitly).

### 10.3 Per-Tool-Call Journaling — The Architecture's Defining Feature

Every `dynamicToolCall` becomes a `ctx.run(...).name("tool:<call_id>")` step.

Codex stamps each tool-call item with a stable `item.id`. On Restate replay, the same
`call_id` produces the same step name, so the journaled result is reused without
re-executing the tool.

```rust
async fn run_one_turn(
    ctx: &ObjectContext<'_>,
    turn_n: u32,
    workspace: &Workspace,
    prior_thread_id: Option<String>,
    prompt: TurnPrompt,
) -> Result<TurnOutcome, HandlerError> {
    // Spawn outside ctx.run; journal only serializable SessionMeta.
    let mut child = spawn_codex(&workspace.path, &codex_cfg)?;
    let session: SessionMeta = ctx
        .run(|| async move { /* handshake + thread/start|resume */ Ok(SessionMeta { /* ... */ }) })
        .name(format!("turn:{turn_n}:start_subprocess"))
        .await?;

    send_turn_start(&mut child, &prompt).await?;

    loop {
        let event = read_event(&mut child).await?;
        match event {
            CodexEvent::ItemStarted(item) if item.is_dynamic_tool_call() => {
                let call_id = item.id.clone();
                let tool_name = item.tool_name.clone();
                let args = item.arguments.clone();

                // Tool execution. TerminalError MUST propagate out of dispatch so that
                // Restate marks the invocation terminal and the operator sees the
                // failure. Only non-terminal errors (transient retries exhausted) are
                // folded into ToolResult::error so the agent can see the failure and
                // adapt within the turn.
                let result = match ctx
                    .run(|| async move {
                        agent_runtime::execute_tool(
                            tenant_id,
                            &call_id,
                            &tool_name,
                            &args,
                        ).await
                    })
                    .name(format!("tool:{call_id}"))
                    .retry_policy(
                        RunRetryPolicy::default()
                            .max_attempts(cfg.restate.tool_run_retry_max_attempts as u32),
                    )
                    .await
                {
                    Ok(r) => r,
                    Err(HandlerError::Terminal(t)) => return Err(t.into()),
                    Err(HandlerError::Run(e)) => ToolResult::error(format!("{e:#}")),
                };

                send_tool_reply(&mut child, &call_id, &result).await?;
            }
            CodexEvent::CommandApprovalRequest(req) => {
                let call_id = req.call_id.clone();

                let decision = ctx
                    .run(|| async move { approval_policy::decide(tenant_id, &req).await })
                    .name(format!("approval:{call_id}"))
                    .await?;

                send_approval_reply(&mut child, &call_id, &decision).await?;
            }
            CodexEvent::FileChangeApprovalRequest(req) => {
                // same shape as CommandApprovalRequest
            }
            CodexEvent::TokenUsageUpdated(usage) => {
                ctx.run(|| async move { record_token_usage(tenant_id, &usage).await })
                    .name(format!("turn:{turn_n}:tokens"))
                    .await?;
            }
            CodexEvent::TurnCompleted(_) => break,
            CodexEvent::TurnFailed(err) => {
                return Err(map_codex_error(err));
            }
            _ => {
                // log and continue
            }
        }
    }

    let summary = ctx
        .run(|| async move {
            child.kill().await?;
            Ok(TurnSummary { /* ... */ })
        })
        .name(format!("turn:{turn_n}:end_subprocess"))
        .await?;

    Ok(TurnOutcome { thread_id: session.thread_id, summary })
}
```

#### 10.3.1 Tool-Reply Replay Race

The `tool:<call_id>` step is journaled when the closure returns the `ToolResult`. The
subsequent `send_tool_reply` writes that result into the Codex subprocess's stdin/JSONL.
If the worker crashes after the journal write but before `send_tool_reply` completes,
the next `IssueAgent.dispatch` invocation MUST handle the half-replied state safely:

- The journaled `tool:<call_id>` result is preserved across replay.
- The Codex subprocess and its in-memory state are gone.
- The thread JSONL on shared FS is in a half-replied state (request item present,
  response item absent or partial).

On the next dispatch, the implementation issues `thread/resume <thread_id>`. If Codex
reports a `protocol_state_invalid` (or equivalent transport-level "cannot resume from
this position") error, the implementation MUST start a NEW thread (clear
`codex_thread_id` from VO state and call `thread/start` afresh) instead of looping on
`thread/resume`. The journaled tool-call results from the prior `call_id` remain
available to operators auditing the journal, but the Codex thread itself cannot be
reanimated. Implementations SHOULD log `codex_thread_state_corrupted` with the prior
`thread_id` and the journaled `call_id` of the unreplied tool, then continue the
dispatch loop on the fresh thread.

**Agent continuity caveat**: the new thread has zero memory of the prior turn's tool
calls, partial reasoning, or scratch state. The agent re-derives task state from the
rendered prompt (workflow body + issue + previous-attempt metadata). Implementations
MAY include a structured "previous-attempt summary" in the first-turn prompt of a
fresh-thread reset to reduce wasted re-exploration; this summary MUST NOT include
unverified tool-result content (the agent could otherwise hallucinate a continuation
based on a tool result it never actually observed). The audit trail in the Restate
journal — not the agent's working memory — is the source of truth for what side
effects landed.

Why this works:

- Restate journals each `ctx.run` step name and result.
- On replay (worker restart, transient error), every `tool:<call_id>` step that already
  has a journaled result is **skipped** — the closure is not re-executed.
- The Codex protocol's `call_id` is stable across replay because it is generated by Codex,
  not by Symphony, so the step name is deterministic.

What this does NOT solve:

- **Agent non-determinism.** On a fresh turn (after a non-resumable failure), Codex may
  emit a different sequence of tool calls. The journal records "what actually happened"
  rather than "what should have happened." Audit trails MUST be interpreted accordingly.
- **Spawn-vs-record race.** As noted in 10.2, the subprocess spawn itself is not
  exactly-once across worker crashes. Codex tolerates a duplicate subprocess via JSONL
  exclusivity but the implementation MUST ensure stale subprocesses are killed.

### 10.4 Tool Execution Idempotency

Tools that have side effects (e.g. `git push`, `gh pr create`, `github_graphql` mutations)
MUST be idempotent at the `(tenant_id, call_id)` boundary. Required because:

- The `ctx.run(...).name("tool:<call_id>")` step is journaled, but the side effect is performed
  inside the closure. If the worker crashes after the side effect but before the journal
  write, Restate will replay the closure on the next attempt. Without idempotency, the
  side effect is applied twice.

Implementation patterns:

- For `github_graphql`: pass `call_id` as an idempotency key in mutation variables when the
  GraphQL operation supports one (e.g. `clientMutationId`).
- For `gh pr create`: compute the head branch name deterministically from
  `(issue.id, call_id)` at the workflow level. A retry against the same `head→base`
  pair fails with `pull request already exists`, providing idempotency. Different
  retry attempts MUST NOT generate different branch names (e.g. timestamp- or
  random-suffix-based), as that would create duplicate PRs.
- For arbitrary shell commands (`bash` tool): the implementation MUST mark the command as
  non-idempotent and surface this in the `ToolResult` so the agent's prompt can advise
  against retries. The default `RunRetryPolicy` for `tool:<call_id>` SHOULD use
  `max_attempts(1)` for these tools to avoid double-application.

The configuration knob is `restate.tool_run_retry_max_attempts` (default `5`); deployments
that cannot guarantee tool idempotency SHOULD set it to `1`.

#### 10.4.1 Tool-Run Error Propagation

The `tool:<call_id>` `ctx.run` step can fail in two distinct ways. Implementations MUST
distinguish them:

- **`HandlerError::Terminal(_)`** — a `TerminalError` raised by the tool execution
  (e.g. `tenant_misconfigured`, an explicit authorization failure, a schema-level
  rejection). The dispatch handler MUST propagate this with `?` so that Restate marks
  the invocation terminal and the operator sees the failure. Folding terminal errors
  into a `ToolResult::error` would let the agent silently work around the failure and
  obscure the operator signal.
- **`HandlerError::Run(_)`** — retries exhausted on a transient error. Implementations
  SHOULD fold this into a `ToolResult::error` that is sent back to the Codex subprocess
  so the agent can adapt within the same turn (e.g. choose a different tool, abort the
  task, or report the issue back via PR comment). The dispatch handler continues; the
  turn does not terminate.

The match in §10.3's reference code shows the canonical shape (`Err(HandlerError::Terminal(t))
=> return Err(t.into()); Err(HandlerError::Run(e)) => ToolResult::error(format!("{e:#}"))`).

### 10.5 Approval Handling

Each approval request is a journaled `ctx.run(...).name("approval:<call_id>")` step. The
closure consults the tenant's policy and decides:

```rust
async fn decide(
    tenant_id: &str,
    request: &ApprovalRequest,
) -> Result<ApprovalDecision, ApprovalError> {
    let cfg = read_tenant_config(tenant_id).await?;
    match cfg.codex.approval_policy {
        AskForApproval::Never => Ok(ApprovalDecision::AcceptForSession),
        AskForApproval::OnRequest => surface_to_operator(tenant_id, request).await,
        AskForApproval::UnlessTrusted => {
            if is_trusted(request) {
                Ok(ApprovalDecision::Accept)
            } else {
                surface_to_operator(tenant_id, request).await
            }
        }
    }
}
```

`surface_to_operator` MAY:

- create an `ApprovalWorkflow` invocation and await its decision (durable; survives
  restart);
- post a comment to the parent issue/PR with a deep link to a web UI;
- `ctx.awakeable::<ApprovalDecision>()` and store the awakeable ID where an external
  operator process can resolve it;
- fail the run with `TerminalError` if the policy is "no operator available".

The Symphony reference implementation defaults to `Never` (auto-accept everything) for
high-trust deployments. Deployments running against untrusted repositories MUST configure
`OnRequest` and supply an operator surface.

User-input-required signals (Codex `turn_input_required`) are handled identically:
journaled as `user_input:<turn_n>`, surfaced via the configured operator policy. A run
MUST NOT stall indefinitely.

### 10.6 Token Usage Telemetry

Codex emits two telemetry event types:

- `thread/tokenUsage/updated` — absolute totals for the thread. Use these for accounting.
- `account/rateLimits/updated` — current account-level rate-limit snapshot.

Both are journaled via `ctx.run` so the dispatch invocation's journal includes a
chronological trace of token consumption and rate-limit pressure for that issue.

Token aggregation:

- `IssueAgent` does NOT aggregate across runs in VO state; the single source of truth is
  the journal.
- The OPTIONAL JSON snapshot endpoint (Section 12) aggregates by querying recent
  invocations.
- `TenantTotals` (per-tenant counter VO) MAY be incremented on every turn end for
  cheap aggregate reporting; this is a denormalized convenience, not a source of truth.

Avoid double-counting: prefer absolute totals (`total_token_usage`) over delta payloads
(`last_token_usage`). When only deltas are available, track `last_reported_*` per-thread
in the dispatch invocation's local state and compute the delta-of-deltas.

### 10.7 Error Mapping

Codex `codexErrorInfo` enum mapped to Restate error semantics:

| Codex error | Restate handling | Notes |
|---|---|---|
| `ContextWindowExceeded` | `TerminalError("codex_context_window_exceeded")` | Continuing would re-fail; surfacing forces workflow to summarize/handoff. |
| `UsageLimitExceeded` | non-terminal retry with backoff | Restate's `RunRetryPolicy` waits and re-tries; eventually exhausts. |
| `ModelOverloaded` | non-terminal retry | Same. |
| `RateLimited` | non-terminal retry; honor `Retry-After` if Codex surfaces one | |
| `InvalidRequest` | `TerminalError` | Bug in the orchestrator; do not retry. |
| `InternalError` | non-terminal retry, capped | |
| Subprocess crash before handshake | non-terminal retry, capped | Treated as `codex_not_found` if persistent. |
| Turn timeout | `TerminalError("codex_turn_timeout")` | The current run attempt fails; the next webhook or cron tick will re-dispatch. |
| Stall timeout | `TerminalError("codex_stall_timeout")` | Same. |
| `turn_input_required` and policy says "fail" | `TerminalError("codex_turn_input_required")` | |

The categorical names are:

- `codex_not_found`
- `invalid_workspace_cwd`
- `codex_response_timeout`
- `codex_turn_timeout`
- `codex_stall_timeout`
- `codex_subprocess_exit`
- `codex_turn_failed`
- `codex_turn_cancelled`
- `codex_turn_input_required`
- `codex_context_window_exceeded`
- `codex_usage_limit_exceeded`

### 10.8 Honest Gaps

This subsection makes the architecture's known limitations explicit so implementations
plan for them rather than discover them in production.

1. **Tool execution idempotency is the user's job.** Per 10.4, the orchestrator can
   guarantee at-least-once tool execution per `call_id`, not exactly-once. Tools that
   cannot tolerate at-least-once MUST be configured with `max_attempts(1)`.

2. **Codex thread JSONL on shared FS.** This is the only durable carrier of conversation
   history between turns. NFS hiccups CAN corrupt or truncate JSONL files. Recovery: if
   `thread/resume` fails on an existing JSONL, the implementation MUST restart the thread
   from scratch (creating a new `thread_id`) and log `codex_thread_state_corrupted`.

3. **Agent non-determinism on replay.** A worker crash mid-turn forces the next attempt
   to issue `turn/start` again on a partial Codex history. The new turn may produce a
   different tool-call sequence. The journal records "what actually happened" — operators
   reviewing the audit trail MUST treat divergence between attempts as expected, not as a
   bug.

4. **`dynamicToolCall` is experimental.** A Codex upgrade can break the contract.
   `codex.version_pin` is RECOMMENDED. Operators MUST regression-test the per-tool-call
   journaling behavior before bumping Codex versions.

5. **Long-running subprocess vs Restate timeouts.** Restate has its own invocation timeout
   (configurable, default 5 minutes for service handlers; extended for VO/Workflow
   handlers — consult your Restate version-specific configuration for the exact value).
   Long Codex turns (multi-minute thinking time) are inside `ctx.run` blocks that block
   on Codex JSON-RPC reads. The implementation MUST tune Restate's per-invocation
   suspension and the run-step retry policy together; in particular, a `read_timeout_ms`
   of 5 seconds with a long poll loop is fine, but raw blocking reads that exceed
   Restate's HTTP/2 keep-alive limits will cause the worker to be considered dead. Use
   heartbeat events on the Codex stream to keep liveness reporting flowing.

6. **Restate Rust SDK is pre-1.0.** This spec targets `restate-sdk` v0.10.x. Method
   names (`name`, `retry_policy`, `initial_delay`, `max_delay`,
   `exponentiation_factor`, `object_client`/`service_client`/`workflow_client`,
   `DurableFuturesUnordered`) MAY shift across minor versions. Deployments MUST pin the
   exact `restate-sdk` version in `Cargo.toml` (e.g. `restate-sdk = "=0.10.x"`) and MUST
   regression-test on minor-version bumps.

### 10.9 Cooperative Stop Semantics

`IssueAgent.stop` does NOT use a Restate Admin cancel call (which would be an
out-of-journal effect requiring HTTP access from inside a handler). Cancellation is
cooperative:

```rust
async fn stop(&self, ctx: ObjectContext<'_>) -> Result<(), HandlerError> {
    ctx.set("stop_requested", true);
    ctx.set("stopped_at", chrono::Utc::now().to_rfc3339());
    Ok(())
}
```

Inside `dispatch`, between turns (and after any pause check), the loop reads the flag:

```rust
if ctx.get::<bool>("stop_requested").await?.unwrap_or(false) {
    // Terminate the Codex subprocess gracefully.
    if let Some(child) = current_child.take() {
        let _ = child.kill().await;
    }
    ctx.run(|| async move { release_slot(tenant_id, issue_state).await })
        .name("release_slot")
        .await?;
    return Ok(Json(DispatchOutcome::Stopped));
}
```

This design is simpler and journal-friendly: the stop signal flows through VO state
(persisted, replay-safe), and the only remaining latency is "current turn finishes or
hits its read timeout". For deployments that need hard cancellation of a wedged turn,
the `restate invocations cancel <id>` operator command (§13.7) remains available as a
break-glass path; that command does NOT integrate with the cooperative
`DispatchOutcome::Stopped` return value but does free the VO key.

## 11. Issue Tracker Integration Contract (GitHub Projects v2)

### 11.1 REQUIRED Operations

`GitHubAdapter` (Service) MUST implement:

1. `fetch_candidate_issues(tenant_id) -> Vec<Issue>`
   - Return all project items whose effective state is in `active_states`, after
     applying the terminal-OR rule (Section 11.2.1) and the `include_kinds` filter.
   - Returned values conform to the Issue domain model in Section 4.1.1.

2. `fetch_issues_by_states(tenant_id, state_names) -> Vec<Issue>`
   - Return all project items whose effective state is in the supplied list.
   - Used for terminal cleanup.
   - When `state_names` is empty, return an empty list without making any API call.

3. `fetch_issue_states_by_ids(tenant_id, issue_ids) -> Vec<IssueRef>`
   - Look up the current effective state for the given list of project item IDs.
   - Used for active-run reconciliation and webhook-hinted refresh.
   - Empty input → empty output, no API call.
   - Items that no longer exist (`nodes(ids:)` returns null, or
     `ProjectV2Item.type == REDACTED`) MUST be omitted.

4. `probe_status_field(tenant_id) -> StatusFieldInfo`
   - Section 11.2.4.

5. `mint_installation_token(tenant_id) -> InstallationToken`
   - Section 7.3.

6. `resolve_collaborator_permission(tenant_id, owner, repo, login) -> Permission`
   - Used by `CommentRouter` for authorization.

7. `execute_graphql(tenant_id, query, variables) -> GraphQlResponse`
   - Used by Codex's `github_graphql` tool.

### 11.2 Query Semantics (GitHub)

Identical to the language-agnostic edition with these adaptations:

- All queries are issued from `GitHubAdapter` handlers. Each call site wraps the HTTP
  request in `ctx.run(...).name("github_graphql:<short-name>")` with a `RunRetryPolicy` that
  honors GitHub's secondary rate-limit `Retry-After` header.
- Every query SHOULD include `rateLimit { limit cost remaining used resetAt }` and the
  service SHOULD voluntarily back off as `remaining` approaches zero by inserting
  `ctx.sleep(until_reset)` before the next call.
- Transport: HTTP POST against `tracker.endpoint`.
- Auth: `Authorization: Bearer <token>` where `<token>` is minted via
  `mint_installation_token`.
- Header `X-Github-Next-Global-ID: 1` REQUIRED.
- Network timeout per request: 30 seconds. Honored via `reqwest::ClientBuilder::timeout`.
- Pagination: REQUIRED for the project items connection. `first <= 100`. Loop until
  `pageInfo.hasNextPage == false`. Treat
  `pageInfo.hasNextPage == true && pageInfo.endCursor == null` as
  `github_missing_end_cursor`.

Two distinct rate-limit signals (same as language-agnostic edition):

- **Primary limit** — HTTP 200 + `rateLimit.remaining == 0`. Sleep until `resetAt` via
  `ctx.sleep`. Emit `github_rate_limited`.
- **Secondary limit** — HTTP 429 or HTTP 403 + `Retry-After`. Sleep at least
  `Retry-After` seconds via `ctx.sleep`. Emit `github_rate_limited` with the value.

When both signals are present, prefer the longer wait.

#### 11.2.1 Effective State and Terminal-OR Rule

Identical to the language-agnostic edition. An item is **terminal** when **either**:

- Lowercased effective state is in lowercased `terminal_states`, **or**
- Underlying content is closed: `Issue.state == CLOSED` or
  `PullRequest.state ∈ {CLOSED, MERGED}`.

An item is **active** only when:

- Lowercased effective state is in lowercased `active_states`, **and**
- Either `kind == draft_issue`, or the underlying content is `OPEN`.

`<no status>` items are inactive and non-terminal: do not dispatch, do not clean up.

#### 11.2.2 Candidate Items Query

The same GraphQL shape as the language-agnostic edition:

```graphql
query SymphonyProjectItems($projectId: ID!, $first: Int!, $after: String) {
  rateLimit { limit cost remaining used resetAt }
  node(id: $projectId) {
    ... on ProjectV2 {
      id title number
      items(first: $first, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id type isArchived createdAt updatedAt
          fieldValueByName(name: "Status") {
            __typename
            ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
          }
          content {
            __typename
            ... on Issue {
              id number title body url state createdAt updatedAt
              repository { nameWithOwner owner { login } name }
              labels(first: 50) { nodes { name } }
              trackedIssues(first: 50) {
                nodes { id number state repository { nameWithOwner } }
              }
            }
            ... on PullRequest {
              id number title body url state createdAt updatedAt
              isDraft merged mergedAt closedAt headRefName baseRefName
              reviewDecision mergeable mergeStateStatus
              repository { nameWithOwner owner { login } name }
              labels(first: 50) { nodes { name } }
              latestOpinionatedReviews(first: 50, writersOnly: true) {
                nodes { state author { login } submittedAt }
              }
              reviewThreads(first: 50) {
                nodes { id isResolved isOutdated }
              }
              reviewRequests(first: 20) {
                nodes {
                  requestedReviewer {
                    __typename
                    ... on User { login }
                    ... on Team { slug }
                    ... on Mannequin { login }
                  }
                }
              }
              commits(last: 1) {
                nodes {
                  commit {
                    oid
                    statusCheckRollup { state }
                  }
                }
              }
            }
            ... on DraftIssue {
              id title body createdAt updatedAt
            }
          }
        }
      }
    }
  }
}
```

Archived items (`isArchived == true`) are filtered before normalization.

#### 11.2.3 Issue State Refresh Query

```graphql
query SymphonyRefresh($ids: [ID!]!) {
  rateLimit { remaining resetAt }
  nodes(ids: $ids) {
    __typename
    ... on ProjectV2Item {
      id type isArchived
      fieldValueByName(name: "Status") {
        ... on ProjectV2ItemFieldSingleSelectValue { name }
      }
      content {
        __typename
        ... on Issue       { id number state repository { nameWithOwner } }
        ... on PullRequest { id number state merged repository { nameWithOwner } }
        ... on DraftIssue  { id }
      }
    }
  }
}
```

#### 11.2.4 Status Field Probe

```graphql
query SymphonyStatusFieldProbe($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      field(name: "Status") {
        __typename
        ... on ProjectV2SingleSelectField { id name options { id name } }
      }
    }
  }
}
```

`field == null` → `tracker_status_field_missing`.
`field.__typename != "ProjectV2SingleSelectField"` → same error.

The probe is REQUIRED at `Tenant.init` and `Tenant.update_config` when the project
identifier or `status_field` changed.

### 11.3 Normalization Rules

Same as the language-agnostic edition. Key points:

- `kind` from `ProjectV2Item.type` (`ISSUE` → `issue`, `PULL_REQUEST` → `pull_request`,
  `DRAFT_ISSUE` → `draft_issue`). `REDACTED` items skipped silently.
- Items whose `content` resolves to null skipped silently.
- `id` is `ProjectV2Item.id` (the Project item node ID, not the underlying Issue/PR ID).
- `identifier`: `<owner>/<repo>#<number>` for `issue`/`pull_request`; `draft:<short>` for
  `draft_issue`.
- `labels` lowercased; empty for `draft_issue`.
- `priority` from `tracker.priority_field` per Section 5.3.1; falls back to label parsing
  (`priority:<n>`) when no field signal.
- `blocked_by` from `Issue.trackedIssues.nodes`; PRs and Draft Issues have no blockers in
  v1. The candidate query fetches the first 50; pagination is OPTIONAL.
- PR fields populated only for `pull_request` kind. `null` `reviewDecision` preserved
  distinctly from `REVIEW_REQUIRED`.
- `branch_name` is `headRefName` for PRs; null otherwise.
- `issue_state` is `Issue.state` for issues, `pr.state` for PRs, null for Draft Issues.

### 11.4 Error Handling Contract

Error categories (mapped to typed Rust errors that implement `Into<HandlerError>`):

- `unsupported_tracker_kind`
- `missing_tracker_api_token`
- `missing_tracker_project_identifier`
- `tracker_project_not_found`
- `tracker_status_field_missing`
- `tracker_permission_denied` — HTTP 401, 403 without `Retry-After`, or HTTP 200 with
  `FORBIDDEN`/`INSUFFICIENT_SCOPES` GraphQL error. Treated as `TerminalError` so the
  tenant is blocked from dispatch until config is fixed.
- `github_api_request` (transport failures) — non-terminal, retried.
- `github_api_status` (non-200 HTTP) — non-terminal unless explicitly mapped above.
- `github_rate_limited` — non-terminal; the wrapping `ctx.run` step uses `ctx.sleep`
  before retrying.
- `github_graphql_errors` — non-terminal.
- `github_unknown_payload` — non-terminal.
- `github_missing_end_cursor` — `TerminalError` (pagination integrity is non-recoverable
  without operator inspection).
- `unsupported_pr_signal` — `TerminalError` at preflight.

Extension errors (defined in their respective appendices):

- `webhook_secret_missing`, `webhook_port_in_use` (Appendix A)
- `comment_commands_bot_login_missing`, `comment_commands_token_insufficient`,
  `comment_commands_requires_webhook` (Appendix B)

### 11.5 Tracker Writes

Symphony does NOT issue tracker mutations from the orchestrator. All Issue/PR/Project
mutations (Status changes, comments, labels, sub-issue filing, PR linkage) are performed
by Codex via the `github_graphql` client-side tool (Section 10.3). This keeps the
orchestrator a strict read-only consumer of the tracker.

The `github_graphql` tool is exposed to Codex as a `dynamicToolCall`. The Symphony-side
implementation:

```rust
async fn github_graphql_tool(
    tenant_id: &str,
    args: &GithubGraphqlArgs,
) -> Result<ToolResult, ToolError> {
    if args.query.trim().is_empty() {
        return Err(ToolError::invalid("query is empty"));
    }
    // Reject multi-operation documents.
    if count_operations(&args.query) != 1 {
        return Err(ToolError::invalid("query must contain exactly one operation"));
    }
    let response = github_adapter::execute_graphql(
        tenant_id,
        &args.query,
        &args.variables,
    ).await?;
    Ok(ToolResult::ok(serde_json::to_value(&response)?))
}
```

Tool result semantics (preserving the language-agnostic edition's contract):

- HTTP success + no top-level GraphQL `errors` → `success=true`.
- Top-level GraphQL `errors` present → `success=false`; preserve the response body for
  debugging.
- HTTP 429 / `Retry-After` → `success=false` with `retry_after_seconds` in error
  payload. The model MAY back off voluntarily. The tool itself MUST NOT block waiting.
- Invalid input, missing auth, transport failure → `success=false` with error envelope.

### 11.6 Required GitHub Token Permissions

Symphony separates **core** scopes (required for the orchestrator's read-only tracker
plane) from **comment-plane** scopes (required only when Appendix B is enabled).

Core scopes — REQUIRED for every deployment:

- `Repository`: `Contents: Read & write` (for `git push` from Codex), `Issues: Read &
  write`, `Pull requests: Read & write`, `Metadata: Read`.
- `Organization`: `Projects: Read & write` (REQUIRED for Projects v2 access — this is
  what unlocks the GraphQL `ProjectV2`/`ProjectV2Item` types).

Comment-plane scopes — REQUIRED only when `comment_commands.enabled == true`:

- The collaborator-permission endpoint
  `GET /repos/{owner}/{repo}/collaborators/{login}/permission` is the authorization
  primitive (Appendix B.4). Per GitHub's documentation this endpoint is gated by repo-
  level `Metadata: Read` (already in the core scopes above) and returns the
  effective permission merging direct collaborator grants and team-membership grants.
- `Organization`: `Members: Read` is RECOMMENDED but not strictly required for the
  comment-plane authorization flow. It exposes org-team affiliations for diagnostics
  and for any operator-side audit tooling that lists which org members can run
  commands. Implementations that omit it MAY find some diagnostic surfaces less
  informative but the command-permission decision still works.

Preflight behavior:

- The startup probe in `Tenant.init` / `update_config` calls the
  collaborator-permission endpoint with the configured `bot_login` against a sample
  repository under the tenant's project. A 401/403 response raises
  `comment_commands_token_insufficient`. Dispatch is NOT blocked, but operators are
  warned that command authorization will fail until the token is corrected.
- The legacy phrasing "silently rejects every command" overstated the failure mode;
  failures are visible in receiver logs (`comment_command_unauthorized`) and the
  startup probe surfaces the misconfiguration.

PAT auth equivalents:

- Classic PAT: `repo`, `read:project`. Add `read:org` only when team-membership
  diagnostics are required.
- Fine-grained PAT: repository permissions matching the core scopes above. Note that
  fine-grained PAT `Members: Read` is an **organization-scoped** permission (not
  repository-scoped); a fine-grained PAT issued for a single repository CANNOT request
  it. Tenants that require team-membership diagnostics MUST issue an organization-
  scoped fine-grained PAT or use GitHub App auth.

### 11.7 PR Review and CI Awareness Extension

See Appendix C. The extension is purely additive: when not configured, behavior matches
Section 11.2.1 exactly.

## 12. Logging, Status, and Observability

### 12.1 Restate Admin UI and SQL Are Primary

Operators get observability primarily from Restate, not from a Symphony custom dashboard:

- **Restate Admin UI** — visual journal browser, invocation timeline, state inspection.
- **`restate sql`** — DataFusion SQL over the durable journal:
  - `sys_invocation` — every invocation, status, target, key, retry count.
  - `sys_journal` — every `ctx.run` step, every state mutation, every awakeable.
  - `sys_state` — current VO state per key.
  - `sys_promise` — durable promises and their resolution state.
- **`restate invocations describe <id>`** — full journal for one invocation.
- **`restate state get <Service>/<key>`** — VO state inspection.
- **`restate invocations cancel <id>`** / **`pause <id>`** / **`resume <id> --deployment <new>`** —
  surgical control of stuck invocations.

Common operator queries:

```sql
-- Per-tenant in-flight work
SELECT id, target, status, created_at
FROM sys_invocation
WHERE target_key LIKE 'acme-prod:%'
  AND status NOT IN ('completed', 'cancelled')
ORDER BY created_at DESC;

-- Per-tenant token usage in the last hour.
-- NOTE: substitute the JSON extraction function provided by your Restate version's
-- DataFusion build (commonly `json_extract`, but some versions expose `json_get_str`
-- or similar). Consult `restate sql --help` or the version-specific docs.
SELECT t.tenant_id, SUM(t.tokens) AS total
FROM ( SELECT split_part(target_key, ':', 1) AS tenant_id,
              CAST(json_extract(result, '$.total_tokens') AS BIGINT) AS tokens
       FROM sys_journal
       WHERE step_name LIKE 'turn:%:tokens'
         AND created_at > now() - interval '1 hour' ) t
GROUP BY t.tenant_id;

-- Stalled IssueAgent dispatches
SELECT id, target_key, created_at
FROM sys_invocation
WHERE target_service = 'IssueAgent'
  AND status = 'running'
  AND created_at < now() - interval '1 hour';
```

### 12.2 Logging Conventions

Every Symphony log line MUST include:

- `tenant_id`
- `restate_invocation_id` (from `ctx.invocation_id()` when inside a handler)
- `step_name` (when inside a `ctx.run` block)

Issue-related logs additionally include:

- `issue_id`, `issue_identifier`, `issue_kind`, `repository`.

Codex session logs additionally include:

- `session_id`, `thread_id`, `turn_id`.

Format: structured JSON by default (`SYMPHONY_LOG_FORMAT=json`). Text format (`text`)
RECOMMENDED only for local development. Use the `tracing` crate with
`tracing-subscriber`'s JSON formatter.

### 12.3 OPTIONAL `/api/v1/state` REST Endpoint

A custom Symphony JSON view is OPTIONAL. When present, it MUST be served by a Symphony
worker (not by Restate) on a dedicated port (default `9090`).

Suggested response shape (realistic GitHub identifiers):

```json
{
  "tenant_id": "acme-prod",
  "generated_at": "2026-05-09T17:25:30Z",
  "counts": {
    "running": 3,
    "paused": 1,
    "gated": 2,
    "epics_active": 1
  },
  "running": [
    {
      "issue_id": "PVTI_lADOBcd_eM4AF6gQzgKZ1aw",
      "issue_identifier": "openai/symphony#42",
      "kind": "issue",
      "repository": "openai/symphony",
      "state": "In Progress",
      "session_id": "thread-9f8e-turn-3",
      "turn_count": 7,
      "last_event": "turn_completed",
      "last_message": "wired up workspace lifecycle hooks",
      "started_at": "2026-05-09T16:55:12Z",
      "last_event_at": "2026-05-09T17:24:59Z",
      "restate_invocation_id": "inv_01HW9C8X7N3R5K2T4Y6Z8B0Q1A",
      "tokens": {
        "input_tokens": 12500,
        "output_tokens": 4200,
        "total_tokens": 16700
      }
    }
  ],
  "paused": [
    {
      "issue_id": "PVTI_lADOBcd_eM4AF6gQzgKZ1bx",
      "issue_identifier": "openai/symphony#43",
      "reason": "operator pause via @symphony[bot] pause",
      "requested_by": "alice",
      "requested_at": "2026-05-09T17:00:00Z",
      "awakeable_id": "awk_01HW9CABCD..."
    }
  ],
  "gated": [
    {
      "issue_id": "PVTI_lADOBcd_eM4AF6gQzgKZ1cy",
      "issue_identifier": "openai/symphony#100",
      "kind": "issue",
      "state": "Todo",
      "reason": "blocked_on_dependencies",
      "blockers": [
        {"identifier": "openai/symphony#101", "state": "OPEN"},
        {"identifier": "openai/symphony#102", "state": "OPEN"}
      ]
    }
  ],
  "epics_active": [
    {
      "epic_id": "PVTI_lADOBcd_eM4AF6gQzgKZ200",
      "epic_identifier": "openai/symphony#200",
      "status": "AwaitingSubIssues",
      "sub_issue_count": 5,
      "sub_issues_complete": 2,
      "started_at": "2026-05-08T09:00:00Z",
      "restate_workflow_id": "wf_01HW8X..."
    }
  ],
  "totals": {
    "input_tokens": 124000,
    "output_tokens": 41000,
    "total_tokens": 165000,
    "seconds_running": 18342.5
  },
  "rate_limits": {
    "github": {
      "remaining": 4200,
      "reset_at": "2026-05-09T17:30:00Z"
    },
    "codex": null
  },
  "webhook": {
    "enabled": true,
    "deliveries_received": 1234,
    "deliveries_dropped": 2,
    "last_event_at": "2026-05-09T18:00:00Z"
  }
}
```

When `webhook.enabled == true`, the `webhook` sub-object is REQUIRED in the snapshot
response. Operators rely on `deliveries_received`, `deliveries_dropped`, and
`last_event_at` to detect silent webhook failure (e.g. expired secret, GitHub-side
delivery suspension, downstream queue overflow). When `webhook.enabled == false`, the
sub-object MAY be omitted or set to `{ "enabled": false }`.

The endpoint composes its response by:

1. Querying Restate's `sys_invocation` table for in-flight `IssueAgent.dispatch`
   invocations for the tenant.
2. Reading `IssueAgent` VO state via `Tenant.config()` and individual
   `IssueAgent.status()` calls.
3. Reading `Epic` workflow state via `restate state get Epic/<key>`.

### 12.4 Token Accounting

Implementations MUST follow these rules when aggregating token counts for dashboard or
API totals:

1. Prefer absolute thread totals (e.g. `thread/tokenUsage/updated`) over delta-style
   payloads. Absolute totals are idempotent under replay; deltas double-count.
2. Ignore delta-style payloads such as `last_token_usage` for dashboard / API totals.
   They may be retained in the journal for diagnostic purposes only.
3. Do NOT treat generic `usage` maps as cumulative unless the originating event type
   explicitly defines them as cumulative.
4. Extract input / output / total counts leniently from common field names within the
   selected payload (e.g. `input_tokens`, `prompt_tokens`, `total_tokens`,
   `completion_tokens`, `output_tokens`); a missing field MUST be treated as zero, not
   as "data unavailable".
5. Track deltas relative to the last-reported absolute totals to avoid double-counting
   on replay. The reference implementation stores
   `last_reported_{input,output,total}_tokens` in dispatch invocation local state and
   computes the delta when emitting per-turn telemetry.

`TenantTotals` VO is OPTIONAL — see Section 10.6.

### 12.5 Rate-Limit Tracking

- `account/rateLimits/updated` payloads journaled per turn.
- The OPTIONAL snapshot endpoint reports the latest seen value per tenant.

### 12.6 Humanized Event Summaries

OPTIONAL. When implemented, treat as observability output only — never gate orchestrator
logic on humanized strings.

## 13. Failure Model and Recovery

This section is dramatically simpler than the language-agnostic edition. Restate's durable
journal eliminates most of the "in-memory state lost on restart" failure modes.

### 13.1 Failure Classes

1. **Workflow / Config Failures** (per-tenant)
   - Missing `WORKFLOW.md`, invalid YAML, unsupported tracker kind, missing
     credentials, missing project, missing status field.
   - Effect: tenant blocked from dispatch; other tenants unaffected.

2. **Workspace Failures**
   - Workspace directory creation failure (FS error, quota, permissions).
   - Hook timeout/failure.
   - Effect: current `IssueAgent.dispatch` invocation surfaces a non-terminal error;
     Restate retries per the run policy. After exhausted retries, the dispatch fails;
     the next webhook or cron-driven dispatch will retry from scratch.

3. **Codex Session Failures**
   - Subprocess crash, turn failed/cancelled, turn timeout, stall, user-input-required
     handled-as-failure.
   - Effect: per Section 10.7. Most map to `TerminalError` of the current dispatch
     invocation; the next webhook or cron-driven dispatch will re-enter the loop.

4. **Tracker Failures**
   - Transport, non-200, GraphQL errors, malformed payloads.
   - Effect: non-terminal retry inside the wrapping `ctx.run` step. After max retries,
     the calling handler fails; the next tick retries.

5. **Restate Connectivity Failures**
   - Symphony worker cannot reach Restate Server (network split, Restate restart).
   - Effect: in-flight handler invocations are paused on Restate's side; they resume
     when the worker reconnects. No data loss.

### 13.2 Replay Semantics

Restate's durable journal is the source of truth. On worker crash or Restate failover:

- Every `ctx.run` step that completed successfully is **skipped on replay** — the
  journaled result is reused.
- Every step that did not complete is **re-executed** — closures must be safe to
  re-run.
- Awakeables, durable promises, sleep timers all persist across crashes.

Implications for handler authors:

- All side effects MUST be inside `ctx.run` so they participate in the journal.
- Random number generation, current-time reads, UUID generation MUST also be inside
  `ctx.run` (otherwise replay produces a different value than the original execution).
  Use `ctx.run(|| async { Ok(SystemTime::now()) }).name("now")` for time, etc.
- Closures inside `ctx.run` MUST be deterministic given their inputs (or use the journal
  to capture non-determinism).

### 13.3 Idempotency Across Replay

The `ctx.run(...).name("<step_name>")` mechanism gives at-most-once **journaling** of the
step's result. The closure itself runs at-least-once (re-run on replay if not
journaled). For side-effecting closures, idempotency at the closure boundary is the
caller's responsibility:

- Tool execution: idempotency keyed by `call_id` (Section 10.4).
- GitHub mutations: idempotency via `clientMutationId` or pre-existence checks.
- Workspace writes: keyed by `(tenant_id, issue_id)` — overwriting the same workspace
  is idempotent.
- Subprocess spawn: NOT idempotent; tolerated via `kill_on_drop` and Codex's JSONL
  exclusivity.

### 13.4 Terminal vs Transient Errors

- `TerminalError::new(reason)` — surfaced to the caller; **not retried** by Restate.
  Use for unrecoverable business failures.
- All other `Result::Err(_)` — retried per the active `RunRetryPolicy`.

Choose `TerminalError` for:

- Missing/invalid configuration.
- Permanent authorization failures (`tracker_permission_denied`).
- Codex `ContextWindowExceeded` (continuing would re-fail).
- Pagination integrity (`github_missing_end_cursor`).
- Validation failures.

Choose non-terminal for:

- Transport errors, 5xx responses, timeouts.
- Rate limits (with `ctx.sleep` then retry).
- `UsageLimitExceeded`, `ModelOverloaded`.

### 13.5 Deployment-Pinned Invocations

Restate pins each in-flight invocation to the **deployment ID** that started it. This
matters for long-running workflows:

- A 7-day `Epic.handoff` await pins that `Epic` workflow to whichever Symphony
  deployment was live when it started.
- If that deployment is decommissioned, the workflow cannot resume.

Recommended discipline:

- Avoid removing or renaming `ctx.run` step names within a release. Adding new steps in
  later release is safe, since older invocations don't reach them.
- For long-horizon workflows like `Epic`, prefer **delayed self-sends** over single
  `ctx.sleep` calls of multi-day duration. See Section 16.4.
- Major refactors of journaled flow MUST go through a deprecation cycle: deploy the new
  version side-by-side, drain old invocations to completion, then remove the old code.

### 13.6 Hotfix Flow (Pause / Resume to New Deployment)

When a stuck invocation needs surgical intervention:

```
restate invocations describe inv_01HW9...
restate invocations pause inv_01HW9...
# (deploy fix)
restate invocations resume inv_01HW9... --deployment dep_01HW9...
```

The `--deployment <new_deployment_id>` flag re-pins the invocation to the freshly
deployed code, allowing it to continue under fixed logic.

### 13.7 Operator Intervention Points

- Editing the tenant's workflow content and calling `Tenant.update_config`.
- Calling `IssueAgent.pause`, `resume`, `stop` directly via `restate ingress` or
  Restate's Admin UI.
- Resolving awakeables via `POST /restate/awakeables/<id>/resolve`.
- Resolving durable promises via the workflow's shared submission handler.
- `restate invocations cancel <id>` for stuck handlers.
- Restarting Symphony workers — safe; in-flight invocations are paused on Restate's side
  and resume when workers reconnect.

## 14. Security and Operational Safety

### 14.1 Trust Boundary Assumption

Each implementation defines its own trust boundary. Symphony in this edition supports
multi-tenant deployments, which means the trust boundary spans:

- Symphony workers (one trust domain per deployment).
- Restate Server (one trust domain per cluster; per-tenant clusters give hard isolation
  per Section 15.4).
- Per-tenant credentials (each tenant's GitHub App installation token / PAT MUST never
  be exposed to a different tenant).
- Per-tenant workspaces on shared FS (Section 9.5 invariants enforce containment).

### 14.2 Filesystem Safety Requirements

Mandatory:

- Workspace path MUST stay under `<SHARED_FS_ROOT>/<tenant_id>/`.
- Codex cwd MUST equal the per-issue workspace path (verified after canonicalization).
- Workspace directory names MUST be sanitized.
- Symphony worker process MUST run as a unix user that has read/write to
  `<SHARED_FS_ROOT>` only — not to Symphony binaries, deployment env vars, or other
  tenants' workspaces. Per-tenant unix users are RECOMMENDED for hard FS isolation.

### 14.3 Secret Handling

- Credentials are NEVER stored in VO state — only `*_ref` (env var name) is.
- Access tokens minted on demand inside `ctx.run` (Section 7.3) are journaled into the
  Restate durable store. The store's encryption-at-rest and access controls determine
  the tokens' confidentiality.
- Symphony logs MUST NOT include token values. The `tracing` setup MUST install a
  redaction layer that strips fields named `*_token`, `Authorization`, `secret`,
  `private_key`, `webhook_secret`.

### 14.4 Hook Script Safety

- Hooks are arbitrary shell scripts from `WORKFLOW.md`.
- Hooks are fully trusted configuration — a malicious tenant `WORKFLOW.md` could ask
  Symphony to run arbitrary shell.
- Mitigation: tenant onboarding MUST include a code-review step on `WORKFLOW.md`
  changes, and `Tenant.update_config` MAY require an out-of-band approval flag for
  hook changes.
- Hook output truncated to 4 KB in logs.
- Hook timeouts REQUIRED.

### 14.5 Harness Hardening Guidance

Running Codex against repositories, tracker data, and tool outputs MUST be treated as a
sandboxing problem. Implementations SHOULD:

- Tighten `codex.approval_policy` and `codex.thread_sandbox` for low-trust tenants.
- Add OS/container/VM sandboxing around the Codex subprocess, especially when the
  workspace contains untrusted code.
- Filter which Issues, PRs, repositories, projects, owners, or labels are eligible for
  dispatch via `tracker.repo`, `include_kinds`, label filters in `WORKFLOW.md`, etc.
- Narrow the `github_graphql` tool's effective scope per deployment — implementations
  MAY enforce mutation denylists, restrict variables to the configured project ID, or
  disable mutations for read-only deployments.
- Reduce the set of client-side tools, env vars, FS paths, and network destinations
  available to the Codex subprocess.

Operational hardening checklist (deployment-time):

- Run Symphony as a unix user with read/write access only to `<SHARED_FS_ROOT>` —
  not to Symphony binaries, deployment env vars, or other tenants' workspaces. Use
  per-tenant unix users for hard FS isolation between tenants.
- Do NOT expose Restate Admin UI publicly. Place it behind a VPN or
  authenticating reverse proxy; the Admin UI grants destructive operator powers
  (cancel, pause/resume, state delete) and has no built-in authentication.
- The Symphony binary SHOULD NOT have write access to its own deployment
  directory. Read-only mounts (or distroless containers with read-only rootfs) are
  RECOMMENDED for production.
- Log redaction MUST cover at minimum: `installation_id`, the raw HMAC webhook
  secret, the GitHub App private key path and its contents, and any token strings.
  Implementations SHOULD verify redaction with a test that grep's known sensitive
  values against the log output of a representative dispatch.
- Per-tenant secrets (webhook secrets, App private keys, PATs) MUST be stored in
  a secret manager (Vault, AWS Secrets Manager, GCP Secret Manager, Kubernetes
  Secrets with envelope encryption). They MUST NOT be persisted in VO state; only
  `*_ref` (env var name) is persisted.
- Hooks (`bash -lc` shell scripts in `WORKFLOW.md`) run as the Symphony worker
  user. Tighten file permissions on the workspace root if hooks should not be
  able to read other tenants' workspaces. Per-tenant unix users (above) is the
  strong containment.
- In multi-tenant mode running adversarial or low-trust workloads, consider
  OS-level isolation: per-tenant unix users, per-tenant chroot jails, per-tenant
  containers, or per-tenant VMs. The shared-cluster soft-isolation model
  (§15.2) is appropriate for cooperating internal tenants only.

### 14.6 Restate-Specific Operational Gotchas

- **Don't sleep in exclusive Virtual Object handlers when other handlers need to make
  progress.** Long `ctx.sleep` inside an exclusive handler blocks all other exclusive
  handlers for that key. For long waits, use awakeables or split the work across
  invocations (delayed self-send).
- **Non-determinism on replay.** Adding/removing `ctx.run` step names between deploys
  can strand pinned invocations. Section 13.5 covers the mitigation.
- **Two systems to operate.** Restate Server and Symphony are separate processes with
  separate failure modes. Operators MUST monitor both.
- **Journal storage cost.** Every `ctx.run` step is journaled. High-volume tools (e.g.
  thousands of small file reads inside one turn) will inflate journal storage. Consider
  consolidating fine-grained tools or capping journal retention.
- **Restate version compatibility.** This spec targets Restate Server v1.4+. Older
  versions lack `restate sql`; later versions may change SDK APIs. Pin both.

## 15. Multi-Tenancy

This section is first-class because the deployment topology of "one Symphony cluster, N
tenants" is novel relative to the language-agnostic edition.

### 15.1 Tenancy Model

A **tenant** is an isolation unit defined by:

- A `tenant_id` (opaque slug).
- A `Tenant` Virtual Object holding parsed config and credential references.
- One GitHub Project v2 (the tenant's `tracker.project_id`).
- One GitHub App installation (or one PAT).
- A per-tenant workspace root under `<SHARED_FS_ROOT>/<tenant_id>/`.
- Per-tenant `SymphonyCron` and `ReconcileCron` Virtual Objects.
- A per-tenant concurrency cap enforced by `TenantSlots`.

### 15.2 Soft Isolation (Shared Cluster)

The default deployment model is **soft isolation** on a shared Restate cluster:

- All tenants share one Restate cluster.
- Tenant boundaries are enforced by key-prefix conventions (Section 7.2).
- A bug or compromise in Symphony code can read/write across tenants. Tenant data is
  protected by code-review discipline, not by the runtime.

This is appropriate for:

- Internal teams operating multiple Projects in one organization.
- Cooperating tenants under one ops umbrella.
- Development and staging.

### 15.3 Per-Tenant Concurrency Caps

`TenantSlots` (Virtual Object, key = `tenant_id`):

```rust
#[restate_sdk::object]
pub trait TenantSlots {
    async fn acquire(req: Json<AcquireReq>) -> Result<Json<AcquireOutcome>, HandlerError>;
    async fn release(req: Json<ReleaseReq>) -> Result<(), HandlerError>;

    #[shared]
    async fn snapshot() -> Result<Json<SlotsSnapshot>, HandlerError>;
}
```

State keys:

- `running_total` (integer)
- `per_state_running` (map state → integer)
- `max_total` (integer, refreshed from `Tenant.config`)
- `max_per_state` (map, refreshed from `Tenant.config`)

`acquire` returns `false` (without modifying state) when caps would be exceeded.
`IssueAgent.dispatch` calls `acquire` at the top; on `false` it returns
`DispatchOutcome::Throttled`, and the next webhook / cron tick will reschedule.

Cleanup on dispatch exit: every `dispatch` invocation MUST emit a
`ctx.run(...).name("release_slot")` step in a Drop-equivalent path. Restate's
journal-replay-on-cancellation guarantees the release step runs even if the handler is
cancelled mid-flight.

### 15.4 Hard Isolation (Per-Tenant Clusters)

Hard tenant isolation REQUIRES per-tenant Restate clusters:

- One Restate Server (or HA cluster) per tenant.
- One Symphony deployment per tenant, configured to register with the tenant's Restate.
- Cross-tenant access is impossible at the runtime level.

This model is what Restate Cloud offers commercially. Self-hosted deployments achieve
the same by running N Restate clusters.

Implementations MUST document which model they support. The reference Symphony
implementation supports both via deployment configuration (`SYMPHONY_RESTATE_INGRESS_URL`
points to one cluster; one deployment per tenant achieves hard isolation).

### 15.5 Per-Tenant Audit Isolation

Operators query per-tenant data via the key-prefix convention:

```sql
SELECT id, target, status, created_at, completed_at
FROM sys_invocation
WHERE target_key LIKE 'acme-prod:%'
   OR (target_service IN ('Tenant', 'SymphonyCron', 'ReconcileCron', 'TenantSlots')
       AND target_key = 'acme-prod')
ORDER BY created_at DESC
LIMIT 200;
```

For hard-isolated deployments, the SQL query targets only that tenant's Restate cluster
— no cross-tenant query is possible.

### 15.6 Resource Caps and Fairness

Implementations SHOULD enforce per-tenant caps on:

- Concurrent `IssueAgent.dispatch` invocations (`agent.max_concurrent_agents`).
- Concurrent active `Epic` workflows.
- Total tokens consumed per hour / per day (informational; surfaces in alerts).

`Tenant.config` carries these caps; `TenantSlots.acquire` and `Epic.run` read them at
the relevant decision points.

Cluster-wide global caps (across all tenants) MAY be enforced via deployment
configuration (e.g. a single `MAX_GLOBAL_DISPATCHES` env var checked by `IssueAgent.dispatch`
before `acquire`). This protects the shared cluster from a single misbehaving tenant
exhausting Restate workers.

### 15.7 Tenant Lifecycle

Provisioning:

```
restate ingress send Tenant/acme-prod init '{"workflow_blob": "...", "github_app_installation_id": 123456}'
```

Update:

```
restate ingress send Tenant/acme-prod update_config '{"workflow_blob": "..."}'
```

Decommission (informative; not normative):

1. `restate ingress send Tenant/acme-prod stop_all_dispatch` (custom handler, OPTIONAL).
2. Wait for in-flight invocations to drain.
3. `restate state delete Tenant/acme-prod`.
4. Optionally archive workspace and journal data to cold storage.

## 16. Long-Horizon Workflows: Epic

`Epic` is the canonical multi-day workflow demonstrating Restate's value. The lifecycle:
decompose → fan-out sub-issues → integration test → handoff awakeable → done.

### 16.1 EpicRequest

```rust
#[derive(Serialize, Deserialize, Clone)]
pub struct EpicRequest {
    pub tenant_id: String,
    pub epic_issue_node_id: String,
    pub epic_identifier: String,
    pub handoff_timeout_days: Option<u32>,
}

#[derive(Serialize, Deserialize)]
pub struct EpicResult {
    pub approver: String,
    pub sub_results: Vec<DispatchOutcome>,
    pub integration: IntegrationOutcome,
}

#[derive(Serialize, Deserialize)]
pub enum EpicStatus {
    Decomposing,
    AwaitingSubIssues,
    Integration,
    AwaitingHandoff,
    Done,
    Failed,
}
```

### 16.2 Workflow Skeleton

```rust
#[restate_sdk::workflow]
pub trait Epic {
    async fn run(req: Json<EpicRequest>) -> Result<Json<EpicResult>, HandlerError>;

    #[shared]
    async fn submit_handoff(approver: Json<String>) -> Result<(), HandlerError>;

    /// Reject the handoff promise (e.g. from a HandoffWatcher tick that detected the
    /// configured deadline elapsed). Used by the long-horizon pattern in §16.4.
    #[shared]
    async fn reject_handoff(reason: Json<HandoffRejection>) -> Result<(), HandlerError>;

    #[shared]
    async fn status() -> Result<Json<EpicStatus>, HandlerError>;
}

pub struct EpicImpl { /* deps */ }

impl Epic for EpicImpl {
    async fn run(
        &self,
        ctx: WorkflowContext<'_>,
        Json(req): Json<EpicRequest>,
    ) -> Result<Json<EpicResult>, HandlerError> {
        ctx.set("status", EpicStatus::Decomposing);

        let sub_issues: Vec<SubIssueRef> = ctx
            .run(|| async move { decompose_via_codex(&req).await })
            .name("decompose")
            .retry_policy(
                RunRetryPolicy::default()
                    .max_attempts(3)
                    .max_delay(Duration::from_secs(60)),
            )
            .await?;

        ctx.set("sub_issues", sub_issues.clone());
        ctx.set("status", EpicStatus::AwaitingSubIssues);

        // Dynamic-N parallel fan-out via DurableFuturesUnordered.
        use restate_sdk::context::DurableFuturesUnordered;
        let mut futures = DurableFuturesUnordered::new();
        for s in &sub_issues {
            futures.push(
                ctx.object_client::<IssueAgentClient>(format!("{}:{}", req.tenant_id, s.issue_id))
                    .dispatch(Json(DispatchReq::for_sub_issue(s)))
                    .call(),
            );
        }
        let mut sub_results: Vec<DispatchOutcome> = Vec::with_capacity(sub_issues.len());
        while let Some((_index, result)) = futures.next().await? {
            sub_results.push(result?.into_inner());
        }

        ctx.set("status", EpicStatus::Integration);

        let integration = ctx
            .run(|| async move { run_integration_via_codex(&req).await })
            .name("integration_test")
            .retry_policy(RunRetryPolicy::default().max_attempts(3))
            .await?;

        ctx.set("status", EpicStatus::AwaitingHandoff);

        // Short-timeout fast path: a single ctx.sleep is acceptable when the timeout is
        // smaller than half the deployment cadence (see §13.5 deployment-pinning warning
        // and §16.4). For longer timeouts, prefer the delayed-self-send pattern below.
        let timeout_days = req.handoff_timeout_days.unwrap_or(7) as u64;
        let approver = match restate::select! {
            approval = ctx.promise::<String>("handoff").value() => SelectResult::Approval(approval?),
            _ = ctx.sleep(Duration::from_secs(timeout_days * 86_400)) => SelectResult::Timeout,
        } {
            SelectResult::Approval(name) => name,
            SelectResult::Timeout => {
                ctx.set("status", EpicStatus::Failed);
                return Err(TerminalError::new("epic_handoff_timeout").into());
            }
        };

        ctx.set("status", EpicStatus::Done);

        Ok(Json(EpicResult {
            approver,
            sub_results,
            integration,
        }))
    }

    async fn submit_handoff(
        &self,
        ctx: SharedWorkflowContext<'_>,
        Json(approver): Json<String>,
    ) -> Result<(), HandlerError> {
        ctx.promise::<String>("handoff").resolve(approver);
        Ok(())
    }

    async fn status(
        &self,
        ctx: SharedWorkflowContext<'_>,
    ) -> Result<Json<EpicStatus>, HandlerError> {
        let status: EpicStatus = ctx
            .get("status").await?
            .unwrap_or(EpicStatus::Decomposing);
        Ok(Json(status))
    }
}
```

### 16.3 Decomposition Step

`decompose_via_codex` spawns a one-shot Codex turn whose prompt is "decompose this epic
into sub-issues, file each as a GitHub Issue with `tracked_in` linkage, and return the
list." The output is a `Vec<SubIssueRef>` with each `issue_id` pointing to a freshly
created Project v2 item.

The decomposition step is itself a Codex session — implementations MAY reuse
`AgentRuntime.execute_tool` for `github_graphql` mutations or run a dedicated
"decomposer" subprocess.

### 16.4 Long Sleeps and Deployment Pinning

A multi-day `ctx.sleep` pins the Workflow invocation to the deployment that started it
(see §13.5). The single `ctx.sleep(timeout_days * 86_400)` shown in §16.2 is presented
as a **fast path** for short handoff timeouts; it is convenient but it forecloses
redeploys for the entire wait. Implementations MUST NOT rely on a single sleep longer
than half the deployment cadence (e.g. if you redeploy weekly, do not exceed roughly
3-day inline sleeps).

A Workflow's `run` handler is exactly-once per workflow ID — once it returns, the
workflow is terminal and cannot be resumed in place. Therefore "self-checkpoint and
re-enter the same workflow ID later" is NOT a viable pattern; the spec rejects any
shape that tries to do this.

For handoff timeouts that may span multiple deploys, the recommended pattern is the
**`HandoffWatcher` Virtual Object cron** (defined below). The watcher is a separate
self-rescheduling object whose ticks are short enough to release the deployment pin
between each one. The watcher polls the GitHub Project Status field (or whatever the
deployment defines as its handoff signal) and, on detection, calls
`Epic.submit_handoff` via `ctx.workflow_client::<EpicClient>(epic_key).submit_handoff(...).send()`
to resolve the parent Epic's `handoff` promise.

```rust
// Per-Epic handoff watcher. Key = "<tenant_id>:<epic_issue_node_id>".
#[restate_sdk::object]
pub trait HandoffWatcher {
    async fn start(req: WatcherStart) -> Result<(), HandlerError>;
    async fn tick() -> Result<(), HandlerError>;
    async fn cancel() -> Result<(), HandlerError>;
}

// State keys: "epic_workflow_key", "deadline_unix_ms", "poll_interval_ms",
//             "next_invocation_id", "started_at_unix_ms"

async fn tick(&self, ctx: ObjectContext<'_>) -> Result<(), HandlerError> {
    // Reschedule first (crash-safe), then work.
    let interval = ctx
        .get::<u64>("poll_interval_ms")
        .await?
        .unwrap_or(6 * 3600 * 1000); // default 6h
    ctx.object_client::<HandoffWatcherClient>(ctx.key().to_string())
        .tick()
        .send_after(Duration::from_millis(interval));

    let now = ctx.time().await? as i64;
    let deadline = ctx.get::<i64>("deadline_unix_ms").await?.unwrap_or(0);
    let epic_key = ctx
        .get::<String>("epic_workflow_key")
        .await?
        .ok_or_else(|| TerminalError::new("watcher_state_missing"))?;

    if now >= deadline {
        // Reject the parent's handoff promise so Epic.run returns the timeout error.
        ctx.workflow_client::<EpicClient>(epic_key)
            .reject_handoff(Json(HandoffRejection::Timeout))
            .send();
        return Ok(());
    }

    // Check the GitHub side for the configured handoff signal (e.g. project Status
    // == "Approved", or a label, or a specific reviewer's APPROVED review).
    if let Some(approver) = ctx
        .run(|| async move { check_for_handoff_signal(/* ... */).await })
        .name("check_handoff_signal")
        .await?
    {
        ctx.workflow_client::<EpicClient>(epic_key)
            .submit_handoff(Json(approver))
            .send();
    }
    Ok(())
}
```

`Epic.run` continues to use the simple `restate::select! { handoff = promise.value(),
timeout = ctx.sleep(...) }` form for short timeouts. For long-horizon deployments
(timeouts > half the deployment cadence), `Epic.run` SHOULD instead:

1. Start a `HandoffWatcher` for this epic (`ctx.object_client::<HandoffWatcherClient>(epic_key).start(...).send()`).
2. Await the durable promise (`ctx.promise::<String>("handoff").value().await?`)
   without an inline timeout — the watcher rejects the promise on its own deadline.
3. On Epic completion (success or rejection), cancel the watcher
   (`ctx.object_client::<HandoffWatcherClient>(epic_key).cancel().send()`).

Each watcher tick is a fresh invocation; the deployment pin lasts at most one tick
interval. This pattern is REQUIRED for any handoff timeout exceeding half the
deployment cadence; it is RECOMMENDED for any timeout above 24 hours so that operators
have a uniform observability surface across timeout scales.

Cross-reference §13.5 for the full deployment-pinning warning. The Workflow exactly-once
constraint is the load-bearing reason this pattern uses a separate Virtual Object,
not the same workflow.

### 16.5 Sub-Issue Concurrency

`DurableFuturesUnordered` over N sub-issue dispatches runs them concurrently. Each
sub-dispatch is subject to:

- Per-tenant concurrency cap (`TenantSlots.acquire`).
- Per-state concurrency cap.
- The dependency gate (sub-issues that depend on each other are serialized naturally —
  the gate releases the dependent only after the dependency's `IssueAgent.dispatch`
  completes and the GitHub Issue is closed).

The orchestrator does NOT need to do its own dependency analysis at decompose time;
filed sub-issues with `tracked_in` linkage produce `blocked_by` entries that the
existing dependency gate handles.

### 16.6 Failure Handling

- A sub-issue dispatch failure (`TerminalError`) propagates out of the
  `DurableFuturesUnordered` loop (the `?` on `result?`) and fails the `Epic`. The
  integration step is skipped; status set to `Failed`.
- Operators MAY restart the failed sub-issue's `IssueAgent.dispatch` directly and then
  manually invoke the integration step via a dedicated shared handler (NOT defined in
  this spec).
- An integration test failure surfaces as a `TerminalError`; the Epic transitions to
  `Failed` and waits for operator intervention.
- Handoff timeout transitions to `Failed`.

### 16.7 Observability

- `restate state get Epic/<key>` shows `status`, `sub_issues`, intermediate results.
- `restate invocations describe <epic_invocation_id>` shows the full journal:
  decompose, fan-out, gather, integration, handoff await/resolve.
- The OPTIONAL `/api/v1/state` endpoint surfaces active Epics in the
  `epics_active` array (Section 12.3).

## 17. Reference Algorithms (Language-Agnostic)

This section gives runtime algorithms in pseudocode for components whose Rust skeletons
appear elsewhere. The pseudocode is for a reader cross-checking semantics; it is not
normative on syntax.

### 17.1 Service Startup

```text
function start_service():
  configure_logging()    # JSON via tracing-subscriber
  load_deployment_env()  # SYMPHONY_RESTATE_INGRESS_URL, SHARED_FS_ROOT, GITHUB_APP_*

  endpoint = build_restate_endpoint(
    services = [WebhookReceiver, CommentRouter, GitHubAdapter, AgentRuntime],
    objects  = [Tenant, IssueAgent, SymphonyCron, ReconcileCron, TenantSlots, WebhookDedup, HandoffWatcher],
    workflows = [Epic, ApprovalWorkflow]
  )

  http_server.listen(endpoint, bind=SYMPHONY_BIND_ADDR)
```

Note: there is no global startup terminal-cleanup pass. Cleanup happens per-tenant
inside `Tenant.init` and on `Tenant.update_config` when `terminal_states` changed.

### 17.2 SymphonyCron.tick

```text
function tick(ctx, tenant_id):
  next_delay = polling.interval_ms + jitter(restate.cron_jitter_ms)   // additive jitter, see §5.3.7
  handle = ctx.object_client(SymphonyCronClient, tenant_id).tick().send_after(next_delay)
  next_id = handle.invocation_id()
  ctx.set("next_invocation_id", next_id)

  cfg = ctx.object_client(TenantClient, tenant_id).config().call()
  validation = validate_dispatch_config(cfg)
  if not validation.ok:
    log_and_return(validation)

  candidates = ctx.run(|| fetch_candidate_issues(tenant_id)).name("fetch_candidates")
  sorted = sort_for_dispatch(candidates, cfg)

  for issue in sorted:
    if !candidate_eligible(issue, cfg):
      continue
    slot = ctx.object_client(TenantSlotsClient, tenant_id).acquire(issue.state).call()
    if not slot.acquired:
      break
    status = ctx.object_client(IssueAgentClient, key(tenant_id, issue.id)).status().call()
    if status.in_flight:
      ctx.object_client(TenantSlotsClient, tenant_id).release(issue.state).call()
      continue
    ctx.object_client(IssueAgentClient, key(tenant_id, issue.id)).dispatch(req(issue)).send()
```

### 17.3 IssueAgent.dispatch (high-level)

```text
function dispatch(ctx, req):
  cfg = ctx.object_client(TenantClient, req.tenant_id).config().call()
  workspace = ctx.run(|| create_or_reuse(cfg, req)).name("ensure_workspace")
  if workspace.created_now:
    ctx.run(|| run_hook(cfg.hooks.after_create, workspace)).name("hook:after_create")

  thread_id = ctx.get("codex_thread_id")
  for turn_n in 1..=cfg.agent.max_turns:
    if ctx.get("pause_reason") is set:
      # Dispatch creates and awaits its own awakeable; resume() resolves it. See Appendix B.7.
      (awakeable_id, promise) = ctx.awakeable()
      ctx.set("pause_awakeable_id", awakeable_id)
      promise.await    # suspends durably until resume() resolves
      ctx.clear("pause_awakeable_id")
      ctx.clear("pause_reason")

    ctx.run(|| run_hook(cfg.hooks.before_run, workspace)).name("hook:before_run:turn{turn_n}")
    outcome = run_one_turn(ctx, turn_n, workspace, thread_id, prompt_for(req, turn_n))
    thread_id = outcome.thread_id
    ctx.set("codex_thread_id", thread_id)
    ctx.set("turn_count", turn_n)
    ctx.run(|| run_hook(cfg.hooks.after_run, workspace)).name("hook:after_run:turn{turn_n}")

    refreshed = ctx.run(|| fetch_issue_states_by_ids([req.issue_id])).name("refresh_issue")
    if refreshed empty or terminal:
      break

  ctx.run(|| release_slot(req.tenant_id, req.issue.state)).name("release_slot")
  return DispatchOutcome
```

### 17.4 Per-Turn Loop (detailed)

See Section 10.3 Rust skeleton.

### 17.5 WebhookReceiver.github

```text
function github(ctx, req):
  raw = ctx.request().body
  sig = ctx.request().headers["x-hub-signature-256"]
  expected = "sha256=" + hmac_sha256(secret_for(req), raw)
  if not constant_time_eq(sig, expected):
    return TerminalError("webhook_signature_invalid")

  if cfg.webhook.allowlist_cidrs and source_ip not in cfg.webhook.allowlist_cidrs:
    return TerminalError("webhook_ip_disallowed")

  delivery_id = ctx.request().headers["x-github-delivery"]
  if dedup_seen(delivery_id):
    return Ok(())     # 200 OK

  event = ctx.request().headers["x-github-event"]
  if event == "ping":
    return Ok(/* 200 with pong */)
  if event not in cfg.webhook.events:
    return Ok(())     # 200 OK; not in whitelist

  payload = parse_json(raw)
  tenant_id = resolve_tenant_for(payload)        # by installation_id
  ctx.run(|| record_delivery(delivery_id, ttl=webhook.delivery_dedup_ttl_ms)).name("dedup_record")

  route_event_to_handlers(ctx, tenant_id, event, payload)
  return Ok(())
```

## 18. Test and Validation Matrix

Validation profiles:

- `Core Conformance` — REQUIRED for all conforming implementations.
- `Extension Conformance` — REQUIRED only for OPTIONAL features that an implementation
  ships.
- `Real Integration Profile` — environment-dependent, RECOMMENDED before production.

Unless noted, Sections 18.1 through 18.9 are `Core Conformance`. Bullets that begin
with `If ... is implemented` are `Extension Conformance`.

### 18.1 Workflow and Config Parsing

- Per-tenant workflow content can be loaded from file path, Git URL, or inline blob.
- `Tenant.update_config` re-parses without restart and applies on the next tick.
- Invalid `Tenant.update_config` does not mutate state.
- Missing workflow content returns `missing_workflow_file`.
- Invalid YAML returns `workflow_parse_error`.
- Front matter non-map returns `workflow_front_matter_not_a_map`.
- Config defaults apply when OPTIONAL values are missing.
- `tracker.kind == "github"` is enforced.
- `tracker.auth.mode` validation enforces one of `github_app` or `pat`.
- Env-var `*_ref` resolution works for credentials and shared FS root.
- Per-state concurrency override map normalizes state names and ignores invalid values.
- Prompt template renders `issue`, `attempt`, and `tenant`.
- Strict prompt rendering fails on unknown variables.

### 18.2 Workspace Manager and Safety

- Deterministic workspace path per `(tenant_id, issue_identifier)`.
- Missing workspace directory is created.
- Existing workspace is reused.
- `after_create` hook runs only on new workspace creation (verified via journal:
  `hook:after_create` step appears once per workspace lifetime).
- `before_run` runs before each turn, failure aborts attempt.
- `after_run` runs after each turn, failures logged.
- Workspace path containment under `<SHARED_FS_ROOT>/<tenant_id>/` is enforced
  pre-spawn.
- Codex launch uses workspace path as cwd; rejects paths outside the tenant root.
- Sanitized workspace key for canonical identifiers and edge cases (`draft:*`).

### 18.3 GitHub Adapter

- Candidate fetch resolves Project v2 by `project_id` or `owner+number+owner_type`.
- Pagination loops until `hasNextPage == false`; missing-cursor case fails as
  `github_missing_end_cursor`.
- Items filtered client-side by `active_states`, `include_kinds`, optional
  `tracker.repo`.
- Empty `fetch_issues_by_states([])` returns empty without API call.
- Empty `fetch_issue_states_by_ids([])` returns empty without API call.
- Status field probe correctly raises `tracker_status_field_missing` when the field is
  absent or non-single-select.
- Permission denied surfaces as `tracker_permission_denied` (HTTP 401 / 403 /
  GraphQL `FORBIDDEN`).
- Primary rate-limit signal triggers `ctx.sleep` until `resetAt`.
- Secondary rate-limit signal honors `Retry-After`.
- Dependency gate filters `Todo` items with non-CLOSED blockers; gated items appear in
  the snapshot bucket.
- Cycle members get a one-shot warning per tick and dispatch normally.
- `cross_repo_blockers == false` ignores out-of-repo blockers.
- Token minting via `mint_installation_token` is journaled; replay reuses the cached
  token until expiry.
- 401 from any GitHub call triggers `Tenant.rotate_app_token` then a single retry.

### 18.4 Restate Mechanics

- Every `IssueAgent.dispatch` invocation is uniquely keyed by
  `<tenant_id>:<issue_node_id>`.
- A second `dispatch` for the same key while the first is running is queued behind it
  (verified by inspecting `sys_invocation`).
- `ctx.run(...).name("tool:<call_id>")` is journaled; on simulated worker crash + replay,
  the same `call_id` step is skipped (closure not re-executed).
- Awakeable resolution survives orchestrator restart (pause/resume across restart).
- `pause` issued while no `dispatch` is running persists the `pause_reason` flag in
  state. A subsequent webhook-driven `dispatch` reads the flag at iteration 0, creates
  its own awakeable, and suspends. `resume` then resolves it.
- `resume` issued before `dispatch` reaches its pause check (race) only clears the
  flag; no awakeable was created, so there is nothing to resolve. The next dispatch
  iteration proceeds normally.
- Durable promises survive restart (workflow handoff signal).
- `DurableFuturesUnordered` over N sub-issue dispatches runs them concurrently, each
  appearing as a separate child invocation in `sys_invocation`.
- `RunRetryPolicy` honours `max_attempts`, `initial_delay`, `max_delay`.
- `TerminalError` does not retry; non-terminal errors retry per policy.
- Deployment pinning: an in-flight `Epic` continues running on the originally pinned
  deployment after a new deployment is registered (verified in test by introspecting
  the invocation's deployment ID).

### 18.5 Codex Agent Integration

- Codex launch: `bash -lc <codex.command>` with `cwd = workspace_path`,
  `kill_on_drop(true)`.
- Per-turn subprocess lifecycle: spawn → handshake → run → terminate, journaled as a
  single `turn:<n>:start_subprocess` + `turn:<n>:end_subprocess` pair.
- Thread persistence: a second turn invokes `thread/resume <thread_id>` and the JSONL
  file is preserved on shared FS.
- Each `dynamicToolCall` becomes a `tool:<call_id>` journal step.
- Replay test: simulate worker crash mid-turn; verify on replay that already-journaled
  tool calls are not re-executed (e.g. by checking that no second `git push` happens).
- Each approval becomes an `approval:<call_id>` journal step.
- Token usage telemetry is journaled per turn as `turn:<n>:tokens`.
- Codex `ContextWindowExceeded` maps to `TerminalError` (no retry).
- Codex `RateLimited` maps to non-terminal retry with backoff.
- Subprocess crash before handshake retries up to `tool_run_retry_max_attempts`.
- Stall timeout fires when no event arrives within `codex.stall_timeout_ms`.
- `codex.version_pin` mismatch logs a warning at first dispatch.
- `thread/resume` returning `protocol_state_invalid` clears `codex_thread_id` and starts
  a fresh thread on the next turn. Tool results journaled under the dead thread remain
  in the journal and are NOT re-executed; the new thread has no agent-side memory of
  them (§10.3.1).
- Cooperative stop: `stop` mid-turn causes the running dispatch to return
  `DispatchOutcome::Stopped` at the next safe checkpoint, the subprocess is
  gracefully terminated, and the per-state slot is released. A worker crash before the
  flag is read replays from the journal and still observes `stop_requested == true` on
  resume.

### 18.6 Multi-Tenancy

- Two tenants `acme-prod` and `widgetco-staging` operating concurrently in one
  cluster:
  - Their `IssueAgent` keys never collide.
  - `restate sql` audit query for one tenant returns only that tenant's invocations.
  - Workspace paths are mutually exclusive under `<SHARED_FS_ROOT>/`.
  - Per-tenant concurrency cap is enforced independently.
  - One tenant's `tracker_permission_denied` does not block the other tenant.
- `Tenant.init` for an existing key without `allow_reinit=true` returns
  `TerminalError`.
- Cross-tenant key access in test (e.g. an `IssueAgent` handler attempting to read
  `Tenant("other-tenant").config()`) is detected by code review; runtime guard via the
  request validator MAY enforce.

### 18.7 Webhooks (MANDATORY in this edition — Appendix A)

- HMAC-SHA256 verification rejects missing/mismatched signatures with
  `TerminalError("webhook_signature_invalid")` (mapped to HTTP 401 by ingress).
- Duplicate `X-GitHub-Delivery` UUIDs within `delivery_dedup_ttl_ms` return HTTP 200
  with no side effect.
- Events outside `webhook.events` return HTTP 200 (not 4xx) and are not processed.
- Receiver returns within 10 seconds even when downstream tracker calls are slow
  (achieved by `service_client::<C>().method(...).send()` fan-out).
- `ping` returns HTTP 200 with `{"pong": true}`.
- Webhook payload exceeding `webhook.max_payload_bytes` (default 25 MB) is rejected with
  HTTP 413 before parsing, and produces no journal entry.
- IP allowlisting (when configured) rejects out-of-CIDR requests with
  `webhook_ip_disallowed` (HTTP 403).
- Queue overflow returns HTTP 200 + `webhook_queue_full` log; polling loop is the
  recovery.
- Tenant routing by `installation_id` correctly dispatches to the right tenant's
  components.

### 18.8 Comment Control Plane (Appendix B, OPTIONAL)

- Comments authored by `comment_commands.bot_login` are silently ignored.
- `allowed_authors` bypasses the permission check.
- Authors below `allowed_permissions` are rejected and logged.
- Permission resolved via REST `/repos/.../collaborators/.../permission`, NOT via
  `author_association`.
- Edited comments whose canonical command is unchanged are no-ops.
- `comment_commands.enabled` while `webhook.enabled == false` raises
  `comment_commands_requires_webhook` at preflight.
- Commands inside Markdown blockquote, fenced code blocks, or indented code blocks are
  not honored.
- `pause`/`resume` survive worker restart (durable awakeable).
- `bot_login` self-loop suppression handles `[bot]` suffix correctly.
- `retry` against an issue currently held by the dependency gate releases the claim
  and logs `comment_command_skipped` with the gate reason.

### 18.9 Long-Horizon Workflows (Epic)

- `Epic.run` decomposes via Codex, fans out sub-issue dispatches via
  `DurableFuturesUnordered`, runs integration test, awaits handoff.
- `Epic.submit_handoff` resolves the durable promise; `Epic.run` resumes.
- `Epic` survives orchestrator restart mid-await: handoff resolution after restart is
  recognized.
- Handoff timeout transitions Epic to `Failed`.
- Sub-issue dispatch failure propagates out of the `DurableFuturesUnordered` loop and
  fails the Epic.
- Long sleep (e.g. 7 days) in test is verified via `ctx.advance_time` (or equivalent
  test harness) without wall-clock waiting.

### 18.10 Real Integration Profile (RECOMMENDED)

These checks RECOMMENDED for production readiness; MAY be skipped in CI when network
access or external service permissions are unavailable.

- A real GitHub smoke test with a valid GitHub App installation:
  - `Tenant.init` succeeds against a live Project v2.
  - `SymphonyCron.tick` enumerates at least one item of each configured
    `include_kinds` value present in the project.
  - `mint_installation_token` returns a valid token; a token rotation cycle works.
- A real Codex smoke test with a real `codex` binary:
  - One full `IssueAgent.dispatch` cycle completes end-to-end against a sample
    issue.
  - Per-tool-call journaling produces the expected `tool:<call_id>` entries in
    `sys_journal`.
- A real webhook end-to-end test:
  - GitHub-side webhook configured against a public Restate ingress URL (e.g. via
    ngrok in dev).
  - A real GitHub event triggers the expected `IssueAgent.dispatch`.
- Skipped real-integration tests SHOULD be reported as skipped, not silently passed.
- Real-integration tests SHOULD use isolated test identifiers and clean up tracker
  artifacts.
- A simulated `Retry-After` HTTP 429 is honored.

## 19. Implementation Checklist (Definition of Done)

Same profile structure as Section 18:

- §19.1 = `Core Conformance`
- §19.2 = `Extension Conformance`
- §19.3 = `Real Integration Profile`

### 19.1 REQUIRED for Conformance

- Symphony Rust binary registers `Tenant`, `IssueAgent`, `SymphonyCron`, `ReconcileCron`,
  `TenantSlots`, `WebhookDedup`, `HandoffWatcher`, `Epic`, `ApprovalWorkflow`,
  `WebhookReceiver`, `CommentRouter`, `GitHubAdapter`, `AgentRuntime` with Restate Server
  v1.4+.
- `Tenant.init` and `Tenant.update_config` parse and validate `WORKFLOW.md`, persist
  config without raw credentials, and refuse mutation on validation errors.
- Per-tenant `SymphonyCron` self-rescheduling tick with crash-safe ordering
  (reschedule first, work second).
- Per-tenant `ReconcileCron` running stall detection, tracker state refresh, and
  dependency-gate refresh (when enabled).
- `IssueAgent.dispatch` runs Codex per-turn subprocess lifecycle with thread
  persistence via on-disk JSONL on the shared filesystem.
- Per-tool-call journaling: every `dynamicToolCall` is `ctx.run(...).name("tool:<call_id>")`.
- Per-approval journaling: every approval request is `ctx.run(...).name("approval:<call_id>")`.
- Pause/resume durable across restart: `pause` only sets the `pause_reason` flag in VO
  state; the running `dispatch` invocation creates and awaits its own awakeable on the
  next loop iteration; `resume` clears the flag and resolves the persisted awakeable id
  if dispatch already created one. The `pause` handler never owns an awakeable on its
  own.
- Cooperative stop (§10.9): `stop` sets `stop_requested` in VO state. The running
  dispatch loop polls the flag at safe checkpoints (between turns and around each
  `dynamicToolCall`), gracefully terminates the subprocess, and returns
  `DispatchOutcome::Stopped`. The flag survives worker crash because VO state is
  durable.
- Fresh-thread fallback (§10.3.1): `thread/resume` returning `protocol_state_invalid`
  (or equivalent Codex error) clears `codex_thread_id` and starts a new thread.
  Implementations MUST NOT silently retry `thread/resume`; they MUST detect the
  inconsistent-state response and reset.
- Webhook receiver returns HTTP 200 on async-queue overflow (NOT 5xx); logs
  `webhook_queue_full`; relies on the polling loop for recovery (§A.4 step 8).
- HandoffWatcher VO is registered (§16.4) for handoff timeouts that exceed half the
  deployment cadence; `Epic.run` does NOT use single multi-day `ctx.sleep` calls in
  that scenario.
- `GitHubAdapter` implements all REQUIRED operations from Section 11.1, with
  primary/secondary rate-limit handling and the `fetch_issue_states_by_ids` reconciliation
  query.
- Status field probe at `Tenant.init` and on relevant reloads.
- Per-tenant workspace path containment enforced before Codex spawn.
- Sanitized workspace keys.
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`,
  `before_remove`) with `hooks.timeout_ms`.
- Strict prompt rendering with `issue`, `attempt`, `tenant`.
- Restate per-step `RunRetryPolicy` with `max_attempts` and exponential backoff capped
  by `agent.max_retry_backoff_ms`.
- `WebhookReceiver` (MANDATORY in this edition) verifying HMAC-SHA256, deduping by
  `X-GitHub-Delivery`, returning within 10 seconds, handling `ping`.
- Tenant routing by `installation_id` for App-auth tenants.
- Dependency gating per Appendix D applied inside `SymphonyCron.tick`.
- PR Review and CI Awareness predicates (Appendix C) applied when configured.
- Structured JSON logs with `tenant_id`, `restate_invocation_id`, `step_name` fields.
- Token redaction in logs.

### 19.2 RECOMMENDED Extensions

- `github_graphql` client-side tool exposed to Codex via `dynamicToolCall`.
- `Epic` workflow (Section 16) for long-horizon multi-day orchestrations.
- `ApprovalWorkflow` for multi-step durable approvals.
- Comment Control Plane (Appendix B): `@<bot_login> retry|pause|resume|stop|status`
  via REST `/repos/.../collaborators/.../permission` authorization, durable
  pause/resume.
- OPTIONAL `/api/v1/state` JSON snapshot endpoint per Section 12.3.
- IP allowlisting from `/meta` for the webhook receiver.
- `restate.awakeable_pause_ttl_ms` enforcement.
- Per-tenant token-budget alerts via `TenantTotals` VO.
- Hard-isolation deployment topology (per-tenant Restate clusters).

### 19.3 Operational Validation Before Production

- Run the Real Integration Profile from Section 18.10.
- Verify per-tenant audit isolation via `restate sql`.
- Verify shared filesystem visibility across all Symphony workers (workspace and
  thread JSONL writes from worker A are visible to worker B).
- Verify HA failover: kill one Restate node and one Symphony worker simultaneously;
  in-flight `IssueAgent.dispatch` invocations recover and complete on the surviving
  nodes.
- Verify deployment-pinned hotfix flow: pause an in-flight invocation, deploy a fix,
  resume against the new deployment.
- Verify webhook end-to-end with a real GitHub App installation.
- Verify Codex `version_pin` is enforced and a mismatched version emits a warning.

## Appendix A. Webhook-Driven Dispatch (MANDATORY)

This appendix is **mandatory** in this edition (it is `Core Conformance`, not
`Extension Conformance`). Polling alone is too coarse for multi-tenant deployments;
webhooks reduce dispatch latency from `polling.interval_ms` to milliseconds and
materially reduce GraphQL spend.

The polling loop (`SymphonyCron.tick`) is NOT removed by this requirement. It remains the
safety net for missed events, processing failures, and out-of-order delivery.

### A.1 Configuration

Top-level workflow front-matter key `webhook` (object):

- `webhook.enabled` (boolean) — default `true` in this edition. Setting to `false` is
  permitted for development only; production deployments MUST have it enabled.
- `webhook.bind` (string) — default `0.0.0.0`. The receiver runs as a Restate Service
  handler, so binding is delegated to Restate's ingress.
- `webhook.port` (integer) — default `8080` (Restate ingress port). When Symphony is
  deployed behind a load balancer, the LB's public URL points at this port.
- `webhook.path` (string) — default `/WebhookReceiver/github`. This is Restate's
  service-call URL; GitHub webhooks POST here.
- `webhook.secret_ref` (env var name, REQUIRED).
- `webhook.events` (list, OPTIONAL) — see §A.5.
- `webhook.allowlist_cidrs` (list of CIDR strings, OPTIONAL).
- `webhook.delivery_dedup_ttl_ms` (integer) — default `86400000` (24 hours).
- `webhook.max_payload_bytes` (integer) — default `26214400` (25 MB). Requests larger
  than this MUST be rejected with HTTP 413 before parsing (§A.7).

### A.2 TLS

Symphony does NOT terminate TLS itself. When exposing the receiver to the public
internet, operators MUST terminate TLS at a load balancer or reverse proxy in front of
Restate ingress. The webhook secret protects integrity (HMAC), not confidentiality.

### A.3 Provisioning

This specification does NOT require Symphony to create the GitHub-side webhook
automatically. Operators provision the webhook in one of three ways:

- **GitHub App webhook** (RECOMMENDED for multi-tenant): register a single webhook URL
  in the App's settings; events from every installation arrive at that URL. The
  payload's `installation.id` field is used by `WebhookReceiver` to route to the right
  tenant.
- **Org webhook**: `POST /orgs/{org}/hooks`. Required scope: `admin:org_hook`.
  RECOMMENDED only for single-tenant deployments because installation-id routing is
  ambiguous when multiple tenants share one org.
- **Repo webhook**: `POST /repos/{owner}/{repo}/hooks`. Required scope:
  `admin:repo_hook`. NOTE: `projects_v2_item` is NOT delivered at the repo level;
  this option is sufficient for Issue/PR-only workflows but cannot fully replace the
  polling loop for project Status changes.

Provisioning body example (org webhook):

```json
{
  "name": "web",
  "active": true,
  "events": ["projects_v2_item", "issues", "pull_request",
             "pull_request_review", "pull_request_review_thread",
             "pull_request_review_comment", "issue_comment",
             "check_suite", "check_run"],
  "config": {
    "url": "https://symphony.example.com/WebhookReceiver/github",
    "content_type": "json",
    "secret": "<value matching webhook.secret>",
    "insecure_ssl": "0"
  }
}
```

### A.4 Receiver Contract

Implementation skeleton:

```rust
#[restate_sdk::service]
pub trait WebhookReceiver {
    async fn github(req: WebhookReq) -> Result<(), HandlerError>;
}

impl WebhookReceiver for WebhookReceiverImpl {
    async fn github(
        &self,
        ctx: Context<'_>,
        _req: WebhookReq,
    ) -> Result<(), HandlerError> {
        let raw = ctx.request();
        let headers = &raw.headers;
        let body: &[u8] = raw.body.as_ref();

        // 1. IP allowlist (when configured)
        if !ip_allowed(headers, &self.deps.cfg.allowlist_cidrs) {
            return Err(TerminalError::new("webhook_ip_disallowed").into());
        }

        // 2. Read X-GitHub-Event
        let event = headers
            .get("x-github-event")
            .ok_or_else(|| TerminalError::new("webhook_event_missing"))?;
        if event == "ping" {
            return Ok(());  // Restate ingress maps Ok -> 200
        }

        // 3. Resolve tenant by installation_id
        let payload: GithubWebhookPayload = serde_json::from_slice(body)
            .map_err(|e| TerminalError::new(format!("webhook_payload_unparseable: {e}")))?;
        let tenant_id = self
            .deps
            .resolve_tenant_for_installation(payload.installation_id())
            .ok_or_else(|| TerminalError::new("webhook_tenant_not_found"))?;

        // 4. Load tenant secret
        let cfg = ctx
            .object_client::<TenantClient>(tenant_id.clone())
            .config()
            .call()
            .await?;
        let secret = self.deps.load_secret(&cfg.webhook_secret_ref)?;

        // 5. HMAC-SHA256 verification
        let sig = headers
            .get("x-hub-signature-256")
            .ok_or_else(|| TerminalError::new("webhook_signature_missing"))?;
        let expected = hmac_sha256_hex(&secret, body);
        if !constant_time_eq(sig.as_bytes(),
                             format!("sha256={expected}").as_bytes()) {
            return Err(TerminalError::new("webhook_signature_invalid").into());
        }

        // 6. Event whitelist
        if !cfg.webhook.events.contains(event) {
            return Ok(());  // 200 OK, ignored
        }

        // 7. Dedup
        let delivery_id = headers
            .get("x-github-delivery")
            .ok_or_else(|| TerminalError::new("webhook_delivery_id_missing"))?;
        // Dedup state lives in the per-tenant `WebhookDedup` Virtual Object so that the
        // sliding-window set survives restarts and is observable as VO state.
        let already_seen = ctx
            .object_client::<WebhookDedupClient>(tenant_id.clone())
            .check_and_record(DedupCheckReq {
                delivery_id: delivery_id.to_string(),
                ttl_ms: cfg.webhook.delivery_dedup_ttl_ms,
            })
            .call()
            .await?;
        if already_seen {
            return Ok(());
        }

        // 8. Route. Queue overflow MUST return HTTP 200 (Restate ingress maps Ok -> 200);
        // we deliberately do NOT propagate the overflow error with `?`. The polling loop
        // is the recovery path. A 5xx here would mark the delivery failed in GitHub's UI
        // without auto-retry.
        match route_event(ctx, &tenant_id, event, &payload).await {
            Ok(()) => {}
            Err(RouteError::QueueFull(_)) => {
                tracing::warn!(?delivery_id, ?tenant_id, "webhook_queue_full");
                // intentionally NOT returning Err; HTTP 200 is correct here.
            }
            Err(e) => return Err(e.into()),
        }
        Ok(())
    }
}
```

Receiver MUST return HTTP 200 on downstream queue overflow; the polling loop is the
recovery path. Returning 5xx would mark the delivery failed in GitHub's UI without
auto-retry. Receiver MUST also reject requests over the configured maximum payload size
with HTTP 413 **before** parsing the body — see §A.7.

### A.5 Default Event Whitelist and Dispatch Effect

| Event | Action(s) | Effect |
|---|---|---|
| `projects_v2_item` | `created`, `edited`, `archived`, `restored`, `deleted`, `reordered`, `converted` | Refresh affected item; on `archived`/`deleted`, send `IssueAgent.stop` and trigger `SymphonyCron.tick` via `object_client::<SymphonyCronClient>(tenant_id).tick().send()`. **Org/App webhooks only.** |
| `issues` | `opened`, `closed`, `reopened`, `labeled`, `unlabeled`, `edited`, `transferred` | `SymphonyCron.tick` send to refresh wrapping project items. |
| `pull_request` | `opened`, `closed`, `reopened`, `synchronize`, `ready_for_review`, `converted_to_draft`, `edited`, `labeled`, `unlabeled`, `review_requested`, `review_request_removed` | Same. `synchronize` triggers CI/check-state re-evaluation. |
| `pull_request_review` | `submitted`, `edited`, `dismissed` | `SymphonyCron.tick` send. PR with `pr_dispatch_signals.changes_requested` may dispatch immediately. |
| `pull_request_review_thread` | `resolved`, `unresolved` | `SymphonyCron.tick` send. Requires GitHub.com or GHES 3.10+. |
| `pull_request_review_comment` | `created`, `edited` | `CommentRouter.route` send. |
| `issue_comment` | `created`, `edited` | `CommentRouter.route` send. PR-conversation comments arrive here, NOT under `pull_request_review_comment`. |
| `check_suite` | `completed` | `SymphonyCron.tick` send. |
| `check_run` | `completed`, `rerequested` | `SymphonyCron.tick` send. |

`deleted` actions on `issue_comment` and `pull_request_review_comment` are intentionally
ignored.

### A.6 Bridge to the Orchestrator

A successful event triggers a
`ctx.object_client::<SymphonyCronClient>(tenant_id).tick().send()` or, when the event
identifies a specific issue, a direct
`ctx.object_client::<IssueAgentClient>(key).dispatch(req).send()`. The async send returns
immediately, satisfying GitHub's 10-second budget.

For events that carry `changes.field_value.from`/`to` (specifically
`projects_v2_item.edited` on a single-select field — the canonical "Status changed"
signal), implementations MAY fold the new state into the next reconcile pass without
a full GraphQL refresh. This is an OPTIONAL optimization.

### A.7 Out-of-Order Delivery and Reliability

- GitHub does NOT guarantee event ordering. Reconciliation handles this naturally
  because each event triggers a fresh `fetch_issue_states_by_ids` (or full sweep) — the
  latest state always wins.
- GitHub does NOT auto-retry failed deliveries. The polling loop (Section 8.1) is the
  authoritative recovery path.
- The dedup window (default 24 hours) prevents tight-loop double-processing of operator
  redeliveries from the GitHub UI.
- Maximum payload size is approximately 25 MB. Implementations MUST reject requests
  over the configured limit with HTTP 413 **before** parsing the body. The error
  category `webhook_payload_too_large` (§A.8) is logged for these rejections.

### A.8 Validation and Errors

Preflight (per tenant, in `Tenant.init`/`update_config`):

- `webhook_secret_missing` — `webhook.secret_ref` env var unset or empty.
- `webhook_tenant_not_found_at_setup` — installation ID not yet registered with any
  tenant.

Receiver-side error categories (logged per request; mapped to non-200 by Restate
ingress when surfaced as `TerminalError`):

- `webhook_signature_missing`
- `webhook_signature_invalid`
- `webhook_ip_disallowed`
- `webhook_event_missing`
- `webhook_payload_unparseable`
- `webhook_payload_too_large`
- `webhook_event_ignored` (DEBUG; expected)
- `webhook_queue_full` (the receiver's downstream send was rejected by Restate; HTTP
  200 still returned and polling loop is the recovery)

## Appendix B. Comment Control Plane

This appendix is `Extension Conformance` — OPTIONAL but RECOMMENDED. It depends on
Appendix A (the webhook receiver). Polling-only deployments cannot implement
low-latency comment commands.

The big win in this edition vs the language-agnostic edition: **`pause` and `resume`
are durable across orchestrator restart** because they are implemented via Restate
awakeables stored in `IssueAgent` VO state. The original specification's "in-memory
pause set, lost on restart" caveat is REMOVED.

### B.1 Configuration

Top-level workflow front-matter key `comment_commands` (object):

- `comment_commands.enabled` (boolean) — default `false`.
- `comment_commands.bot_login` (string) — REQUIRED when enabled.
- `comment_commands.allowed_permissions` (list) — default
  `["ADMIN", "MAINTAIN", "WRITE"]`.
- `comment_commands.allowed_authors` (list) — default empty.
- `comment_commands.commands` (list) — default all canonical commands.
- `comment_commands.reaction_acknowledge` (string or null) — default null.

For GitHub Apps, the login appearing in `comment.user.login` includes the literal
`[bot]` suffix (for example `symphony[bot]`). The configured `bot_login` MUST match
that exact form for self-loop suppression to work. Implementations MAY accept the bare
login as a convenience alias for the mention prefix when documented.

### B.2 Trigger Events

Subscribed via Appendix A:

- `issue_comment.created`, `issue_comment.edited`
- `pull_request_review_comment.created`, `pull_request_review_comment.edited`

PR-level conversation comments fire `issue_comment`, NOT `pull_request_review_comment`.
Both subscriptions are required for full PR coverage.

`deleted` actions are intentionally ignored.

### B.3 Canonical Commands

Mention prefix: `@<comment_commands.bot_login>`. Commands are case-insensitive,
single-line, parsed only when the prefix appears at the start of a comment body line
(ignoring leading whitespace). Multiple commands in one comment are NOT supported;
first match wins.

Lines that MUST be ignored (privilege-escalation suppression):

- Lines beginning with `>` (Markdown blockquote).
- Lines inside fenced code blocks (` ``` ` or `~~~`). Open-but-unclosed fences MUST
  also suppress every following line.
- Lines inside four-space-indented code blocks.

| Command | Effect |
|---|---|
| `@bot retry` | Send a fresh `IssueAgent.dispatch` for the parent issue/PR. If gated by dependencies, releases the claim and logs `comment_command_skipped` with the gate reason. |
| `@bot pause` | `IssueAgent.pause` — stores an awakeable in VO state; the next dispatch loop iteration suspends. **Durable across restart.** |
| `@bot resume` | `IssueAgent.resume` — resolves the awakeable. No-op if not paused. |
| `@bot stop` | `IssueAgent.stop` — cancels in-flight dispatch (if any), sets `stopped_at` marker. |
| `@bot status` | `IssueAgent.status` (shared handler) — reply with summary comment. Always allowed. |

### B.4 Author Authorization

`CommentRouter.route` flow:

1. Resolve `comment.user.login`.
2. If `comment.user.login == comment_commands.bot_login`, ignore silently
   (`comment_command_self_loop_skipped` log).
3. If `allowed_authors` non-empty AND login is in the list, allow.
4. Otherwise, query effective repository permission via REST:

   ```http
   GET /repos/{owner}/{repo}/collaborators/{login}/permission
   Authorization: Bearer <installation_token_or_pat>
   Accept: application/vnd.github+json
   ```

   The response includes `permission` (one of `read`, `triage`, `write`, `maintain`,
   `admin`, `none`) and `role_name`. This endpoint returns the **effective** permission
   merging direct collaborator grants and team-membership grants.

   The resolved `permission` (compared case-insensitively to `allowed_permissions`)
   MUST be in the allowlist. `none` MUST be rejected.

5. If authorization fails:
   - Do NOT execute the command.
   - SHOULD post a one-line reply (`unauthorized: requires WRITE or higher`).
   - Log `comment_command_unauthorized` with author login, command, resolved
     permission.

`author_association` MUST NOT be used as a permission proxy.

### B.5 Idempotency and Comment Edits

- Compare `changes.body.from` with current body. If the canonical command on the
  matching line is unchanged, the edit is a no-op.
- Process command iff the canonical command on the matching line is newly introduced
  or changed.
- Honor the dedup window from Appendix A.

### B.6 Validation and Errors

Preflight additions when `comment_commands.enabled == true`:

- `comment_commands_bot_login_missing` — `bot_login` unset.
- `comment_commands_requires_webhook` — `webhook.enabled` is `false`.
- `comment_commands_token_insufficient` — startup probe of the collaborator-permission
  REST endpoint returned 401/403. The token is missing repo-level `Metadata: Read` (the
  primary requirement) or, for fine-grained PATs scoped narrowly, lacks visibility into
  the configured project's repos. Dispatch is NOT blocked, but commands will be
  rejected (and logged as `comment_command_unauthorized`) with an operator warning
  until the token is corrected. See §11.6 for the full scope breakdown.

Receiver-side log categories:

- `comment_command_unauthorized`
- `comment_command_unknown`
- `comment_command_self_loop_skipped`
- `comment_command_executed`
- `comment_command_skipped`

### B.7 Durable Pause/Resume

The correct design has the running `dispatch` invocation own the awakeable. `pause`
sets a flag in VO state; `dispatch` reads that flag at the top of each turn, creates
its OWN awakeable in its OWN context, persists the awakeable id, and then awaits the
promise. `resume` reads the persisted id and resolves the awakeable.

This survives orchestrator restart because Restate's journal records "dispatch is
awaiting awakeable X." On replay, dispatch is restored at that suspension point. When
`resume` resolves the awakeable (identified by the stable id persisted in VO state),
dispatch wakes — no matter how many worker restarts have occurred in between.

```rust
async fn dispatch(
    &self,
    ctx: ObjectContext<'_>,
    Json(req): Json<DispatchReq>,
) -> Result<Json<DispatchOutcome>, HandlerError> {
    // ... ensure_workspace, after_create hook, etc.

    let mut turn_n = 0;
    loop {
        // Check pause-flag at top of each loop iteration.
        if let Some(reason) = ctx.get::<String>("pause_reason").await? {
            // Dispatch creates the awakeable in its OWN context and awaits it.
            let (awakeable_id, promise) = ctx.awakeable::<()>();
            ctx.set("pause_awakeable_id", &awakeable_id);
            // Suspends durably; survives worker crash and orchestrator restart.
            promise.await?;
            ctx.clear("pause_awakeable_id");
            ctx.clear("pause_reason");
            // Optional: clear pause_requested_by / pause_requested_at telemetry fields.
        }

        // ... run turn_n, handle terminal exit, etc.
        if terminal { return Ok(Json(outcome)); }
        turn_n += 1;
    }
}

async fn pause(
    &self,
    ctx: ObjectContext<'_>,
    Json(req): Json<PauseReq>,
) -> Result<(), HandlerError> {
    // pause does NOT create an awakeable. It only sets the flag.
    // The running dispatch will create and await the awakeable on its next loop turn.
    ctx.set("pause_reason", req.reason);
    ctx.set("pause_requested_by", req.requested_by);
    ctx.set("pause_requested_at", chrono::Utc::now().to_rfc3339());
    Ok(())
}

async fn resume(
    &self,
    ctx: ObjectContext<'_>,
) -> Result<(), HandlerError> {
    // Always clear the reason so a not-yet-suspended dispatch loop will not pause on
    // its next iteration.
    ctx.clear("pause_reason");
    if let Some(id) = ctx.get::<String>("pause_awakeable_id").await? {
        // Resolve the awakeable owned by the suspended dispatch invocation.
        ctx.resolve_awakeable::<()>(&id, ());
        // dispatch will clear pause_awakeable_id when it wakes.
    }
    Ok(())
}
```

Why this works across orchestrator restart: Restate persists the awakeable's id and
the in-flight `dispatch` invocation's journal position. After a worker crash, Restate
re-runs `dispatch` from its journal until it reaches the suspended `promise.await?`,
where it suspends again. When `resume` resolves the awakeable by id, the suspended
dispatch is woken regardless of which worker hosts it. The id in VO state is the
durable handle, not an in-process pointer.

Edge cases:

- `pause` followed by `resume` before `dispatch` reaches the loop top: only the flag
  flickers; no awakeable is ever created, no suspension occurs, and the loop runs
  normally on its next iteration.
- `pause` while no `dispatch` invocation is running: the flag persists. The next
  webhook- or cron-driven dispatch will read the flag at its first iteration and
  suspend until `resume` is called.
- `resume` with no `pause_awakeable_id` in state: no-op (the dispatch loop has not yet
  reached the suspension point, or there is no in-flight dispatch).

### B.8 Security Notes

- `comment.author_association` MUST NOT be trusted as a permission proxy.
- Comment bodies are arbitrary user input; treat with the same caution as tracker
  data per Section 14.5.

### B.9 Conformance Notes

`Extension Conformance`. Implementations that ship the comment control plane MUST
cover: bot self-loop suppression, `allowed_authors` bypass, permission-denied flow,
command-not-in-`commands`-list rejection, edit no-op, webhook prerequisite validation,
durable pause/resume across restart, and code-fence/blockquote suppression.

## Appendix C. PR Review and CI Awareness Extension

This appendix is `Extension Conformance` — OPTIONAL.

When configured, two predicates apply to items whose `kind == "pull_request"`. The
extension is purely additive: when not configured, behavior matches Section 11.2.1
exactly.

### C.1 Configuration

Under `tracker`:

- `tracker.pr_dispatch_signals` (list, OPTIONAL) — entries that make a PR dispatch-
  eligible **even if** its project Status is not in `active_states`. Supported:
  - `changes_requested` — at least one `pr.latest_opinionated_reviews` entry has
    `state == CHANGES_REQUESTED`, **and** `pr.unresolved_review_threads > 0`.

    GitHub's `latestOpinionatedReviews(writersOnly: true)` already returns the most
    recent opinionated review per author (the states it surfaces are `APPROVED` and
    `CHANGES_REQUESTED`; `COMMENTED`, `DISMISSED`, and `PENDING` are excluded).
    Implementations iterate the returned list directly without de-duplicating per
    author. Worked example:

    - Alice posts `CHANGES_REQUESTED`, then `COMMENTED`, then `APPROVED`. The
      predicate does NOT match: Alice's latest opinionated review is `APPROVED`, so
      no `CHANGES_REQUESTED` entry appears for her in the returned list.
    - Alice posts `CHANGES_REQUESTED`, then `COMMENTED`. The predicate matches
      (subject to `unresolved_review_threads > 0`): Alice's latest opinionated review
      is `CHANGES_REQUESTED`; the trailing `COMMENTED` is not opinionated and does
      not displace it.
  - `ci_failure` — `pr.check_state ∈ {ERROR, FAILURE}`.
  - `review_requested` — at least one login in `tracker.pr_self_reviewer_logins`
    appears in `pr.requested_reviewers`.
- `tracker.pr_self_reviewer_logins` (list, OPTIONAL) — logins identifying the
  Symphony deployment to itself.
- `tracker.pr_block_signals` (list, OPTIONAL) — entries that **disqualify** a PR.
  Supported:
  - `awaiting_human_review` — `pr.review_decision == REVIEW_REQUIRED` AND no entry
    in `pr_self_reviewer_logins` is among `pr.requested_reviewers`.
  - `mergeable_unknown` — `pr.mergeable == UNKNOWN`.
  - `merge_state_blocked` — `pr.merge_state_status == BLOCKED` **and**
    `pr.review_decision == REVIEW_REQUIRED`.

`pr_dispatch_signals` is evaluated **before** `pr_block_signals`; if a PR matches
both, the block wins.

### C.2 Effective State for PRs Under the Extension

```
eligible_pr =
    (status in active_states OR any signal in pr_dispatch_signals matches)
  AND NOT (any signal in pr_block_signals matches)
  AND NOT terminal-OR rule (Section 11.2.1)
  AND dependency gate passes (Appendix D)
```

The terminal-OR rule still wins. The dependency gate is an outer eligibility check
applied to all kinds.

### C.3 Continuation-Run Semantics

When a PR is dispatched because of `changes_requested` or `ci_failure`, the prompt
template SHOULD render with `attempt` non-null. Standard template variables expose
`issue.pr.review_decision`, `issue.pr.check_state`, and
`issue.pr.latest_opinionated_reviews`; workflows branch on these.

The orchestrator does NOT auto-resolve review threads, dismiss reviews, or push
commits. Codex does that via the `github_graphql` tool.

### C.4 Validation

Preflight rejects unknown signal entries with `unsupported_pr_signal` (`TerminalError`).

## Appendix D. Sub-Issue Dependency Gating

This appendix specifies the candidate-eligibility filter applied inside
`SymphonyCron.tick`. It is `Core Conformance` (the gate is required) but the extended
config knobs (`gate_running_on_dependencies`, `cross_repo_blockers`) are optional.

### D.1 Inputs

- `issue.state` — the project Status field value.
- `issue.blocked_by` — list of blocker refs.
- `tracker.dependency_gating_states` — default `["Todo"]`.
- `tracker.cross_repo_blockers` — default `true`.

### D.2 Algorithm

1. If lowercased `issue.state` is not in lowercased `dependency_gating_states`, the
   gate passes unconditionally.
2. Otherwise, build the **effective blocker set**: copy of `issue.blocked_by`,
   filtered to drop entries whose `repository.name_with_owner` differs from the
   issue's repository when `cross_repo_blockers == false`.
3. A blocker is **resolved** iff its `state == CLOSED`. "Resolved" is the GitHub
   Issue close state; it is independent of the project Status field.
4. The gate passes iff every blocker in the effective set is resolved.
5. Items that fail the gate are **not** dispatched, **not** retried, and **not**
   treated as terminal. They appear in the `gated` snapshot bucket (Section 12.3).

### D.3 Cycle Handling

If two or more issues form a dependency cycle, every member would be permanently
gated. Implementations SHOULD detect cycles per tick using a topological sort over the
candidate set. When a cycle is detected, every member is treated as having an empty
effective blocker set **for that tick only**, dispatch proceeds normally, and the
orchestrator emits one operator-visible warning per cycle (deduplicated by the sorted
member-id tuple).

### D.4 Depth Handling

The gate considers first-level `blocked_by` entries only. Sub-issues' own blockers are
evaluated when those sub-issues become candidates themselves.

### D.5 Decomposition Workflow Mode

This specification does not require a separate "decomposition mode" config. A
workflow prompt that instructs Codex to file sub-issues will, on the next tick, find
the parent with non-empty `blocked_by` — the parent gates naturally and the new
sub-issues become candidates. No special orchestrator support needed.

The `Epic` workflow (Section 16) is the structured first-class equivalent.

### D.6 Reconciliation Refresh (`gate_running_on_dependencies = true`)

When this flag is true, `ReconcileCron.tick` Part C re-evaluates the gate for running
parents. If the gate now fails (a blocker reopened), terminate the worker without
workspace cleanup, release the claim, log `dependencies_reopened`. No retry is
scheduled — the next tick or webhook re-evaluates eligibility from scratch.

## Appendix E. Deployment Topologies

### E.1 Single-Node Development

- 1 Restate Server (RocksDB backend, single node, no HA).
- 1 Symphony worker.
- Local filesystem for workspaces.
- 1 tenant (or a few cooperating tenants).
- Webhooks via ngrok or equivalent to expose Restate ingress.

Suitable for local development, demos, and small internal deployments (<10 active
issues at any time).

### E.2 HA Production

- 3 Restate Server nodes (Raft cluster, RocksDB or Postgres backend).
- N Symphony Rust workers behind an L7 load balancer (e.g. nginx, GCP Load Balancing,
  AWS ALB).
- Shared filesystem accessible to every Symphony worker (NFS / EFS / FSx).
- 1 GitHub App registered for the deployment, with webhook URL pointing at the LB.
- Per-tenant `installation_id` in `Tenant` VO state; one installation per tenant org.

Capacity sizing: roughly 50-100 concurrent `IssueAgent.dispatch` invocations per
Symphony worker (depends on Codex turn duration and tool-call cardinality). Restate
overhead is negligible at this scale.

### E.3 Restate Cloud Topology

- Per-tenant Restate Cloud cluster (hard isolation; this is Restate Cloud's model).
- One Symphony deployment per tenant in your VPC, registered with the tenant's
  Restate Cloud cluster.
- Workspace storage per tenant in S3-backed FUSE or per-deployment EFS.
- GitHub App per tenant (or shared App with per-tenant installation).

Suitable for SaaS deployments where tenant isolation is a contractual requirement.

### E.4 Self-Hosted Per-Tenant Clusters

- 1 Restate Server (single or HA) per tenant.
- 1 Symphony worker (or HA pair) per tenant.
- Per-tenant FS storage.

Operationally heavier than the shared-cluster model but offers hard isolation
without the SaaS cost.

## Appendix F. Migration Path from the Elixir SPEC.md (Informative)

This appendix is informative and brief. It sketches how an organization currently
running the Elixir reference implementation of `SPEC.md` would migrate to the Rust +
Restate edition.

### F.1 Phase 0 — Stabilize Existing Elixir Deployment

Continue running the Elixir Symphony as-is. Confirm `WORKFLOW.md` content is
versioned and the team can describe their tenant's GitHub Project v2, status field,
active/terminal states, concurrency caps, and approval policy.

### F.2 Phase 1 — Stand Up Rust + Restate Skeleton

- Deploy Restate Server (single-node dev to start).
- Deploy a Symphony Rust worker registering all handlers.
- Provision a single test tenant: `Tenant.init` with a copy of the production
  `WORKFLOW.md`.
- Run `SymphonyCron.tick` against a non-production GitHub Project (a fork or a
  staging Project) to validate the GraphQL contract and per-tool-call journaling.

### F.3 Phase 2 — Webhooks and Comment Control Plane

- Configure the GitHub App / org webhook URL pointing at Restate ingress.
- Enable `webhook.enabled = true` on the test tenant.
- Enable `comment_commands` and validate durable pause/resume across worker restart.
- Compare audit trails between Elixir and Rust implementations on a few sample
  issues.

### F.4 Phase 3 — Long-Horizon Workflow

- Implement and exercise the `Epic` workflow on a real multi-day decomposition.
- Validate handoff awakeable resolution.
- Validate cross-deploy hotfix flow (pause → deploy fix → resume).

### F.5 Phase 4 — Per-Tenant Cutover

- For each production tenant: stop the Elixir worker for that tenant, run
  `Tenant.init` against the Rust deployment with the same `WORKFLOW.md`,
  validate one full dispatch cycle, then point the GitHub App webhook at the new URL.
- Workspaces from the Elixir deployment SHOULD be migrated by file copy if Codex
  thread state continuity is desired; otherwise they will be re-created on first
  dispatch.

### F.6 Compatibility Notes

- The Issue domain model (Section 4.1.1) is identical between editions.
- The GraphQL queries (Section 11.2) are identical.
- The dependency gate algorithm (Appendix D) is identical.
- The Codex app-server protocol contract is identical.
- The `WORKFLOW.md` front matter is mostly compatible; new keys (`tracker.auth`,
  `restate.*`, `workspace.root_ref`) are required by the Rust edition. Old keys
  (`tracker.api_token` literal) are accepted via the `pat` auth mode shim.

### F.7 What's Different (Highlights)

- The in-memory orchestrator state machine (Elixir SPEC §7) is gone. Restate Virtual
  Object identity replaces it.
- The retry queue (Elixir SPEC §8.4) is gone. Restate's `RunRetryPolicy` per step
  replaces it.
- Pause/resume is now durable across restart (Appendix B).
- Webhooks are mandatory (Appendix A).
- Long-horizon workflows are first-class (`Epic`, Section 16).
- Multi-tenancy is first-class (Section 15).
- Operator observability shifts from a custom dashboard to Restate Admin UI +
  `restate sql`. Symphony's `/api/v1/state` becomes optional convenience.


