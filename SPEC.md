# Symphony Service Specification

Status: Draft v1 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this
specification does not prescribe one universal policy. Implementations MUST document the selected
behavior.

## 1. Problem Statement

Symphony is a long-running automation service that continuously reads work from an issue tracker
(GitHub Projects v2 in this specification version), creates an isolated workspace for each issue,
and runs a coding agent session for that issue inside the workspace.

The tracker model in this specification version treats GitHub Issues, Pull Requests, and GitHub
Projects v2 items that point to either as the primary unit of work. Symphony polls a single
configured GitHub Project v2, normalizes its items into a stable Issue model (Section 4), and
schedules coding-agent runs for items whose project Status is in the configured active states.

The service solves four operational problems:

- It turns issue execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It keeps the workflow policy in-repo (`WORKFLOW.md`) so teams version the agent prompt and runtime
  settings with their code.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy; some
implementations target trusted environments with a high-trust configuration, while others require
stricter approvals or sandboxing.

Important boundary:

- Symphony is a scheduler/runner and tracker reader.
- Issue and Pull Request writes (Status field updates, comments, labels, PR linkage) are
  typically performed by the coding agent using tools available in the workflow/runtime
  environment.
- A successful run can end at a workflow-defined handoff state (for example `Human Review`), not
  necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from a repository-owned `WORKFLOW.md` contract.
- Expose operator-visible observability (at minimum structured logs).
- Support tracker/filesystem-driven restart recovery without requiring a persistent database; exact
  in-memory scheduler state is not restored.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- Built-in business logic for how to edit Issues, Pull Requests, project items, or comments.
  (That logic lives in the workflow prompt and agent tooling.)
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads `WORKFLOW.md`.
   - Parses YAML front matter and prompt body.
   - Returns `{config, prompt_template}`.

2. `Config Layer`
   - Exposes typed getters for workflow config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Issue Tracker Client`
   - Fetches candidate issues in active states.
   - Fetches current states for specific issue IDs (reconciliation).
   - Fetches terminal-state issues during startup cleanup.
   - Normalizes tracker payloads into a stable issue model.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Tracks session metrics and retry queue state.

5. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

6. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + workflow template.
   - Launches the coding agent app-server client.
   - Streams agent updates back to the orchestrator.

7. `Status Surface` (OPTIONAL)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

8. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Symphony is easiest to port when kept in these layers:

1. `Policy Layer` (repo-defined)
   - `WORKFLOW.md` prompt body.
   - Team-specific rules for issue and PR handling, validation, and handoff.

2. `Configuration Layer` (typed getters)
   - Parses front matter into typed runtime settings.
   - Handles defaults, environment tokens, and path normalization.

3. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation.

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

5. `Integration Layer` (GitHub adapter)
   - GraphQL calls against the GitHub API and normalization of Project v2 items, Issues, and Pull
     Requests into the domain model.

6. `Observability Layer` (logs + OPTIONAL status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API (GitHub GraphQL API for `tracker.kind: github` in this specification version).
- Local filesystem for workspaces and logs.
- OPTIONAL workspace population tooling (for example Git CLI, if used).
- Coding-agent executable that supports the targeted Codex app-server mode.
- Host environment authentication for the issue tracker (GitHub token) and coding agent.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

An `Issue` in this specification represents one unit of dispatchable tracker work. With
`tracker.kind == "github"` it MAY be backed by:

- a GitHub Project v2 item whose underlying content is a GitHub Issue,
- a GitHub Project v2 item whose underlying content is a Pull Request,
- a GitHub Project v2 item whose underlying content is a Draft Issue (project-only, not yet a real
  GitHub Issue).

The same domain model is used for all three. Fields specific to one underlying kind are populated
only when applicable and are otherwise null.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
  - For GitHub: the Project v2 item node ID (`PVTI_*`). This MUST be the value used as the map key
    for orchestrator state, reconciliation, and retry bookkeeping.
- `identifier` (string)
  - Human-readable identifier used in logs, prompts, and workspace naming.
  - For GitHub Issues and Pull Requests: `<owner>/<repo>#<number>` (example:
    `openai/symphony#42`).
  - For GitHub Draft Issues: `draft:<short>` where `<short>` is the last 8 characters of the
    Project item node ID (example: `draft:AF6gQ123`).
- `kind` (string)
  - One of `issue`, `pull_request`, `draft_issue`.
  - Normalized from the GraphQL `ProjectV2ItemType` enum (`ISSUE`, `PULL_REQUEST`, `DRAFT_ISSUE`).
- `title` (string)
- `description` (string or null)
  - GitHub Issue/PR/DraftIssue `body` field, treated as Markdown.
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
  - For GitHub: derived from a configured project priority field or labels (Section 11.3).
- `state` (string)
  - Effective project state used by orchestration.
  - For GitHub: the value of the configured Status single-select field on the project item
    (`fieldValueByName(name: "Status").name`). If the Status field is unset, the implementation
    SHOULD use the sentinel string `<no status>` (lowercased before comparison).
- `repository` (object or null)
  - Populated for `issue` and `pull_request` kinds; null for `draft_issue`.
  - Fields:
    - `owner` (string)
    - `name` (string)
    - `name_with_owner` (string, equal to `<owner>/<name>`)
- `number` (integer or null)
  - GitHub Issue or PR number; null for `draft_issue`.
- `branch_name` (string or null)
  - For `pull_request`: PR head branch (`headRefName`).
  - For `issue` and `draft_issue`: null by default. Implementations MAY populate a
    deterministic suggested branch name for issues as an extension; if they do, this MUST be
    documented and the same value MUST appear consistently in `branch_name` across normalization
    paths (Section 11.3) so prompts and logs see one source of truth.
- `url` (string or null)
  - GitHub Issue/PR HTML URL; null for `draft_issue`.
- `labels` (list of strings)
  - Normalized to lowercase.
  - Empty list for `draft_issue` (Draft Issues do not carry labels).
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null) — node ID of the blocking issue.
    - `identifier` (string or null) — human-readable identifier
      (`<owner>/<repo>#<number>`).
    - `state` (string or null) — `OPEN` or `CLOSED` from the GitHub Issue state.
  - For GitHub: derived from Issue `trackedIssues` (the items this issue tracks/depends on).
    Section 11.3 covers normalization rules and an OPTIONAL label-based fallback.
- `pr` (object or null)
  - Populated only for `pull_request` kind; null otherwise.
  - Fields:
    - `state` (string) — `OPEN`, `CLOSED`, or `MERGED`.
    - `merged` (boolean)
    - `merged_at` (timestamp or null)
    - `closed_at` (timestamp or null)
    - `is_draft` (boolean)
    - `base_ref_name` (string)
    - `review_decision` (string or null) — `APPROVED`, `CHANGES_REQUESTED`,
      `REVIEW_REQUIRED`, or `null`. `null` means review requirements do not apply (no branch
      protection, or the protection rule does not require reviews); it MUST NOT be coerced to
      `REVIEW_REQUIRED`.
    - `mergeable` (string or null) — `MERGEABLE`, `CONFLICTING`, `UNKNOWN`.
    - `merge_state_status` (string or null) — one of `BEHIND`, `BLOCKED`, `CLEAN`, `DIRTY`,
      `DRAFT`, `HAS_HOOKS`, `UNKNOWN`, `UNSTABLE`. Diagnostic; `BLOCKED` typically indicates
      failing required checks or missing required reviews.
    - `check_state` (string or null) — `EXPECTED`, `ERROR`, `FAILURE`, `PENDING`, `SUCCESS`.
      Derived from the head commit's `statusCheckRollup.state`.
    - `unresolved_review_threads` (integer) — count of `reviewThreads` with
      `isResolved == false && isOutdated == false`. Used by workflows that gate on review
      resolution.
    - `latest_opinionated_reviews` (list of objects, ordered by `submitted_at` descending) —
      derived from `latestOpinionatedReviews(first: 50, writersOnly: true)`. Each entry:
      `state` (`APPROVED` or `CHANGES_REQUESTED`), `author_login`, `submitted_at`.
    - `requested_reviewers` (list of strings) — `User.login` and `Team.slug` values from
      `reviewRequests`. `Mannequin` reviewers, when present, contribute the mannequin login.
- `issue_state` (string or null)
  - For `issue` kind: `OPEN` or `CLOSED`.
  - For `pull_request` kind: same as `pr.state`.
  - For `draft_issue` kind: null.
  - Used by terminal-OR semantics (Section 11.2.1).
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
  - YAML front matter root object.
- `prompt_template` (string)
  - Markdown body after front matter, trimmed.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config` plus environment resolution.

Examples:

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.4 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (absolute workspace path)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `codex_app_server_pid` (string or null)
- `last_codex_event` (string/enum or null)
- `last_codex_timestamp` (timestamp or null)
- `last_codex_message` (summarized payload)
- `codex_input_tokens` (integer)
- `codex_output_tokens` (integer)
- `codex_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.7 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)

#### 4.1.8 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (current effective poll interval)
- `max_concurrent_agents` (current effective global concurrency limit)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `completed` (map `issue_id -> %{completed_at: timestamp}`; bookkeeping only, not
  dispatch gating). Implementations MAY keep this as a plain set if they do not
  surface `last_run_completed_at` to prompts (Section 12.3); the map shape is
  REQUIRED only when the OPTIONAL `last_run_completed_at` template variable is
  exposed. When the OPTIONAL Agent Workpad Protocol (Section 11.8) is enabled,
  the per-issue value MUST extend further to an ordered list of per-session
  records (Section 11.8.5); implementations adopting §11.8 MUST plan for this
  schema migration rather than treating it as a value-shape tweak.
- `codex_totals` (aggregate tokens + runtime seconds)
- `codex_rate_limits` (latest rate-limit snapshot from agent events)

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the workspace directory name.
  - Worked examples for `tracker.kind == "github"`:
    - `openai/symphony#42` → `openai_symphony_42`
    - `myorg/my-repo#1234` → `myorg_my-repo_1234`
    - `draft:AF6gQ123` → `draft_AF6gQ123`
  - Implementations MUST NOT use the canonical identifier directly as a path segment. The `/`
    and `#` characters are not permitted in workspace directory names (and `/` is a path
    separator, which would break workspace-root containment checks in Section 9.5).
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - Compose from coding-agent `thread_id` and `turn_id` as `<thread_id>-<turn_id>`.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Workflow file path precedence:

1. Explicit application/runtime setting (set by CLI startup path).
2. Default: `WORKFLOW.md` in the current process working directory.

Loader behavior:

- If the file cannot be read, return `missing_workflow_file` error.
- The workflow file is expected to be repository-owned and version-controlled.

### 5.2 File Format

`WORKFLOW.md` is a Markdown file with OPTIONAL YAML front matter.

Design note:

- `WORKFLOW.md` SHOULD be self-contained enough to describe and run different workflows (prompt,
  runtime settings, hooks, and tracker selection/config) without requiring out-of-band
  service-specific configuration.

Parsing rules:

- If file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter MUST decode to a map/object; non-map YAML is an error.
- Prompt body is trimmed before use.

Returned workflow object:

- `config`: front matter root object (not nested under a `config` key).
- `prompt_template`: trimmed Markdown body.

### 5.3 Front Matter Schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`

Unknown keys SHOULD be ignored for forward compatibility.

Note:

- The workflow front matter is extensible. Extensions MAY define additional top-level keys without
  changing the core schema above.
- Extensions SHOULD document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.

#### 5.3.1 `tracker` (object)

Fields:

- `kind` (string)
  - REQUIRED for dispatch.
  - Current supported value: `github`.
- `endpoint` (string)
  - Default for `tracker.kind == "github"`: `https://api.github.com/graphql`.
  - For GitHub Enterprise Server, set this to `https://<host>/api/graphql`.
  - For GitHub Enterprise Cloud with data residency, set this to
    `https://api.<tenant>.ghe.com/graphql`.
- `api_token` (string)
  - REQUIRED for dispatch.
  - MAY be a literal token or `$VAR_NAME`.
  - Canonical environment variable for `tracker.kind == "github"`: `GITHUB_TOKEN`.
  - If `$VAR_NAME` resolves to an empty string, treat the token as missing.
  - Sent on every GraphQL request as `Authorization: Bearer <token>`.
- `owner` (string)
  - REQUIRED for dispatch when `tracker.kind == "github"`.
  - GitHub login of the user or organization that owns the target Project v2.
- `owner_type` (string)
  - One of `organization` or `user`.
  - Default: `organization`.
  - Selects between `organization(login: $owner) { projectV2(number: $n) }` and
    `user(login: $owner) { projectV2(number: $n) }` when resolving the project from
    `tracker.project_number`. Ignored when `tracker.project_id` is used directly.
- `project_number` (positive integer)
  - REQUIRED unless `tracker.project_id` is provided.
  - The integer shown in the project URL (`/orgs/<owner>/projects/<number>`).
- `project_id` (string)
  - OPTIONAL alternative to `tracker.project_number`.
  - Stable Project v2 global node ID (typically prefixed `PVT_`).
  - When both `project_id` and `project_number` are provided, `project_id` wins and
    `owner_type` is ignored for project resolution.
- `repo` (string)
  - OPTIONAL.
  - When set, restricts the items returned by `fetch_candidate_issues()` and
    `fetch_issues_by_states()` to project items whose underlying Issue or Pull Request belongs
    to the repository `<tracker.owner>/<tracker.repo>`. Draft Issues have no repository and
    therefore **pass through** this filter unchanged when their kind is allowed by
    `include_kinds`. To exclude Draft Issues entirely, omit `draft_issue` from
    `include_kinds`.
  - The bare `<repo>` form requires the underlying Issue/PR to belong to `<tracker.owner>`;
    items in the project that belong to a different owner are silently filtered out.
  - Implementations MAY also accept `<owner>/<repo>` form for cross-owner repositories. When
    given, `<owner>` MUST match exactly (case-insensitive) for an item to pass the filter.
- `status_field` (string)
  - Name of the Project v2 single-select field that drives orchestration state.
  - Default: `Status`.
  - Comparison against `active_states`/`terminal_states` is case-insensitive after lowercasing
    both sides (Section 4.2).
- `priority_field` (string, OPTIONAL)
  - Name of the Project v2 single-select or number field used to derive `issue.priority`.
  - Default: `Priority`. If absent on an item, `issue.priority` is null.
- `priority_mapping` (map of string to integer, OPTIONAL)
  - Maps single-select option names (compared case-insensitively) to the `issue.priority`
    integer.
  - Default mapping when omitted:
    - `urgent` → `1`
    - `high` → `2`
    - `medium` → `3`
    - `low` → `4`
    - `p0` → `0`, `p1` → `1`, `p2` → `2`, `p3` → `3`, `p4` → `4`
  - Number-field values are passed through as-is when the configured `priority_field` is a
    number field.
- `include_kinds` (list of strings)
  - Subset of `["issue", "pull_request", "draft_issue"]`.
  - Default: `["issue", "pull_request"]`.
  - Project items whose `kind` is not in this list are filtered out before reaching the
    orchestrator. This is enforced after server fetch because Projects v2 does not support
    server-side filtering (Section 11.2).
- `active_states` (list of strings)
  - Default: `["Todo", "In Progress"]`.
  - Compared against `issue.state` (the project Status field value) after lowercasing both
    sides.
- `terminal_states` (list of strings)
  - Default: `["Done"]`.
  - Compared the same way as `active_states`.
  - GitHub-specific terminal-OR rule applies — see Section 11.2.1 for the canonical
    statement.
- `dependency_gating_states` (list of strings, OPTIONAL)
  - Default: `["Todo"]`.
  - Items in any state in this list are treated as not-yet-eligible-for-dispatch when they
    have one or more open `blocked_by` entries. Compared after lowercasing both sides.
  - Set to `[]` to disable dependency gating entirely.
  - Set to (for example) `["Todo", "In Progress"]` to also gate items already in progress
    when sub-issues are open. The orchestrator state machine is unchanged regardless of
    this setting; gating is purely a candidate-eligibility filter (Section 8.2.1).
- `gate_running_on_dependencies` (boolean, OPTIONAL)
  - Default: `false`.
  - When `true`, an actively running parent issue whose blockers transition from all-closed
    to any-open during reconciliation (Section 8.5 Part B) has its worker terminated and the
    issue requeued. When `false` (the default), a running parent finishes its current
    worker session naturally; the gating filter only applies on the next dispatch attempt.
- `cross_repo_blockers` (boolean, OPTIONAL)
  - Default: `true`.
  - When `false`, blocker entries whose `repository.nameWithOwner` differs from the
    parent's repository are ignored for gating purposes. Useful for deployments that should
    only honor in-repo dependencies.

Implementations MUST resolve a unique Project v2 from this configuration before polling. Either
`project_id` is provided directly, or `project_number` plus `owner` (and `owner_type`) is
resolved on first use and the resulting node ID SHOULD be cached for the lifetime of the
process to avoid repeated lookup queries.

#### 5.3.2 `polling` (object)

Fields:

- `interval_ms` (integer)
  - Default: `30000`
  - Changes SHOULD be re-applied at runtime and affect future tick scheduling without restart.

#### 5.3.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/symphony_workspaces`
  - `~` is expanded.
  - Relative paths are resolved relative to the directory containing `WORKFLOW.md`.
  - The effective workspace root is normalized to an absolute path before use.

#### 5.3.4 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, OPTIONAL)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, OPTIONAL)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
- `after_run` (multiline shell script string, OPTIONAL)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, OPTIONAL)
  - Runs before workspace deletion if the directory exists.
  - Failure is logged but ignored; cleanup still proceeds.
- `timeout_ms` (integer, OPTIONAL)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Invalid values fail configuration validation.
  - Changes SHOULD be re-applied at runtime for future hook executions.

#### 5.3.5 `agent` (object)

Fields:

- `max_concurrent_agents` (integer)
  - Default: `10`
  - Changes SHOULD be re-applied at runtime and affect subsequent dispatch decisions.
- `max_turns` (positive integer)
  - Default: `20`
  - Limits the number of coding-agent turns within one worker session.
  - Invalid values fail configuration validation.
- `max_retry_backoff_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD be re-applied at runtime and affect future retry scheduling.
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (non-positive or non-numeric) are ignored.

#### 5.3.6 `codex` (object)

Fields:

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Implementors SHOULD treat them as pass-through Codex config values rather than relying on a
hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

- `command` (string shell command)
  - Default: `codex app-server`
  - The runtime launches this command via `bash -lc` in the workspace directory.
  - The launched process MUST speak a compatible app-server protocol over stdio.
- `approval_policy` (Codex `AskForApproval` value)
  - Default: implementation-defined.
- `thread_sandbox` (Codex `SandboxMode` value)
  - Default: implementation-defined.
- `turn_sandbox_policy` (Codex `SandboxPolicy` value)
  - Default: implementation-defined.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
- `read_timeout_ms` (integer)
  - Default: `5000`
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - If `<= 0`, stall detection is disabled.

### 5.4 Prompt Template Contract

The Markdown body of `WORKFLOW.md` is the per-issue prompt template.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering.
- Unknown filters MUST fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime MAY use a minimal default prompt
  (`You are working on a GitHub issue.`).
- Workflow file read/parse failures are configuration/validation errors and SHOULD NOT silently fall
  back to a prompt.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

Configuration is resolved in this order:

1. Select the workflow file path (explicit runtime setting, otherwise cwd default).
2. Parse YAML front matter into a raw config map.
3. Apply built-in defaults for missing OPTIONAL fields.
4. Resolve `$VAR_NAME` indirection only for config values that explicitly contain `$VAR_NAME`.
5. Coerce and validate typed values.

Environment variables do not globally override YAML values. They are used only when a config value
explicitly references them.

Value coercion semantics:

- Path/command fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Apply expansion only to values intended to be local filesystem paths; do not rewrite URIs or
    arbitrary shell command strings.
- Relative `workspace.root` values resolve relative to the directory containing the selected
  `WORKFLOW.md`.

### 6.2 Dynamic Reload Semantics

Dynamic reload is REQUIRED:

- The software MUST detect `WORKFLOW.md` changes.
- On change, it MUST re-read and re-apply workflow config and prompt template without restart.
- The software MUST attempt to adjust live behavior to the new config (for example polling
  cadence, concurrency limits, active/terminal states, codex settings, workspace paths/hooks, and
  prompt content for future runs).
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Implementations are not REQUIRED to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) MAY
  require restart unless the implementation explicitly supports live rebind.
- Implementations SHOULD also re-validate/reload defensively during runtime operations (for example
  before dispatch) in case filesystem watch events are missed.
- Invalid reloads MUST NOT crash the service; keep operating with the last known good effective
  configuration and emit an operator-visible error.

### 6.3 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the workflow/config needed to poll and launch workers, not a full audit of all possible workflow
behavior.

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- Workflow file can be loaded and parsed.
- `tracker.kind` is present and supported.
- `tracker.api_token` is present after `$` resolution.
- For `tracker.kind == "github"`:
  - At least one of `tracker.project_id` or `tracker.project_number` is present.
  - When `tracker.project_number` is used, `tracker.owner` is present.
  - `tracker.owner_type`, when set, is one of `organization` or `user`.
  - `tracker.include_kinds`, when set, contains only `issue`, `pull_request`, or
    `draft_issue`.
  - The implementation MUST probe the project for the configured `tracker.status_field`
    (Section 11.2.4) at startup, and SHOULD re-probe on the first dispatch tick after a
    workflow reload that changes the project identifier or `status_field`. A missing field
    raises `tracker_status_field_missing` and blocks dispatch until the workflow is fixed,
    rather than silently producing zero candidates forever.
- `codex.command` is present and non-empty.

### 6.4 Core Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.
Extension fields are documented in the extension section that defines them. Core conformance does
not require recognizing or validating extension fields unless that extension is implemented.

- `tracker.kind`: string, REQUIRED, currently `github`
- `tracker.endpoint`: string, default `https://api.github.com/graphql` when `tracker.kind=github`
- `tracker.api_token`: string or `$VAR`, canonical env `GITHUB_TOKEN` when `tracker.kind=github`
- `tracker.owner`: string, REQUIRED when `tracker.kind=github` and `tracker.project_id` is not set
- `tracker.owner_type`: string, one of `organization` or `user`, default `organization`
- `tracker.project_number`: positive integer, REQUIRED when `tracker.project_id` is not set
- `tracker.project_id`: string, OPTIONAL alternative to `tracker.project_number`
- `tracker.repo`: string, OPTIONAL single-repo filter for project items
- `tracker.status_field`: string, default `Status`
- `tracker.priority_field`: string, default `Priority`
- `tracker.priority_mapping`: map of string to integer, OPTIONAL
- `tracker.include_kinds`: list of strings, default `["issue", "pull_request"]`
- `tracker.active_states`: list of strings, default `["Todo", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Done"]`
- `tracker.dependency_gating_states`: list of strings, default `["Todo"]`
- `tracker.gate_running_on_dependencies`: boolean, default `false` (extension)
- `tracker.cross_repo_blockers`: boolean, default `true` (extension)
- `tracker.pr_dispatch_signals`: list of strings, default `[]` (extension; see §11.7)
- `tracker.pr_self_reviewer_logins`: list of strings, default `[]` (extension; see §11.7)
- `tracker.pr_block_signals`: list of strings, default `[]` (extension; see §11.7)

Extension fields (cheat sheet, see Appendix B / Appendix C for full descriptions):

- `webhook.enabled`: boolean, default `false`
- `webhook.bind`: string, default `127.0.0.1`
- `webhook.port`: integer, default `8787`
- `webhook.path`: string, default `/webhooks/github`
- `webhook.secret`: string or `$VAR`, REQUIRED when enabled
- `webhook.events`: list of strings, default per §B.5
- `webhook.allowlist_cidrs`: list of CIDR strings, default empty
- `webhook.delivery_dedup_ttl_ms`: integer, default `86400000`
- `comment_commands.enabled`: boolean, default `false`
- `comment_commands.bot_login`: string, REQUIRED when enabled
- `comment_commands.allowed_permissions`: list of strings, default `["ADMIN","MAINTAIN","WRITE"]`
- `comment_commands.allowed_authors`: list of strings, default empty
- `comment_commands.commands`: list of strings, default all canonical commands
- `comment_commands.reaction_acknowledge`: string or null, default null
- `polling.interval_ms`: integer, default `30000`
- `workspace.root`: path resolved to absolute, default `<system-temp>/symphony_workspaces`
- `hooks.after_create`: shell script or null
- `hooks.before_run`: shell script or null
- `hooks.after_run`: shell script or null
- `hooks.before_remove`: shell script or null
- `hooks.timeout_ms`: integer, default `60000`
- `agent.max_concurrent_agents`: integer, default `10`
- `agent.max_turns`: integer, default `20`
- `agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`
- `codex.command`: shell command string, default `codex app-server`
- `codex.approval_policy`: Codex `AskForApproval` value, default implementation-defined
- `codex.thread_sandbox`: Codex `SandboxMode` value, default implementation-defined
- `codex.turn_sandbox_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `codex.turn_timeout_ms`: integer, default `3600000`
- `codex.read_timeout_ms`: integer, default `5000`
- `codex.stall_timeout_ms`: integer, default `300000`

## 7. Orchestration State Machine

The orchestrator is the only component that mutates scheduling state. All worker outcomes are
reported back to it and converted into explicit state transitions.

### 7.1 Issue Orchestration States

This is not the same as tracker states (`Todo`, `In Progress`, etc.). This is the service's internal
claim state.

1. `Unclaimed`
   - Issue is not running and has no retry scheduled.

2. `Claimed`
   - Orchestrator has reserved the issue to prevent duplicate dispatch.
   - In practice, claimed issues are either `Running` or `RetryQueued`.

3. `Running`
   - Worker task exists and the issue is tracked in `running` map.

4. `RetryQueued`
   - Worker is not running, but a retry timer exists in `retry_attempts`.

5. `Released`
   - Claim removed because issue is terminal, non-active, missing, or retry path completed without
     re-dispatch.

Important nuance:

- A successful worker exit does not mean the issue is done forever.
- The worker MAY continue through multiple back-to-back coding-agent turns before it exits.
- After each normal turn completion, the worker re-checks the tracker issue state.
- If the issue is still in an active state, the worker SHOULD start another turn on the same live
  coding-agent thread in the same workspace, up to `agent.max_turns`.
- The first turn SHOULD use the full rendered task prompt.
- Continuation turns SHOULD send only continuation guidance to the existing thread, not resend the
  original task prompt that is already present in thread history.
- Once the worker exits normally, the orchestrator still schedules a short continuation retry
  (about 1 second) so it can re-check whether the issue remains active and needs another worker
  session.

### 7.2 Run Attempt Lifecycle

A run attempt transitions through these phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

Distinct terminal reasons are important because retry logic and logs differ.

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs.
  - Validate config.
  - Fetch candidate issues.
  - Dispatch until slots are exhausted.

- `Worker Exit (normal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule continuation retry (attempt `1`) after the worker exhausts or finishes its in-process
    turn loop.

- `Worker Exit (abnormal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule exponential-backoff retry.

- `Codex Update Event`
  - Update live session fields, token counters, and rate limits.

- `Retry Timer Fired`
  - Re-fetch active candidates and attempt re-dispatch, or release claim if no longer eligible.

- `Reconciliation State Refresh`
  - Stop runs whose issue states are terminal or no longer active.

- `Stall Timeout`
  - Kill worker and schedule retry.

### 7.4 Idempotency and Recovery Rules

- The orchestrator serializes state mutations through one authority to avoid duplicate dispatch.
- `claimed` and `running` checks are REQUIRED before launching any worker.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven (without a durable orchestrator DB).
- Startup terminal cleanup removes stale workspaces for issues already in terminal states.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick, and
then repeats every `polling.interval_ms`.

The effective poll interval SHOULD be updated when workflow config changes are re-applied.

Tick sequence:

1. Reconcile running issues.
2. Run dispatch preflight validation.
3. Fetch candidate issues from tracker using active states.
4. Sort issues by dispatch priority.
5. Dispatch eligible issues while slots remain.
6. Notify observability/status consumers of state changes.

If per-tick validation fails, dispatch is skipped for that tick, but reconciliation still happens
first.

### 8.2 Candidate Selection Rules

An issue is dispatch-eligible only if all are true:

- It has `id`, `identifier`, `title`, and `state`.
- Its state is in `active_states` and not in `terminal_states`.
- It is not already in `running`.
- It is not already in `claimed`.
- Global concurrency slots are available.
- Per-state concurrency slots are available.
- Dependency gate passes (Section 8.2.1).

Sorting order (stable intent):

1. `priority` ascending (lower numbers including `0` sort first; `null`/unknown sorts last)
2. `created_at` oldest first
3. `identifier` lexicographic tie-breaker

#### 8.2.1 Dependency Gate

The dependency gate is the unified blocker rule. It replaces the original `Todo`-only blocker
heuristic with a configurable, cross-state filter.

Inputs:

- `issue.state` — the project Status field value.
- `issue.blocked_by` — list of blocker refs (Section 4.1.1).
- `tracker.dependency_gating_states` (Section 5.3.1).
- `tracker.cross_repo_blockers` (Section 5.3.1).

Algorithm:

1. If the lowercased `issue.state` is not in lowercased `tracker.dependency_gating_states`,
   the gate passes unconditionally.
2. Otherwise, build the **effective blocker set**: copy of `issue.blocked_by`, filtered to
   drop entries whose `repository.nameWithOwner` differs from the issue's repository when
   `tracker.cross_repo_blockers == false`.
3. A blocker is **resolved** iff its `state == CLOSED`. "Resolved" is exclusively the GitHub
   Issue close state; it is independent of the project Status field and of
   `terminal_states`.
4. The gate passes iff every blocker in the effective set is resolved.
5. Items that fail the gate are **not** dispatched, **not** retried, and **not** treated as
   terminal. They appear in the `gated` snapshot bucket (Section 13.7.2) so operators can see
   why they are sitting still.

Cycle handling:

- If two or more issues form a dependency cycle (A blocks B, B blocks A), every member of the
  cycle would be permanently gated. Implementations SHOULD detect cycles per tick using a
  topological sort over the candidate set. When a cycle is detected, every member is treated
  as having an empty effective blocker set **for that tick only**, dispatch proceeds normally,
  and the orchestrator emits one operator-visible warning per detected cycle (deduplicated by
  the sorted member-id tuple) so the cycle is reported but does not freeze the system.
- Blockers that are **not** in the current candidate set (because they live in a different
  project, are excluded by `include_kinds`, or were already terminal at fetch time) are
  evaluated by their `state` field alone: a blocker with `state == CLOSED` resolves the gate
  for that edge, and any other state keeps it unresolved. Cycles that span into or out of
  the candidate set therefore cannot deadlock — at least one out-of-set blocker must be
  CLOSED to break the cycle, and that closure is observable directly from the
  `Issue.trackedIssues` payload.

Depth handling:

- The gate considers first-level `blocked_by` entries only. Sub-issues' own blockers are
  evaluated when those sub-issues become candidates themselves.

Decomposition workflow mode:

- This specification does not require a separate "decomposition mode" config. A workflow
  prompt that instructs the agent to file sub-issues will, on the next tick, find the parent
  with non-empty `blocked_by` — the parent gates naturally and the new sub-issues become
  candidates. No special orchestrator support is needed.

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present (state key normalized)
- otherwise fallback to global limit

The runtime counts issues by their current tracked state in the `running` map.

### 8.4 Retry and Backoff

Retry entry creation:

- Cancel any existing retry timer for the same issue.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.

Backoff formula:

- Normal continuation retries after a clean worker exit use a short fixed delay of `1000` ms.
- Failure-driven retries use `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`.
- Power is capped by the configured max retry backoff (default `300000` / 5m).

Retry handling behavior:

1. Fetch active candidate issues (not all issues).
2. Find the specific issue by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible:
   - Dispatch if slots are available.
   - Otherwise requeue with error `no available orchestrator slots`.
5. If found but no longer active, release claim.

Note:

- Terminal-state workspace cleanup is handled by startup cleanup and active-run reconciliation
  (including terminal transitions for currently running issues).
- Retry handling mainly operates on active candidates and releases claims when the issue is absent,
  rather than performing terminal cleanup itself.

### 8.5 Active Run Reconciliation

Reconciliation runs every tick and has two parts.

Part A: Stall detection

- For each running issue, compute `elapsed_ms` since:
  - `last_codex_timestamp` if any event has been seen, else
  - `started_at`
- If `elapsed_ms > codex.stall_timeout_ms`, terminate the worker and queue a retry.
- If `stall_timeout_ms <= 0`, skip stall detection entirely.

Part B: Tracker state refresh

- Fetch current issue states for all running issue IDs.
- For each running issue:
  - If tracker state is terminal: terminate worker and clean workspace.
  - If tracker state is still active: update the in-memory issue snapshot.
  - If tracker state is neither active nor terminal: terminate worker without workspace cleanup.
- If state refresh fails, keep workers running and try again on the next tick.

Part C: Dependency-gate refresh (OPTIONAL)

- This part runs only when `tracker.gate_running_on_dependencies == true`.
- For each running issue whose `state` is in `tracker.dependency_gating_states`:
  - Re-evaluate the dependency gate (Section 8.2.1) using the freshly refreshed
    `blocked_by` list.
  - If the gate now fails (a previously-resolved blocker reopened, or a new blocker was
    added), terminate the worker without workspace cleanup, release the claim, and emit a
    log entry with reason `dependencies_reopened`.
- This part runs after Part B so it operates on already-refreshed `blocked_by` data.
- Termination via this path does **not** schedule a retry (Section 16.6); the issue
  returns to `Unclaimed` and is re-evaluated by the next poll tick or webhook trigger.
  Scheduling a retry would be self-defeating: the very next dispatch attempt would fail
  the dependency gate and release the claim again.
- When `gate_running_on_dependencies == false` (the default), running workers are not
  interrupted by blocker changes; the gate only re-applies on the next dispatch attempt
  after the worker exits naturally.

### 8.6 Startup Terminal Workspace Cleanup

When the service starts:

1. Query tracker for issues in terminal states.
2. For each returned issue identifier, remove the corresponding workspace directory.
3. If the terminal-issues fetch fails, log a warning and continue startup.

This prevents stale terminal workspaces from accumulating after restarts.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root:

- `workspace.root` (normalized absolute path)

Per-issue workspace path:

- `<workspace.root>/<sanitized_issue_identifier>`

Workspace persistence:

- Workspaces are reused across runs for the same issue.
- Successful runs do not auto-delete workspaces.

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary:

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Ensure the workspace path exists as a directory.
4. Mark `created_now=true` only if the directory was created during this call; otherwise
   `created_now=false`.
5. If `created_now=true`, run `after_create` hook if configured.

Notes:

- This section does not assume any specific repository/VCS workflow.
- Workspace preparation beyond directory creation (for example dependency bootstrap, checkout/sync,
  code generation) is implementation-defined and is typically handled via hooks.

### 9.3 OPTIONAL Workspace Population (Implementation-Defined)

The spec does not require any built-in VCS or repository bootstrap behavior.

Implementations MAY populate or synchronize the workspace using implementation-defined logic and/or
hooks (for example `after_create` and/or `before_run`).

Failure handling:

- Workspace population/synchronization failures return an error for the current attempt.
- If failure happens while creating a brand-new workspace, implementations MAY remove the partially
  prepared directory.
- Reused workspaces SHOULD NOT be destructively reset on population failure unless that policy is
  explicitly chosen and documented.

### 9.4 Workspace Hooks

Supported hooks:

- `hooks.after_create`
- `hooks.before_run`
- `hooks.after_run`
- `hooks.before_remove`

Execution contract:

- Execute in a local shell context appropriate to the host OS, with the workspace directory as
  `cwd`.
- On POSIX systems, `sh -lc <script>` (or a stricter equivalent such as `bash -lc <script>`) is a
  conforming default.
- Hook timeout uses `hooks.timeout_ms`; default: `60000 ms`.
- Log hook start, failures, and timeouts.

Failure semantics:

- `after_create` failure or timeout is fatal to workspace creation.
- `before_run` failure or timeout is fatal to the current run attempt.
- `after_run` failure or timeout is logged and ignored.
- `before_remove` failure or timeout is logged and ignored.

### 9.5 Safety Invariants

This is the most important portability constraint.

Invariant 1: Run the coding agent only in the per-issue workspace path.

- Before launching the coding-agent subprocess, validate:
  - `cwd == workspace_path`

Invariant 2: Workspace path MUST stay inside workspace root.

- Normalize both paths to absolute.
- Require `workspace_path` to have `workspace_root` as a prefix directory.
- Reject any path outside the workspace root.

Invariant 3: Workspace key is sanitized.

- Only `[A-Za-z0-9._-]` allowed in workspace directory names.
- Replace all other characters with `_`.

## 10. Agent Runner Protocol (Coding Agent Integration)

This section defines Symphony's language-neutral responsibilities when integrating a Codex
app-server. The Codex app-server protocol for the targeted Codex version is the source of truth for
protocol schemas, message payloads, transport framing, and method names.

Protocol source of truth:

- Implementations MUST send messages that are valid for the targeted Codex app-server version.
- Implementations MUST consult the targeted Codex app-server documentation or generated schema
  instead of treating this specification as a protocol schema.
- If this specification appears to conflict with the targeted Codex app-server protocol, the Codex
  protocol controls protocol shape and transport behavior.
- Symphony-specific requirements in this section still control orchestration behavior, workspace
  selection, prompt construction, continuation handling, and observability extraction.

### 10.1 Launch Contract

Subprocess launch parameters:

- Command: `codex.command`
- Invocation: `bash -lc <codex.command>`
- Working directory: workspace path
- Transport/framing: the protocol transport required by the targeted Codex app-server version

Notes:

- The default command is `codex app-server`.
- Approval policy, sandbox policy, cwd, prompt input, and OPTIONAL tool declarations are supplied
  using fields supported by the targeted Codex app-server version.

RECOMMENDED additional process settings:

- Max line size: 10 MB (for safe buffering)

### 10.2 Session Startup Responsibilities

Reference: https://developers.openai.com/codex/app-server/

Startup MUST follow the targeted Codex app-server contract. Symphony additionally requires the
client to:

- Start the app-server subprocess in the per-issue workspace.
- Initialize the app-server session using the targeted Codex app-server protocol.
- Create or resume a coding-agent thread according to the targeted protocol.
- Supply the absolute per-issue workspace path as the thread/turn working directory wherever the
  targeted protocol accepts cwd.
- Start the first turn with the rendered issue prompt.
- Start later in-worker continuation turns on the same live thread with continuation guidance rather
  than resending the original issue prompt.
- Supply the implementation's documented approval and sandbox policy using fields supported by the
  targeted protocol.
- Include issue-identifying metadata, such as `<issue.identifier>: <issue.title>`, when the targeted
  protocol supports turn or session titles.
- Advertise implemented client-side tools using the targeted protocol.

Session identifiers:

- Extract `thread_id` from the thread identity returned by the targeted Codex app-server protocol.
- Extract `turn_id` from each turn identity returned by the targeted Codex app-server protocol.
- Emit `session_id = "<thread_id>-<turn_id>"`
- Reuse the same `thread_id` for all continuation turns inside one worker run

### 10.3 Streaming Turn Processing

The client processes app-server updates according to the targeted Codex app-server protocol until
the active turn terminates.

Completion conditions:

- Targeted-protocol turn completion signal -> success
- Targeted-protocol turn failure signal -> failure
- Targeted-protocol turn cancellation signal -> failure
- turn timeout (`turn_timeout_ms`) -> failure
- subprocess exit -> failure

Continuation processing:

- If the worker decides to continue after a successful turn, it SHOULD start another turn on the same
  live thread using the targeted protocol.
- The app-server subprocess SHOULD remain alive across those continuation turns and be stopped only
  when the worker run is ending.

Transport handling requirements:

- Follow the transport and framing rules of the targeted Codex app-server version.
- For stdio-based transports, keep protocol stream handling separate from diagnostic stderr
  handling unless the targeted protocol specifies otherwise.

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

The app-server client emits structured events to the orchestrator callback. Each event SHOULD
include:

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `codex_app_server_pid` (if available)
- OPTIONAL `usage` map (token counts)
- payload fields as needed

Important emitted events include, for example:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

### 10.5 Approval, Tool Calls, and User Input Policy

Approval, sandbox, and user-input behavior is implementation-defined.

Policy requirements:

- Each implementation MUST document its chosen approval, sandbox, and operator-confirmation
  posture.
- Approval requests and user-input-required events MUST NOT leave a run stalled indefinitely. An
  implementation MAY either satisfy them, surface them to an operator, auto-resolve them, or
  fail the run according to its documented policy.

Example high-trust behavior:

- Auto-approve command execution approvals for the session.
- Auto-approve file-change approvals for the session.
- Treat user-input-required turns as hard failure.

Unsupported dynamic tool calls:

- Supported dynamic tool calls that are explicitly implemented and advertised by the runtime SHOULD
  be handled according to their extension contract.
- If the agent requests a dynamic tool call that is not supported, return a tool failure response
  using the targeted protocol and continue the session.
- This prevents the session from stalling on unsupported tool execution paths.

Optional client-side tool extension:

- An implementation MAY expose a limited set of client-side tools to the app-server session.
- Current standardized optional tool: `github_graphql`.
- If implemented, supported tools SHOULD be advertised to the app-server session during startup
  using the protocol mechanism supported by the targeted Codex app-server version.
- Unsupported tool names SHOULD still return a failure result using the targeted protocol and
  continue the session.

`github_graphql` extension contract:

- Purpose: execute a raw GraphQL query or mutation against the GitHub API using Symphony's
  configured tracker auth for the current session, so the coding agent can read or update Issues,
  Pull Requests, comments, project items, and field values without managing GitHub credentials
  itself.
- Availability: only meaningful when `tracker.kind == "github"` and valid GitHub auth is
  configured.
- Preferred input shape:

  ```json
  {
    "query": "single GraphQL query or mutation document",
    "variables": {
      "optional": "graphql variables object"
    }
  }
  ```

- `query` MUST be a non-empty string.
- `query` MUST contain exactly one GraphQL operation.
- `variables` is OPTIONAL and, when present, MUST be a JSON object.
- Implementations MAY additionally accept a raw GraphQL query string as shorthand input.
- Execute one GraphQL operation per tool call.
- If the provided document contains multiple operations, reject the tool call as invalid input.
- `operationName` selection is intentionally out of scope for this extension.
- Reuse the configured GitHub endpoint and auth from the active Symphony workflow/runtime
  config; do not require the coding agent to read raw tokens from disk. The configured
  `Authorization: Bearer <token>` header MUST be applied for every tool call.
- Tool result semantics:
  - transport success + no top-level GraphQL `errors` -> `success=true`
  - top-level GraphQL `errors` present -> `success=false`, but preserve the GraphQL response body
    for debugging
  - HTTP 429 / `Retry-After` secondary rate-limit response -> `success=false` with an error
    payload that surfaces the `Retry-After` value (the model MAY back off voluntarily, but the
    tool itself MUST NOT block waiting)
  - invalid input, missing auth, or transport failure -> `success=false` with an error payload
- Return the GraphQL response or error payload as structured tool output that the model can inspect
  in-session.
- Implementations MAY narrow the tool's effective scope (for example, restrict it to a specific
  Project v2, repository, owner, or to read-only operations) when the deployment's hardening
  posture requires it. See Section 15.5.

User-input-required policy:

- Implementations MUST document how targeted-protocol user-input-required signals are handled.
- A run MUST NOT stall indefinitely waiting for user input.
- A conforming implementation MAY fail the run, surface the request to an operator, satisfy it
  through an approved operator channel, or auto-resolve it according to its documented policy.
- The example high-trust behavior above fails user-input-required turns immediately.

### 10.6 Timeouts and Error Mapping

Timeouts:

- `codex.read_timeout_ms`: request/response timeout during startup and sync requests
- `codex.turn_timeout_ms`: total turn stream timeout
- `codex.stall_timeout_ms`: enforced by orchestrator based on event inactivity

Error mapping (RECOMMENDED normalized categories):

- `codex_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `port_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 10.7 Agent Runner Contract

The `Agent Runner` wraps workspace + prompt + app-server client.

Behavior:

1. Create/reuse workspace for issue.
2. Build prompt from workflow template.
3. Start app-server session.
4. Forward app-server events to orchestrator.
5. On any error, fail the worker attempt (the orchestrator will retry).

Note:

- Workspaces are intentionally preserved after successful runs.

## 11. Issue Tracker Integration Contract (GitHub Projects v2)

### 11.1 REQUIRED Operations

An implementation MUST support these tracker adapter operations:

1. `fetch_candidate_issues()`
   - Return all project items whose effective state is in `active_states`, after applying the
     terminal-OR rule from Section 11.2.1 and the `include_kinds` filter from Section 5.3.1.
   - The returned values MUST conform to the Issue domain model in Section 4.1.1.

2. `fetch_issues_by_states(state_names)`
   - Return all project items whose effective state is in the supplied list of state names.
   - Used for startup terminal cleanup with `state_names = terminal_states`.
   - When the supplied list is empty, return an empty list without making any API call.

3. `fetch_issue_states_by_ids(issue_ids)`
   - Look up the current effective state for the given list of project item IDs.
   - Used for active-run reconciliation.
   - When `issue_ids` is empty, the implementation MUST return an empty list without making any
     API call.
   - Each returned record MUST include at minimum `id`, `identifier`, and `state` (the effective
     state per Section 11.2.1). The full Issue model MAY also be returned.
   - Items that no longer exist in the configured project MUST be omitted (`nodes(ids:)` returns
     `null` for unresolvable IDs, and `ProjectV2Item.type == REDACTED` MUST also be dropped); the
     orchestrator treats absence as "no longer active".

The behaviour above is defined in tracker-neutral terms. Subsections 11.2–11.6 describe how it is
realized for `tracker.kind == "github"`.

### 11.2 Query Semantics (GitHub)

GitHub-specific requirements for `tracker.kind == "github"`:

- Transport: HTTP POST against the configured GraphQL endpoint
  (default `https://api.github.com/graphql`).
- Auth: `Authorization: Bearer <token>` using `tracker.api_token` after `$VAR` resolution.
  GitHub also accepts the legacy `Authorization: token <pat>` header for classic PATs; this
  specification mandates the `Bearer` form for uniformity with GitHub Apps and fine-grained
  PATs.
- Content type: `application/json`.
- Implementations SHOULD send the `X-Github-Next-Global-ID: 1` request header so that node
  IDs returned by the API are in the new global format (legacy IDs are deprecated and may be
  rejected by Projects v2 mutations in the future).
- Network timeout per request: `30000 ms`.

Concrete request shape (illustrative, not normative on header order):

```http
POST /graphql HTTP/1.1
Host: api.github.com
Authorization: Bearer ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxx
Content-Type: application/json
X-Github-Next-Global-ID: 1
User-Agent: symphony/<version>

{"query":"query SymphonyProjectItems(...) { ... }","variables":{"projectId":"PVT_..."}}
```
- Pagination is REQUIRED for the project items connection.
  - GraphQL `first` argument MUST be `<= 100` (GitHub's hard cap).
  - Default page size: `100`.
  - Loop until `pageInfo.hasNextPage` is false; pass `pageInfo.endCursor` as `after`.
  - Treat `pageInfo.hasNextPage == true && pageInfo.endCursor == null` as
    `github_missing_end_cursor`. Do not loop with a null cursor; abort the fetch and surface
    the error.
  - Items MAY shift between pages when the project is mutated mid-pagination. Implementations
    MUST NOT try to reconcile mid-loop; the next tick re-fetches.
- Server-side filtering of project items by Status is **not supported** by GitHub's GraphQL API
  for Projects v2 (the `items` connection accepts no filter argument). Implementations MUST
  paginate the full set of items and apply state and `include_kinds` filters client-side.
- Implementations SHOULD include `rateLimit { limit cost remaining used resetAt }` on every
  GraphQL query they issue and SHOULD back off voluntarily as `remaining` approaches zero.
- GitHub exposes two distinct rate-limit signals that the spec treats separately:
  - **Primary limit exhaustion**: a successful HTTP 200 GraphQL response that includes a
    `rateLimit.remaining == 0` (or near-zero) value and a `rateLimit.resetAt` timestamp. The
    implementation SHOULD delay subsequent tracker calls until `rateLimit.resetAt` and emit
    `github_rate_limited` with a payload that quotes `resetAt`.
  - **Secondary limit / abuse detection**: HTTP 429, or HTTP 403 carrying a `Retry-After`
    response header. The implementation MUST wait at least `Retry-After` seconds (the value
    is in seconds) before retrying any GitHub GraphQL request, MUST emit `github_rate_limited`
    with a payload quoting the `Retry-After` value, and MUST NOT block the orchestrator main
    loop while waiting (use the standard skip-this-tick path from Section 11.4).
  - When both signals are present (rare), prefer the longer of the two waits.
- Project resolution:
  - If `tracker.project_id` is configured, fetch the project via
    `node(id: $id) { __typename ... on ProjectV2 { id title number } }`. The implementation
    MUST verify `__typename == "ProjectV2"` and raise `tracker_project_not_found` otherwise;
    a non-`ProjectV2` node ID returns a non-null `node` with null inline-fragment fields and
    MUST NOT be conflated with `github_unknown_payload`.
  - Otherwise, fetch via `organization(login: $owner)` or `user(login: $owner)` selected by
    `tracker.owner_type`, with `projectV2(number: $project_number)`. A null `projectV2`
    raises `tracker_project_not_found`.
  - Implementations MUST NOT silently fall back to the other owner type when one resolves to
    null. Operators are expected to set `owner_type` correctly; the resulting
    `tracker_project_not_found` error message SHOULD include the resolved owner login and the
    configured `owner_type` so misconfiguration is diagnosable.
  - The resolved Project v2 node ID MUST be cached for the lifetime of the process.

#### 11.2.1 Effective State and Terminal-OR Rule

The `state` field on a normalized Issue (Section 4.1.1) is the value of the configured Status
single-select field on the project item. When the Status field is unset for an item, the
effective state SHOULD be the literal string `<no status>`.

For dispatch and reconciliation purposes, the orchestrator MUST treat an item as **terminal**
when **either** of the following is true:

- The lowercased effective state is in the lowercased `terminal_states` list, or
- The underlying content is closed at the GitHub level: `Issue.state == CLOSED`,
  or `PullRequest.state ∈ {CLOSED, MERGED}`.

An item is treated as **active** only when:

- The lowercased effective state is in the lowercased `active_states` list, **and**
- Either the kind is `draft_issue`, or the underlying content is open
  (`Issue.state == OPEN`, `PullRequest.state == OPEN`).

Items whose effective state is `<no status>` (Status unset) MUST be treated as inactive and
non-terminal: do not dispatch, do not trigger workspace cleanup, and do not stop running workers
on this signal alone.

This dual-source rule is necessary because closing a GitHub Issue or merging a PR does not
automatically update the Project v2 Status field.

A Pull Request that is closed without being merged (`pr.state == CLOSED`, `pr.merged == false`)
is treated identically to a merged PR for the purposes of dispatch and reconciliation: the item
is terminal, any running worker is terminated, and the workspace is cleaned by the standard
terminal-transition path (Section 8.5 Part B). Implementations that wish to preserve abandoned-
PR workspaces for human inspection MAY do so via the `before_remove` hook; the orchestrator
itself does not differentiate "closed-merged" from "closed-abandoned".

#### 11.2.2 Candidate Items Query

A conforming implementation SHOULD use a query of the following shape (field selection MAY be
reordered or extended; required fields are those used by the domain model in Section 4.1.1):

```graphql
query SymphonyProjectItems($projectId: ID!, $first: Int!, $after: String) {
  rateLimit { limit cost remaining used resetAt }
  node(id: $projectId) {
    ... on ProjectV2 {
      id title number
      items(first: $first, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          type
          isArchived
          createdAt
          updatedAt
          fieldValueByName(name: "Status") {
            __typename
            ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
          }
          # If tracker.priority_field is set, also include:
          # fieldValueByName(name: "Priority") {
          #   __typename
          #   ... on ProjectV2ItemFieldSingleSelectValue { name }
          #   ... on ProjectV2ItemFieldNumberValue       { number }
          #   ... on ProjectV2ItemFieldTextValue         { text }
          # }
          # The implementation detects the field's actual type from __typename:
          # SingleSelect -> map name via tracker.priority_mapping;
          # Number       -> coerce to integer;
          # Text         -> attempt integer parse, otherwise label fallback;
          # Date / Iteration / unsupported types -> drop and emit one warning per reload.
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
              reviewDecision
              mergeable
              mergeStateStatus
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

Archived project items (`isArchived == true`) MUST be filtered out before normalization.

#### 11.2.3 Issue State Refresh Query

`fetch_issue_states_by_ids(issue_ids)` SHOULD use the GraphQL `nodes(ids: [ID!]!)` form to look up
many project items in one round trip:

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

For each input ID, the implementation MUST return either a record reflecting the current
effective state (per Section 11.2.1) or omit the ID when the item no longer resolves.

#### 11.2.4 Status Field Probe

Because `fieldValueByName(name: "Status")` returns null both when the field is unset on a given
item and when the project has no field by that name at all, implementations MUST distinguish the
two cases at startup. A conforming probe queries the project's defined fields once and verifies
the configured `tracker.status_field` exists:

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

If `field` is null, raise `tracker_status_field_missing` and block dispatch until the workflow
is corrected. If `field.__typename != "ProjectV2SingleSelectField"`, raise the same error: this
specification only supports a single-select Status field.

Implementations MAY skip the probe across reloads when neither the project identifier nor
`tracker.status_field` changed.

#### 11.2.5 Schema Drift

GitHub's GraphQL schema evolves; field availability and naming may change. Keep query
construction isolated to the GitHub adapter and add unit tests for the exact selection sets
required by this specification. The current specification version supports `tracker.kind ==
"github"` only; if a future specification version adds non-GitHub adapters they MAY change
transport details, but the normalized outputs MUST match the domain model in Section 4.

### 11.3 Normalization Rules

Candidate item normalization MUST produce fields listed in Section 4.1.1.

Additional normalization details:

- `kind`: derived from `ProjectV2Item.type` (`ISSUE` → `issue`, `PULL_REQUEST` → `pull_request`,
  `DRAFT_ISSUE` → `draft_issue`). Items of type `REDACTED` MUST be skipped silently.
- Items whose `content` resolves to `null` MUST be skipped silently. This typically happens
  when the polling token lacks repository-permission scope for the underlying Issue or PR,
  so the project entry remains visible while the content does not. They are distinct from
  `REDACTED` items but handled identically.
- `id`: the `ProjectV2Item.id` (NOT the underlying Issue/PR node ID). This guarantees a unique
  key per project and per kind.
- `identifier`:
  - `<owner>/<repo>#<number>` for `issue` and `pull_request`.
  - `draft:<short>` for `draft_issue`, where `<short>` is the last 8 characters of the project
    item node ID.
- `state`: the value of `fieldValueByName(name: tracker.status_field).name`, or `<no status>`
  when the field value is null/missing. Comparison against `active_states`/`terminal_states`
  is done after lowercasing both sides.
- `labels`: lowercased strings derived from `content.labels.nodes[].name`. Empty list for
  `draft_issue`.
- `priority`: derived from `tracker.priority_field` per Section 5.3.1. When the field is a
  single-select, look up its option name in `tracker.priority_mapping` (case-insensitive).
  When the field is a number field, pass the value through coerced to integer (drop the value
  if not coercible). When no priority signal is available, fall back to label-based parsing
  (`priority:<n>` or labels matching `tracker.priority_mapping` keys); otherwise null.
- `blocked_by`: derived from `Issue.trackedIssues.nodes` for items whose underlying content is
  an Issue. Each ref MUST set `state` to the GitHub Issue state (`OPEN` or `CLOSED`) so that
  the orchestrator's blocker rule (Section 8.2) can treat `CLOSED` as resolved. Pull Requests
  and Draft Issues have no blockers in this version.
  - The candidate query in Section 11.2.2 fetches only the first 50 tracked issues. This
    specification does not require paginating the dependencies connection in v1; an issue
    with more than 50 dependencies is treated as if only the first 50 are blockers.
    Implementations MAY paginate as an extension and SHOULD log a warning when truncation
    occurs.
  - Implementations MAY additionally accept label-based blockers of the form
    `blocked-by:<owner>/<repo>#<number>` or `blocked-by:#<number>` when no
    `trackedIssues` connection is available. This fallback MUST be opt-in and explicitly
    documented.
- `pr.state`: GitHub `PullRequest.state` (`OPEN`, `CLOSED`, or `MERGED`).
- `pr.merged`, `pr.merged_at`, `pr.closed_at`, `pr.is_draft`, `pr.base_ref_name`: copied
  through.
- `pr.review_decision`: `PullRequest.reviewDecision`. Preserve `null` distinctly from
  `REVIEW_REQUIRED` (Section 4.1.1).
- `pr.mergeable`, `pr.merge_state_status`: copied through. `mergeStateStatus == DRAFT` is
  derived from `isDraft`; the implementation MAY drop `DRAFT` from `merge_state_status`
  reporting since `pr.is_draft` already carries the same signal.
- `pr.check_state`: `commits.last.commit.statusCheckRollup.state`. When the PR has no
  `statusCheckRollup` (no checks configured), set to `null` rather than fabricating a value.
- `pr.unresolved_review_threads`: count `reviewThreads.nodes` where
  `isResolved == false && isOutdated == false`.
- `pr.latest_opinionated_reviews`: list each
  `latestOpinionatedReviews.nodes` entry as `{state, author_login, submitted_at}`. Sort by
  `submitted_at` descending so callers can take `[0]` as the most recent opinion.
- `pr.requested_reviewers`: flatten `reviewRequests.nodes[].requestedReviewer` into a list of
  strings — `User.login`, `Team.slug`, or `Mannequin.login`. Deduplicate.
- `branch_name`: `PullRequest.headRefName` for `pull_request` kind; null otherwise.
- `issue_state`: `Issue.state` for `issue`; `pr.state` for `pull_request`; null for
  `draft_issue`.
- `created_at` / `updated_at`: ISO-8601 timestamps from the underlying content
  (`Issue/PullRequest/DraftIssue.createdAt|updatedAt`).

### 11.4 Error Handling Contract

RECOMMENDED error categories:

- `unsupported_tracker_kind`
- `missing_tracker_api_token`
- `missing_tracker_project_identifier` (neither `project_id` nor (`owner` + `project_number`)
  is present)
- `tracker_project_not_found` (the configured project does not resolve, or the resolved node
  is not a `ProjectV2`)
- `tracker_status_field_missing` (the configured `tracker.status_field` does not exist on the
  resolved project, or exists but is not a `ProjectV2SingleSelectField`)
- `tracker_permission_denied` (HTTP 401, HTTP 403 without `Retry-After`, or HTTP 200 carrying
  a top-level GraphQL error whose `type` is `FORBIDDEN` or `INSUFFICIENT_SCOPES`). Treated as
  startup-blocking, equivalent in severity to `tracker_status_field_missing`: dispatch is
  refused until the operator updates the token, because retrying with the same token will
  deterministically reproduce the failure.
- `github_api_request` (transport failures)
- `github_api_status` (non-200 HTTP responses other than 429)
- `github_rate_limited` (HTTP 429 or HTTP 403 with `Retry-After`; payload SHOULD surface the
  `Retry-After` value the orchestrator/agent saw)
- `github_graphql_errors` (top-level GraphQL `errors`)
- `github_unknown_payload` (response shape did not match expectations)
- `github_missing_end_cursor` (pagination integrity error)
- `unsupported_pr_signal` (unknown entry in `tracker.pr_dispatch_signals` or
  `tracker.pr_block_signals`; payload includes the rejected signal name)

Extensions defined in Appendices B and C add their own error categories scoped to those
extensions. See §B.7 (webhook listener) and §C.6 (comment control plane). Those categories
are deliberately not duplicated in §11.4 because they are not produced by the tracker
adapter itself.

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick. The next tick retries.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.
- `github_rate_limited`: for secondary limits (HTTP 429 / 403 + `Retry-After`), implementations
  MUST delay the next tracker call by at least `Retry-After` seconds. For primary limit
  exhaustion (HTTP 200 + `rateLimit.remaining == 0`), implementations SHOULD delay the next
  tracker call until `rateLimit.resetAt`. Workers already running are not interrupted by
  rate-limit errors.

### 11.5 Tracker Writes (Important Boundary)

Symphony does not require first-class tracker write APIs in the orchestrator.

- Issue/PR mutations (Status field changes, comments, PR linkage, labels, sub-issue/dependency
  updates) are typically handled by the coding agent using tools defined by the workflow
  prompt.
- The service remains a scheduler/runner and tracker reader.
- Workflow-specific success often means "reached the next handoff state" (for example
  `Human Review`) rather than tracker terminal state `Done`.
- If the `github_graphql` client-side tool extension is implemented, it is still part of the
  agent toolchain rather than orchestrator business logic.

### 11.6 Required GitHub Token Permissions

The configured `tracker.api_token` MUST have at minimum the permissions to read the target
Project v2 and the underlying Issues and Pull Requests. RECOMMENDED minimum scopes:

- Classic PAT: `read:project` (or `project` if the agent is allowed to mutate via
  `github_graphql`) plus `repo` (or `public_repo` for public-only repositories).
- Fine-grained PAT:
  - Repository permissions: `Issues: Read`, `Pull requests: Read`, `Metadata: Read` (mandatory).
  - Organization permissions: `Projects: Read` (or `Read and write` if agent mutations are
    expected).
- GitHub App: equivalent permissions, scoped to the installation that owns the project.

When the Comment Control Plane extension (Appendix C) is enabled, the configured token
additionally requires permission to read repository collaborator metadata, because §C.4
resolves comment-author permission via
`GET /repos/{owner}/{repo}/collaborators/{login}/permission`:

- Classic PAT: `repo` already covers this.
- Fine-grained PAT: `Members: Read` at the **organization** level (NOT repository
  scope). A token scoped only to one repository will receive HTTP 403 from this endpoint
  and the comment control plane will silently reject every command.
- GitHub App: `members: read` (organization permission).

When the Comment Control Plane extension is disabled, this scope is not required.

Implementations SHOULD document the permission model they require and MUST detect
permission-denied responses at startup validation. Permission-denied surfaces in two shapes:

- HTTP 401 or HTTP 403 (without a `Retry-After` header) → map to `tracker_permission_denied`.
- HTTP 200 with a GraphQL error whose `type` is `FORBIDDEN` or `INSUFFICIENT_SCOPES` (most
  commonly seen when the token lacks `read:project` for Projects v2) → also map to
  `tracker_permission_denied`, NOT to the generic `github_graphql_errors` bucket. The
  generic bucket would otherwise loop forever in skip-this-tick mode with no operator
  signal.

### 11.7 PR Review and CI Awareness Extension (OPTIONAL)

Symphony's core dispatch loop only consults project Status and the terminal-OR rule
(Section 11.2.1). Pull Request items expose richer signals — review decisions, unresolved
review threads, and CI rollup state — that workflows often want to react to. This section
defines an OPTIONAL extension that adds two PR-specific dispatch predicates.

The extension is purely additive: when not configured, behavior matches Section 11.2.1
exactly. When configured, the predicates apply only to items whose `kind == "pull_request"`.

#### 11.7.1 Configuration

Under `tracker`:

- `tracker.pr_dispatch_signals` (list of strings, OPTIONAL)
  - Each entry names a PR signal that, when present, makes a PR dispatch-eligible **even if
    its project Status is not in `active_states`**. Supported entries:
    - `changes_requested` — at least one entry in `pr.latest_opinionated_reviews` has
      `state == CHANGES_REQUESTED`, **and** `pr.unresolved_review_threads > 0`. The
      `unresolved_review_threads` clause is a "still actionable" proxy: if all threads have
      been resolved (typically because the agent or a maintainer marked them so), there is
      nothing for a re-dispatch to address.
    - `ci_failure` — `pr.check_state ∈ {ERROR, FAILURE}`.
    - `review_requested` — at least one login in `tracker.pr_self_reviewer_logins` appears
      in `pr.requested_reviewers`.
  - Default: empty list (extension disabled).
  - Items dispatched solely because of a PR signal are subject to all other eligibility
    rules (concurrency, claims, blockers).
  - Per-author review collapsing: GitHub's `latestOpinionatedReviews(writersOnly: true)`
    already returns the most recent opinionated review per author (states `APPROVED` and
    `CHANGES_REQUESTED`; non-opinionated states `COMMENTED`/`DISMISSED`/`PENDING` are
    excluded). The implementation iterates the list directly without de-duplicating.
    Worked example for reviewer Alice:
    - Alice posts `CHANGES_REQUESTED`, then `COMMENTED`, then `APPROVED` —
      `latestOpinionatedReviews` returns Alice's `APPROVED` (the `COMMENTED` is filtered
      out, the `APPROVED` supersedes the earlier `CHANGES_REQUESTED`). The
      `changes_requested` predicate does not match for Alice.
    - Alice posts `CHANGES_REQUESTED`, then `COMMENTED` — `latestOpinionatedReviews`
      returns Alice's `CHANGES_REQUESTED`. The predicate matches (subject to the
      `unresolved_review_threads > 0` clause).

- `tracker.pr_self_reviewer_logins` (list of strings, OPTIONAL)
  - Logins that identify the Symphony deployment to itself (typically the GitHub App or
    bot user that owns `tracker.api_token`). Used by the `review_requested` signal and by
    any workflow that needs to distinguish "human asked us to review" from "human asked
    another reviewer."

- `tracker.pr_block_signals` (list of strings, OPTIONAL)
  - Each entry names a PR signal that, when present, **disqualifies** a PR from dispatch
    even if its project Status is in `active_states`. Supported entries:
    - `awaiting_human_review` — `pr.review_decision == REVIEW_REQUIRED` AND no entry in
      `tracker.pr_self_reviewer_logins` is among `pr.requested_reviewers`.
    - `mergeable_unknown` — `pr.mergeable == UNKNOWN`. Useful as a brief soft-pause to
      let GitHub finish computing mergeability after a `synchronize` event.
    - `merge_state_blocked` — `pr.merge_state_status == BLOCKED` **and**
      `pr.review_decision == REVIEW_REQUIRED`. The `REVIEW_REQUIRED` clause is critical:
      `mergeStateStatus == BLOCKED` also fires when CI is failing on a required check, but
      that is exactly the situation `pr_dispatch_signals.ci_failure` is designed to act on.
      Without the `REVIEW_REQUIRED` clause, configuring `ci_failure` and
      `merge_state_blocked` together would silently no-op every CI failure.
  - Default: empty list (extension disabled).

`pr_dispatch_signals` is evaluated **before** `pr_block_signals`; if a PR matches both, the
block wins. This makes block signals a hard veto.

#### 11.7.2 Effective State for PRs Under the Extension

When the extension is configured, a PR's effective dispatch eligibility is:

```
eligible_pr =
    (status in active_states OR any signal in pr_dispatch_signals matches)
  AND NOT (any signal in pr_block_signals matches)
  AND NOT terminal-OR rule (Section 11.2.1)
  AND blocker rule passes
```

The terminal-OR rule still wins: a closed or merged PR is terminal regardless of any
configured signal.

PR items MUST also pass the dependency gate (Section 8.2.1). The PR-specific dispatch
predicates do not bypass blocker enforcement: a PR with `CHANGES_REQUESTED` and an open
sub-issue dependency is gated, not dispatched. The block-vs-dispatch evaluation order
inside Section 11.7 (block wins) is independent of this — the dependency gate is an
outer eligibility check applied to all kinds, and a PR that fails the dependency gate
never reaches the §11.7 predicates.

#### 11.7.3 Continuation-Run Semantics

When a PR is dispatched because of `changes_requested` or `ci_failure`, the prompt template
SHOULD render with `attempt` non-null and SHOULD have access to the relevant signal so the
agent's prompt can address the right thing. The standard template variables already expose
`issue.pr.review_decision`, `issue.pr.check_state`, and
`issue.pr.latest_opinionated_reviews`; workflows are expected to branch on these values
inside their Markdown body.

The orchestrator does not auto-resolve review threads, dismiss reviews, or push commits.
Those mutations remain the agent's job (typically via `github_graphql` or `gh` CLI inside
the workspace). A successful agent run that pushes new commits will trigger the same
dispatch predicates on the next tick — ensure workflow prompts terminate the loop with a
clear handoff state, rather than letting the agent perpetually re-respond to its own CI
failures.

#### 11.7.4 Validation

Dispatch preflight (Section 6.3) MUST reject `tracker.pr_dispatch_signals` and
`tracker.pr_block_signals` containing values not listed above; raise
`unsupported_pr_signal` with the offending signal name in the payload.

### 11.8 Agent Workpad Protocol (OPTIONAL but RECOMMENDED)

Symphony's per-issue workspaces are ephemeral. The orchestrator cleans them up on
terminal transitions (Section 9), and a worker that runs on a different host on the
next dispatch has no on-disk state at all. When a human moves a Project item back
to an active Status — most commonly `Rework` after `Done` or `In Review` — the agent
needs to know two things that span sessions:

1. **What did the prior session(s) actually accomplish, conclude, or get stuck on?**
2. **What changed since the prior session ended (new comments, new review threads)?**

Section 12.3 already exposes `last_run_completed_at` so the agent can scope (2).
This section defines a complementary in-band memory mechanism for (1): the **agent
workpad** — a single, agent-edited issue comment that records every session against
the underlying Issue or Pull Request.

The workpad lives entirely in the tracker (a GitHub Issue or PullRequest comment).
The orchestrator MUST NOT post, edit, or delete the workpad directly; per
Section 11.5 it owns no tracker writes. Instead, the orchestrator supplies the
agent with the identifiers and statistics the workpad needs, and the agent is
responsible for find-or-create + edit operations via the `github_graphql` Codex
tool (Section 18.2.1).

**Item-kind scope.** The protocol applies only when `issue.kind ∈ {"issue", "pull_request"}`
— both correspond to real GitHub `Commentable` node types (Issue, PullRequest). When
`issue.kind == "draft_issue"`, the underlying Project v2 DraftIssue is not
`Commentable` (an `addComment` mutation against it returns a GraphQL type error), so
the orchestrator MUST omit the workpad prompt variables (Section 11.8.5) and the
workflow template MUST tolerate their absence (Section 11.8.9). Draft Issues are
expected to be promoted to a real Issue early in their lifecycle, at which point
the protocol becomes active on subsequent dispatches.

**Interaction with Section 11.7.** When the PR Review and CI Awareness extension
re-dispatches a PR because a dispatch signal (`changes_requested`, `ci_failure`,
`review_requested`) fired, the re-dispatch is a new session row in the workpad,
not a continuation of the prior session's row. The §11.7 predicate decides
*whether* to dispatch; the workpad records *every* dispatch as a distinct row
keyed by Codex thread id (Section 11.8.5).

#### 11.8.1 Workpad Identity and Discovery

A workpad is a single comment on the GitHub Issue or PullRequest that backs the
project item. It is identified by an opening HTML comment marker on the first
line of the comment body:

```
<!-- symphony-workpad:v1 -->
```

And a closing marker on the last line:

```
<!-- /symphony-workpad:v1 -->
```

The marker `v1` is a protocol version. Implementations MAY introduce `v2` later;
the agent MUST treat an unknown version as "not a workpad I can edit safely" and
fall back to creating a new one rather than risk stomping a future format.

To find the existing workpad on dispatch, the agent MUST:

1. Read the underlying Issue or PullRequest's comments via the GraphQL
   `comments` connection. Use `gh issue view <number> --json comments` for
   `issue.kind == "issue"` and `gh pr view <number> --json comments` for
   `issue.kind == "pull_request"` — the two CLI surfaces are not interchangeable
   even though both expose the same `IssueComment` node type underneath. The
   equivalent GraphQL is `repository(owner, name) { issue(number) { comments(...) } }`
   or `repository(owner, name) { pullRequest(number) { comments(...) } }`. The
   field `issueOrPullRequest` does NOT exist on `Repository`; an agent that
   issues that query receives a schema error.
2. Paginate. The agent MUST paginate forward via `comments(first: N, after: $cursor)`
   until the marker is found OR `pageInfo.hasNextPage` is false. A single
   `comments(last: 100)` request silently truncates issues with more than 100
   comments and would lose an old workpad in a chatty issue.
3. Project each comment with at minimum `id`, `databaseId`, `body`, `createdAt`,
   `author { login }`. Do NOT use `viewerDidAuthor` — it is a field on
   `Reactable`, not on `IssueComment`. The "did I (the agent) author this?"
   signal MUST come from comparing `author.login` against the configured agent
   identity (the PAT user, or `<app-name>[bot]` for GitHub App installations).
4. Filter for comments whose body, after trimming leading whitespace, starts
   with `<!-- symphony-workpad:v` followed by a recognized version number.
   The `String.starts_with?/2`-equivalent matching MUST be on the trimmed body,
   NOT a substring search — comments quoting the marker inside fenced code are
   ignored.
5. If exactly one match is found, that is the workpad. Capture its node id
   (for `updateIssueComment` mutations) and body.
6. If zero matches are found, the agent creates a new workpad (Section 11.8.4)
   on its first relevant edit.
7. If more than one match is found, the agent SHOULD log a warning and operate
   on the deterministically-newest one, ordered by `(createdAt DESC,
   databaseId DESC)`. `createdAt` has second precision and can collide between
   two near-simultaneous `addComment` calls; `databaseId` is monotonic and
   provides the secondary tiebreaker. Multiple workpads indicate either a prior
   protocol bug or concurrent orchestrator runs (which Section 11.8.7 forbids);
   the operator should resolve manually.

#### 11.8.2 Workpad Structure

A v1 workpad MUST conform to the following structure:

```
<!-- symphony-workpad:v1 -->
## Symphony agent workpad

### Sessions

| Session | Attempt | Started (UTC) | Ended (UTC) | Duration | Model | Stop reason |
|---|---|---|---|---|---|---|
| `<thread_id>` | <attempt> | <iso8601> | <iso8601 or "—"> | <hh:mm:ss or "—"> | <model> | <reason or "—"> |
| ... | ... | ... | ... | ... | ... | ... |

### Current session — `<thread_id>`, attempt <N>

<freeform agent-authored body: goals, plan, actions taken, open questions>

<!-- /symphony-workpad:v1 -->
```

Field constraints:

- **Session column.** The Codex thread id supplied by the orchestrator as the
  `thread_id` prompt variable (Section 11.8.5). The agent MUST render the value
  verbatim in a backtick code span. The spec makes no assumption about the
  identifier's shape — implementations MAY use ULIDs, UUIDs, or any other
  opaque token Codex emits. Section 4.2's compound `Session ID`
  (`<thread_id>-<turn_id>`) is NOT used here because the workpad records a
  whole session, not a per-turn position.
- **Attempt column.** The orchestrator-supplied `attempt` integer (1-indexed).
- **Started (UTC).** RFC3339 with seconds precision. Sourced from
  `dispatched_at` (Section 11.8.5).
- **Ended (UTC).** RFC3339 with seconds precision once the session terminates,
  or the literal string `—` while the session is in flight. The current session
  SHOULD render `—` until the agent's final turn, at which point it MAY update
  to the wall-clock time it observed last (the orchestrator-observed exit time
  is authoritative and visible in the structured logs of Section 13.1).
- **Duration.** Wall-clock between Started and Ended, formatted `<H>h<M>m<S>s`
  (lower components omitted when zero). `—` while in flight.
- **Model.** The Codex model identifier (for example `gpt-5.5`), supplied by
  the orchestrator (Section 11.8.5).
- **Stop reason.** The Section 13.1 worker-stop reason atom (without the
  leading colon) once known. `—` while in flight. The complete vocabulary is
  defined in Section 13.1; the agent MUST render whichever token the
  orchestrator-authored §13.1 log line carried — it MUST NOT invent new tokens.
  The agent's view of its own stop reason is best-effort; the authoritative
  record is in the orchestrator's logs.

The **freeform body** under "Current session" is at the agent's discretion. It
SHOULD record (at minimum) the goal, the plan, the actions taken, and any open
questions or blockers. It SHOULD NOT repeat content already present in the table
(thread id, model, etc.).

The workpad MUST NOT exceed the GitHub issue-comment body limit (empirically
observed at 65,536 characters; not enforced in the published GraphQL schema and
subject to change). When the sessions table grows beyond an implementation-defined
cap (configured via `agent.workpad.max_sessions_visible`, Section 11.8.9;
default 20 rows), the agent SHOULD fold older rows into a placeholder line
formatted exactly as:

```
| _(N prior sessions hidden)_ | | | | | | |
```

where `N` is the count of folded rows. The placeholder is purely informational;
the authoritative per-session log lives in Section 13.1 structured logs and the
orchestrator's `prior_sessions` prompt variable.

#### 11.8.3 Workpad Lifecycle

For every dispatched session, on **first turn**, the agent MUST:

1. Discover the existing workpad (Section 11.8.1) or note its absence.
2. If it exists: append a new row to the sessions table with the current session's
   metadata (Started, Attempt, Model from the prompt; Ended, Duration, Stop reason
   as `—`). Replace the "Current session" body with a fresh skeleton for this
   session.
3. If it does not exist: post a new comment containing a freshly initialized v1
   workpad with one row (this session) and an empty current-session body. Use the
   `addComment` mutation against the underlying Issue or PullRequest node id
   (Section 11.8.5's `subject_id` variable). `addComment` is on the default
   mutation allowlist (Section 18.2.1).

During execution, the agent SHOULD update the workpad body as plans evolve. The
agent SHOULD serialize workpad writes within a single session — two concurrent
`updateIssueComment` calls from the same agent against the same comment are
last-write-wins (Section 11.8.7) and risk dropping content. Implementations MAY
rate-limit workpad updates (for example: at most one `updateIssueComment` per N
turns, where N matches `agent.workpad.update_throttle_turns`) to control
mutation noise; the protocol does not require per-turn updates.

On the agent's **final turn** before voluntary completion, the agent MUST:

1. Update the current session's row to fill in Ended, Duration, and the agent's
   best-effort Stop reason (typically `agent_exit_normal`).
2. Move the "Current session" body content under a heading `### Session
   <thread_id> notes` (immediately above the current-session heading) so future
   sessions see the archived per-session detail rather than overwriting it.

A session that exits abnormally (orchestrator-driven termination, codex crash,
worker timeout) cannot update its own row. The next dispatched session MUST
patch the prior row using the values from `prior_sessions[0]` (Section 11.8.5),
which the orchestrator populates from its §13.1 termination record.

Each §11.7-driven re-dispatch (PR review or CI signal) opens a new session row
under the rules above; the prior row is closed out exactly as for any other
voluntary or abnormal exit.

#### 11.8.4 GitHub GraphQL Operations Required

All operations below are issued by the **agent** through the `github_graphql`
Codex tool (Section 18.2.1); per Section 11.5 the orchestrator MUST NOT invoke
them. Queries are unrestricted by the mutation allowlist; only the mutations
named below need to be on the allowlist for the agent to call them.

- **Read** the comment list (paginated, per Section 11.8.1):
  ```graphql
  query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) {  # or pullRequest(number: $number) depending on issue.kind
        comments(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes { id databaseId body createdAt author { login } }
        }
      }
    }
  }
  ```
  Branch on `issue.kind` to select `issue` vs `pullRequest`. The field
  `issueOrPullRequest` does NOT exist on `Repository`. Implementations MAY
  alternatively use the `node(id: $subject_id)` form with an inline fragment
  union over `Issue` and `PullRequest` to avoid the branch.
- **Create** the initial workpad:
  ```graphql
  mutation($subjectId: ID!, $body: String!) {
    addComment(input: { subjectId: $subjectId, body: $body }) {
      commentEdge { node { id databaseId } }
    }
  }
  ```
  `$subjectId` is the underlying Issue or PullRequest node id (NOT the Project
  v2 item id, which starts `PVTI_…`). It is supplied to the prompt as
  `subject_id` (Section 11.8.5). `addComment` is on the default mutation
  allowlist (Section 18.2.1) and requires no extension. DraftIssue node ids
  (starting `DI_`) are NOT `Commentable` and the mutation returns a type
  error — Section 11.8 already scopes this case out via item-kind exclusion.
- **Update** the workpad:
  ```graphql
  mutation($id: ID!, $body: String!) {
    updateIssueComment(input: { id: $id, body: $body }) {
      issueComment { id }
    }
  }
  ```
  `updateIssueComment` is **NOT** on the default mutation allowlist as of v1
  and MUST be added by implementations that enable the workpad protocol.
  Implementations SHOULD document this addition explicitly. The same mutation
  works for both Issue conversation comments and PullRequest conversation
  comments — they share the `IssueComment` GraphQL type. PullRequest
  *review-thread* comments are a separate `PullRequestReviewComment` type and
  use `updatePullRequestReviewComment`; the workpad protocol does NOT touch
  review-thread comments.
- **NEVER delete.** `deleteIssueComment` MUST NOT be added to the allowlist
  for workpad purposes. A workpad is append-only at the row level; corrections
  are done via `updateIssueComment`.

#### 11.8.5 Orchestrator Responsibilities

The orchestrator MUST extend the prompt rendering context with the following
variables in addition to those required by Section 12.1, but only when
`agent.workpad.enabled: true` (Section 11.8.9) AND `issue.kind ∈ {"issue", "pull_request"}`:

- **`thread_id`** (string, REQUIRED). The Codex thread identifier for the
  current dispatch — the stable per-session token Codex emits at session
  start, before any turn. This is the value the workpad uses to key its
  sessions table. Implementations capture it from the coding-agent app-server
  client (Section 10) immediately after the session is created and before the
  first turn is sent, so the value is available in the first prompt. Note:
  `thread_id` is the *session-scoped* component of Section 4.2's compound
  `Session ID` (`<thread_id>-<turn_id>`); the workpad ignores the per-turn
  suffix because it records sessions, not turns.
- **`dispatched_at`** (RFC3339 string, REQUIRED). Wall-clock UTC timestamp at
  which the orchestrator started the worker Task for this session.
- **`model`** (string, REQUIRED). The Codex model identifier the agent is
  running under (for example `gpt-5.5`). Implementations SHOULD source this
  from a dedicated `codex.model` config field rather than parsing the
  free-form `codex.command` shell string. The value MUST match what the
  agent will self-report if asked.
- **`subject_id`** (string, REQUIRED). The GraphQL node id of the underlying
  Issue or PullRequest content — `I_…` for Issue, `PR_…` for PullRequest. This
  is NOT the Project v2 item id (`PVTI_…`); the latter is `issue.id`. Sourced
  during candidate fetch (Section 11.2) and threaded through to dispatch.
- **`prior_sessions`** (list of structured records, REQUIRED — possibly empty).
  Each record contains at minimum: `thread_id`, `attempt`, `dispatched_at`,
  `completed_at`, `duration_ms`, `model`, `stop_reason`. The most recent prior
  session is at index 0. Implementations MAY include additional fields the
  orchestrator can verify (workspace path, retry counters) but MUST NOT
  include fields whose values cannot be independently verified outside the
  LLM (token counts reported by the LLM provider, internal-only timers); see
  Section 11.8.8.

The orchestrator MUST persist enough state to populate `prior_sessions` across
restarts. This extends the `completed` map shape defined in Section 4.1.8: when
the workpad protocol is enabled, `completed[issue_id]` MUST hold an ordered
list of session records carrying the seven fields above, not just the singleton
`completed_at` timestamp. Implementations SHOULD retain at least the last K
sessions per issue (RECOMMENDED: K = 20, matching the default
`agent.workpad.max_sessions_visible`) and MAY prune older entries. When the
protocol is disabled (the default), the Section 4.1.8 shape stands unchanged
and no per-session bookkeeping is required.

#### 11.8.6 Failure Modes and Recovery

The workpad protocol is **best-effort** from the agent's side. The following
failure modes MUST NOT block dispatch or worker execution:

- **Comments API rate-limited.** GraphQL comment mutations consume the agent's
  shared primary GraphQL point budget AND are subject to GitHub's secondary
  content-creation throttle. Agent SHOULD skip the workpad update for this
  turn. On `Retry-After` (secondary) the agent MUST honour the header; on
  `rateLimit.resetAt` exhaustion (primary) the agent SHOULD wait until reset
  and SHOULD NOT retry workpad writes in tight loops.
- **Workpad comment manually deleted by a human.** Agent MUST detect this on
  its next discovery pass (no comment matches the marker), log it, and create
  a fresh workpad. The `prior_sessions` prompt variable still gives the agent
  its cross-session memory; the on-tracker workpad is regenerated empty.
- **Workpad body malformed** (table parse fails, marker present but structure
  unexpected, unknown version). Agent SHOULD log the issue, archive the
  corrupted body verbatim under a `### Recovered notes (corrupted workpad)`
  heading inside the new workpad, and continue with a fresh table. NEVER
  overwrite without preserving the prior content.
- **`updateIssueComment` returns an authorization error.** Agent SHOULD fall
  back to posting a new comment with the updated content AND a header noting
  the prior workpad's node id, then log the divergence. Operators must
  reconcile manually.
- **Underlying Issue or PullRequest closes mid-session.** GitHub rejects
  `addComment` / `updateIssueComment` against locked or closed Issues with
  HTTP 403 in some configurations. Agent SHOULD log the failure and skip
  workpad writes for the remainder of the session; the orchestrator's
  terminal-OR teardown (Section 11.2.1) is the authoritative termination
  signal and will stop the worker on the next reconcile tick regardless.

The orchestrator's structured logs (Section 13.1) remain the authoritative
record of session history regardless of workpad state.

#### 11.8.7 Single-Orchestrator Constraint

The workpad protocol assumes a single orchestrator dispatches workers against a
given Project. If two orchestrators ran against the same Project simultaneously,
both could direct their respective agents to edit the same workpad and stomp
each other's changes (GitHub's `updateIssueComment` exposes no optimistic
concurrency token on `IssueComment` — neither in GraphQL nor REST — so the
write is last-write-wins).

Implementations MUST document that running multiple orchestrators against a
single Project is unsupported. They MAY add a startup probe that fails if it
detects recent workpad edits attributed to a different orchestrator identity.

#### 11.8.8 Truthfulness Constraints

The workpad is agent-authored, which means a misbehaving or hallucinating model
could write values that disagree with the orchestrator's observed reality (for
example claiming a different stop reason than what the §13.1 log recorded).
Implementations MUST:

- Refuse to expose orchestrator-internal data the agent cannot verify (raw
  token counters from the LLM provider, internal retry timers, host identifiers
  not derivable from public state).
- Document explicitly that workpad rows are agent-self-reported snapshots, not
  audit records.
- Recommend operators cross-reference Section 13.1 structured logs when the
  workpad disagrees with observed behavior.

#### 11.8.9 Configuration

Workflows configure the workpad protocol via the `agent.workpad` config block:

```yaml
agent:
  workpad:
    enabled: true               # default: true (PR4 amendment)
    version: v1                 # MUST equal the marker version; only "v1" supported in this spec
    max_sessions_visible: 20    # rows before folding, default 20
    update_throttle_turns: 3    # min turns between updateIssueComment calls, default 3
```

`agent.workpad.enabled: true` (the default) means the orchestrator emits the
five workpad prompt variables (`thread_id`, `dispatched_at`, `model`,
`subject_id`, `prior_sessions`) whenever the dispatched item is an Issue or
PullRequest, and the workflow template MUST reference at least one of those
variables so the workpad bridge actually surfaces to the agent. The default
flip pushes the protocol from opt-in to opt-out: implementations adopting the
PR4 amendment expose the workpad to every dispatched session unless the
operator explicitly opts out.

`agent.workpad.enabled: false` means the orchestrator MUST NOT emit any of
the five variables, and the workflow template MUST NOT reference them. Solid
strict mode then rejects any template referencing them, surfacing the half-
flipped config to the operator at boot time.

`agent.workpad.version` MUST match the version embedded in the workpad marker
(`<!-- symphony-workpad:v1 -->`). A future v2 protocol MUST bump both the
config value and the marker simultaneously, and implementations SHOULD reject
configs whose `version` does not match a marker the implementation knows how
to read or write.

`agent.workpad.enabled: true` requires the workflow template to include the
agent-facing protocol instructions described in Section 11.8.3 (or equivalent
prose). Implementations SHOULD ship a reference `WORKFLOW.md` that satisfies
this contract out of the box — operators copying the stock template into their
repo SHOULD get a working workpad with no further wiring.

**Migrating to default-on (PR4 amendment).** Deployments upgrading from an
implementation that defaulted `enabled` to `false` (the original §11.8.9
back-compat default) MUST take one of two paths on a pre-existing
`WORKFLOW.md`:

1. **Opt out explicitly.** Set `agent.workpad.enabled: false` in the existing
   `WORKFLOW.md` front matter. The orchestrator preserves pre-PR4 behavior and
   does not emit the five prompt variables.

2. **Adopt the default-on protocol.** Add the `agent.workpad` block (any non-
   `false` `enabled` value, or omit the block to inherit the on-default), add
   `codex.model` (required by SPEC §11.8.5 cross-validation), and include the
   §11.8.3 prompt prose in the body so `validate_workpad_template/1` (SPEC
   §11.8.9) sees at least one workpad Liquid variable. Implementations MUST
   refuse boot when this contract is partially satisfied (workpad implicitly
   enabled via default + missing `codex.model`, or workpad-enabled config +
   workpad-less prompt) so the migration step surfaces loud rather than
   producing protocol-less prompts at runtime.

The migration is intentionally breaking: a stock pre-PR3 `WORKFLOW.md` that
neither opts out nor adopts the protocol fails boot until the operator picks
a path.

#### 11.8.10 Per-Session Summary Comments

The workpad (Section 11.8.1) is a mutable, single-comment surface that the
agent updates across sessions. The per-session summary protocol is a
complementary append-only audit trail: every dispatched session, on its
final turn, posts a NEW comment on the underlying Issue/PullRequest
carrying that session's lifecycle metadata. Future operators reconstruct
the dispatch history by grepping the comment stream — no need to join
against orchestrator logs.

The summary protocol is **independent** of the workpad protocol.
Implementations MAY ship one without the other; the configuration flags
(`agent.workpad.enabled`, `agent.session_summary.enabled`) are orthogonal.
A deployment can opt into summary-only (no workpad), workpad-only (no
summary), both, or neither.

**Marker shape.** Each summary comment is fenced by an opening and a
closing HTML-comment marker that embed the session's `thread_id` verbatim:

```
<!-- symphony-session-summary:<thread_id>:<version> --> ... <!-- /symphony-session-summary:<thread_id>:<version> -->
```

The `thread_id` scoping is intentional: with N prior sessions, an
Issue/PullRequest carries N uniquely-addressable summary comments.
Implementations MUST use the `thread_id` value the orchestrator supplied
to the prompt (Section 11.8.5); fabricated thread_ids violate the §11.8.8
truthfulness contract.

**Header block.** Immediately after the opening marker, the body MUST
include the following RFC822-style key:value pairs, one per line, in
this order:

```
Session: <thread_id>
Attempt: <N>
Dispatched: <RFC3339 UTC>
Completed: <RFC3339 UTC>
Duration: <H>h<M>m<S>s
Model: <model identifier>
Stop reason: <§13.1 atom without the leading colon>
```

The `Model:` value MUST match `codex.model`; the `Stop reason:` value MUST
come from the §13.1 worker-stop reason vocabulary. Implementations
deriving these fields from agent self-report SHOULD cross-check against
orchestrator state and surface a divergence warning.

**Freeform body.** After a blank line, 3–10 sentences summarizing the
session's goal, plan, key actions, code references, and open questions.
Bullet points and links to PRs/commits are encouraged.

**Posting.** Submitted via `addComment(input: {subjectId: $subject_id,
body: $body})` on the agent's final turn, AFTER the workpad sessions
table update (if the workpad is also enabled). `addComment` is on the
default mutation allowlist (Section 18.2.1).

**Append-only.** Implementations MUST NOT edit or delete a prior
session's summary comment. The §11.8.10 audit trail is the permanent
record of every dispatch; corrections live in the NEXT session's summary
comment, not by overwriting an old one. This rule is enforced by spec
convention rather than by allowlist — `updateIssueComment` IS on the
allowlist when the workpad protocol is also enabled (Section 11.8.4), but
agents MUST NOT use it on session-summary comments.

**Configuration.**

```yaml
agent:
  session_summary:
    enabled: true               # default: true (PR4 amendment)
    version: v1                 # MUST equal the marker version; only "v1" supported in this spec
```

`agent.session_summary.enabled: true` (the default) requires:

1. `codex.model` MUST be set, mirroring the workpad's §11.8.5
   cross-validation. The `Model:` header field cannot be empty.
2. The workflow prompt template MUST reference at least one of
   `{{ thread_id }}`, `{{ subject_id }}`, or `{{ dispatched_at }}` so
   the agent's rendered prompt actually carries per-session identity.
   The validation runs independently of the workpad's analogous check.

`agent.session_summary.enabled: false` disables the protocol entirely:
the agent SHOULD NOT post summary comments, and the cross-validations
above do not fire. Operators opting out of the summary while keeping the
workpad enabled MAY rely on the workpad's mutable sessions table as
their session-history surface.

**Version.** `agent.session_summary.version` MUST match the version
embedded in the markers. The current spec defines only `v1`.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Inputs to prompt rendering:

- `workflow.prompt_template`
- normalized `issue` object
- OPTIONAL `attempt` integer (retry/continuation metadata)

### 12.2 Rendering Rules

- Render with strict variable checking.
- Render with strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Preserve nested arrays/maps (labels, blockers) so templates can iterate.

### 12.3 Retry/Continuation Semantics

`attempt` SHOULD be passed to the template because the workflow prompt can provide different
instructions for:

- first run (`attempt` null or absent)
- continuation run after a successful prior session
- retry after error/timeout/stall

Implementations SHOULD additionally expose `last_run_completed_at` (RFC3339 timestamp
or null) so prompts can convey workspace freshness on continuation runs. This is
particularly useful for human-driven re-dispatch flows (for example a Project Status
moved back from "In Review" to "Rework") where the agent needs to scope its read of
new tracker comments and review threads since the previous session ended. Templates
MAY ignore the variable; implementations that do not record per-issue completion
timestamps in their `completed` bookkeeping (Section 4.1.8) MAY pass null.

### 12.4 Failure Semantics

If prompt rendering fails:

- Fail the run attempt immediately.
- Let the orchestrator treat it like any other worker failure and decide retry behavior.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

REQUIRED context fields for issue-related logs:

- `issue_id`
- `issue_identifier`

REQUIRED context for coding-agent session lifecycle logs:

- `session_id`

Message formatting requirements:

- Use stable `key=value` phrasing.
- Include action outcome (`completed`, `failed`, `retrying`, etc.).
- Include concise failure reason when present.
- Avoid logging large raw payloads unless necessary.

Worker-stop reason vocabulary (RECOMMENDED). Reconciliation and worker-exit log
entries that record why a running worker was stopped SHOULD use a stable token from
the following set so operators consuming logs across implementations see one
vocabulary. Tokens fall into two groups: reasons issued by the orchestrator's
reconcile loop (the worker is still alive when the decision is made) and reasons
issued by the orchestrator's worker-exit handler (the worker process is already
gone).

Reconcile-driven tokens (orchestrator stops a live worker):

- `reconciled_missing` — the project item disappeared between polls (no longer
  resolves via `nodes(ids:)`).
- `terminal_or_closed` — the underlying Issue or PR transitioned to `CLOSED` while
  the project Status was still active (terminal-OR rule, Section 11.2.1).
- `terminal_or_merged` — the underlying PR was merged while the project Status was
  still active.
- `terminal_state` — the project Status field reached a value in `terminal_states`.
- `inactive_state` — the project Status field left `active_states` to a non-terminal
  value (for example `In Review`).
- `dependencies_reopened` — `gate_running_on_dependencies` is true and a previously
  resolved blocker transitioned back to open during reconciliation (Section 8.5
  Part C).

Worker-exit tokens (the orchestrator's `:DOWN` handler observes the worker's exit):

- `agent_exit_normal` — the worker `Task` exited with reason `:normal`, indicating
  the agent run completed (successfully or with a graceful early exit). This is the
  default outcome for runs that finish within `agent.max_turns`.
- `agent_exit_crashed` — the worker `Task` exited with a non-`:normal` reason
  (raised exception, link failure, OS signal, etc.). The orchestrator SHOULD log
  this at warning level and schedule the issue for retry per Section 14.
- `stall_restart` — the worker was alive at reconcile time but failed the stall
  liveness check (no agent progress within an implementation-defined threshold).
  The orchestrator terminates the worker and schedules a retry. Stall semantics are
  implementation-specific; implementations SHOULD document the threshold and the
  detection method.

Implementations MAY add deployment-specific tokens, but SHOULD prefix them
(`ext_<name>`) to avoid colliding with future canonical vocabulary additions. The
Agent Workpad Protocol (Section 11.8.2) consumes this vocabulary verbatim: the
agent renders whichever token the orchestrator wrote into the §13.1 log line and
does not invent its own tokens.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe where logs are written (stderr, file, remote sink, etc.).

Requirements:

- Operators MUST be able to see startup/validation/dispatch failures without attaching a debugger.
- Implementations MAY write to one or more sinks.
- If a configured log sink fails, the service SHOULD continue running when possible and emit an
  operator-visible warning through any remaining sink.

### 13.3 Runtime Snapshot / Monitoring Interface (OPTIONAL but RECOMMENDED)

If the implementation exposes a synchronous runtime snapshot (for dashboards or monitoring), it
SHOULD return:

- `running` (list of running session rows)
- each running row SHOULD include `turn_count`
- `retrying` (list of retry queue rows)
- `webhook` (object, OPTIONAL — included when the webhook listener extension is
  enabled). Suggested fields:
  - `enabled` (boolean) — current effective `webhook.enabled` value.
  - `deliveries_received` (integer) — total deliveries that passed signature verification
    in the current process lifetime.
  - `deliveries_dropped` (integer) — count of deliveries that hit the async-queue overflow
    path in §B.3 step 6 (logged as `webhook_queue_full`).
  - `last_event_at` (timestamp or null) — most recent successfully-queued delivery.
  - Implementations MAY expose rolling-window variants (e.g. last hour) instead of
    process-lifetime totals. Drop counts are critical for operators to detect whether the
    polling-loop fallback is silently carrying load that webhooks were supposed to handle.
- `gated` (list of items currently held by the dependency gate, when the
  `dependency_gating_states` config is non-empty; OPTIONAL but RECOMMENDED). Each row carries
  `issue_id`, `issue_identifier`, `kind`, `state`, `reason`, and (for
  `blocked_on_dependencies`) a `blockers` list.
  - The only `reason` defined by Core Conformance is `blocked_on_dependencies`.
  - PR items vetoed by `tracker.pr_block_signals` (Section 11.7) are NOT included in this
    bucket in the Core specification; if an implementation chooses to expose them, it
    SHOULD use a distinct `reason` discriminator (for example `pr_block_signal:
    awaiting_human_review`) and document that as an extension. Otherwise the snapshot
    would conflate two different concepts.
- `codex_totals`
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running` (aggregate runtime seconds as of snapshot time, including active sessions)
- `rate_limits` (latest coding-agent rate limit payload, if available)

RECOMMENDED snapshot error modes:

- `timeout`
- `unavailable`

### 13.4 OPTIONAL Human-Readable Status Surface

A human-readable status surface (terminal output, dashboard, etc.) is OPTIONAL and
implementation-defined.

If present, it SHOULD draw from orchestrator state/metrics only and MUST NOT be REQUIRED for
correctness.

### 13.5 Session Metrics and Token Accounting

Token accounting rules:

- Agent events can include token counts in multiple payload shapes.
- Prefer absolute thread totals when available, such as:
  - `thread/tokenUsage/updated` payloads
  - `total_token_usage` within token-count wrapper events
- Ignore delta-style payloads such as `last_token_usage` for dashboard/API totals.
- Extract input/output/total token counts leniently from common field names within the selected
  payload.
- For absolute totals, track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals unless the event type defines them that
  way.
- Accumulate aggregate totals in orchestrator state.

Runtime accounting:

- Runtime SHOULD be reported as a live aggregate at snapshot/render time.
- Implementations MAY maintain a cumulative counter for ended sessions and add active-session
  elapsed time derived from `running` entries (for example `started_at`) when producing a
  snapshot/status view.
- Add run duration seconds to the cumulative ended-session runtime when a session ends (normal exit
  or cancellation/termination).
- Continuous background ticking of runtime totals is not REQUIRED.

Rate-limit tracking:

- Track the latest rate-limit payload seen in any agent update.
- Any human-readable presentation of rate-limit data is implementation-defined.

### 13.6 Humanized Agent Event Summaries (OPTIONAL)

Humanized summaries of raw agent protocol events are OPTIONAL.

If implemented:

- Treat them as observability-only output.
- Do not make orchestrator logic depend on humanized strings.

### 13.7 OPTIONAL HTTP Server Extension

This section defines an OPTIONAL HTTP interface for observability and operational control.

If implemented:

- The HTTP server is an extension and is not REQUIRED for conformance.
- The implementation MAY serve server-rendered HTML or a client-side application for the dashboard.
- The dashboard/API MUST be observability/control surfaces only and MUST NOT become REQUIRED for
  orchestrator correctness.

Extension config:

- `server.port` (integer, OPTIONAL)
  - Enables the HTTP server extension.
  - `0` requests an ephemeral port for local development and tests.
  - CLI `--port` overrides `server.port` when both are present.

Enablement (extension):

- Start the HTTP server when a CLI `--port` argument is provided.
- Start the HTTP server when `server.port` is present in `WORKFLOW.md` front matter.
- The `server` top-level key is owned by this extension.
- Positive `server.port` values bind that port.
- Implementations SHOULD bind loopback by default (`127.0.0.1` or host equivalent) unless explicitly
  configured otherwise.
- Changes to HTTP listener settings (for example `server.port`) do not need to hot-rebind;
  restart-required behavior is conformant.

#### 13.7.1 Human-Readable Dashboard (`/`)

- Host a human-readable dashboard at `/`.
- The returned document SHOULD depict the current state of the system (for example active sessions,
  retry delays, token consumption, runtime totals, recent events, and health/error indicators).
- It is up to the implementation whether this is server-generated HTML or a client-side app that
  consumes the JSON API below.

#### 13.7.2 JSON REST API (`/api/v1/*`)

Provide a JSON REST API under `/api/v1/*` for current runtime state and operational debugging.

Minimum endpoints:

- `GET /api/v1/state`
  - Returns a summary view of the current system state (running sessions, retry queue/delays,
    aggregate token/runtime totals, latest rate limits, and any additional tracked summary fields).
  - Suggested response shape:

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "counts": {
        "running": 2,
        "retrying": 1,
        "gated": 1
      },
      "running": [
        {
          "issue_id": "PVTI_lADOBcd_eM4AF6gQzgKZ1aw",
          "issue_identifier": "openai/symphony#42",
          "kind": "issue",
          "repository": "openai/symphony",
          "state": "In Progress",
          "session_id": "thread-1-turn-1",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "retrying": [
        {
          "issue_id": "PVTI_lADOBcd_eM4AF6gQzgKZ1bx",
          "issue_identifier": "openai/symphony#43",
          "kind": "pull_request",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "no available orchestrator slots"
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
      "codex_totals": {
        "input_tokens": 5000,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "rate_limits": null
    }
    ```

- `GET /api/v1/<issue_key>`
  - Returns issue-specific runtime/debug details for the identified issue, including any information
    the implementation tracks that is useful for debugging.
  - The path segment `<issue_key>` accepts the **sanitized workspace key** form of the canonical
    identifier (Section 4.2). Using the workspace key avoids URL-encoding the `/` and `#`
    characters that appear in the canonical `<owner>/<repo>#<number>` form. For example, the
    issue with `issue_identifier == "openai/symphony#42"` is reachable at
    `/api/v1/openai_symphony_42`. Implementations MAY additionally accept the URL-encoded
    canonical identifier (`/api/v1/openai%2Fsymphony%2342`) for ergonomics. Implementations
    MUST NOT attempt to reverse-engineer the canonical identifier from the path by
    re-inserting `/` or `#`; only the sanitized workspace key and the URL-encoded canonical
    form are recognized.
  - Suggested response shape:

    ```json
    {
      "issue_identifier": "openai/symphony#42",
      "issue_id": "PVTI_lADOBcd_eM4AF6gQzgKZ1aw",
      "kind": "issue",
      "repository": "openai/symphony",
      "status": "running",
      "workspace": {
        "path": "/tmp/symphony_workspaces/openai_symphony_42"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "codex_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/symphony/codex/openai_symphony_42/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - If the issue is unknown to the current in-memory state, return `404` with an error response (for
    example `{\"error\":{\"code\":\"issue_not_found\",\"message\":\"...\"}}`).

- `POST /api/v1/refresh`
  - Queues an immediate tracker poll + reconciliation cycle (best-effort trigger; implementations
    MAY coalesce repeated requests).
  - Suggested request body: empty body or `{}`.
  - Suggested response (`202 Accepted`) shape:

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

API design notes:

- The JSON shapes above are the RECOMMENDED baseline for interoperability and debugging ergonomics.
- Implementations MAY add fields, but SHOULD avoid breaking existing fields within a version.
- Endpoints SHOULD be read-only except for operational triggers like `/refresh`.
- Unsupported methods on defined routes SHOULD return `405 Method Not Allowed`.
- API errors SHOULD use a JSON envelope such as `{"error":{"code":"...","message":"..."}}`.
- If the dashboard is a client-side app, it SHOULD consume this API rather than duplicating state
  logic.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Workflow/Config Failures`
   - Missing `WORKFLOW.md`
   - Invalid YAML front matter
   - Unsupported tracker kind or missing tracker credentials/project identifier
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure (implementation-defined; can come from hooks)
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested and handled as failure by the implementation's documented policy
   - Subprocess exit
   - Stalled session (no activity)

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads

5. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures:
  - Skip new dispatches.
  - Keep service alive.
  - Continue reconciliation where possible.

- Worker failures:
  - Convert to retries with exponential backoff.

- Tracker candidate-fetch failures:
  - Skip this tick.
  - Try again on next tick.

- Reconciliation state-refresh failures:
  - Keep current workers.
  - Retry on next tick.

- Dashboard/log failures:
  - Do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Current design is intentionally in-memory for scheduler state.
Restart recovery means the service can resume useful operation by polling tracker state and reusing
preserved workspaces. It does not mean retry timers, running sessions, or live worker state survive
process restart.

After restart:

- No retry timers are restored from prior process memory.
- No running sessions are assumed recoverable.
- Service recovers by:
  - startup terminal workspace cleanup
  - fresh polling of active issues
  - re-dispatching eligible work

### 14.4 Operator Intervention Points

Operators can control behavior by:

- Editing `WORKFLOW.md` (prompt and most runtime settings).
- `WORKFLOW.md` changes are detected and re-applied automatically without restart according to
  Section 6.2.
- Changing issue states in the tracker:
  - terminal state -> running session is stopped and workspace cleaned when reconciled
  - non-active state -> running session is stopped without cleanup
- Restarting the service for process recovery or deployment (not as the normal path for applying
  workflow config changes).

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Each implementation defines its own trust boundary.

Operational safety requirements:

- Implementations SHOULD state clearly whether they are intended for trusted environments, more
  restrictive environments, or both.
- Implementations SHOULD state clearly whether they rely on auto-approved actions, operator
  approvals, stricter sandboxing, or some combination of those controls.
- Workspace isolation and path validation are important baseline controls, but they are not a
  substitute for whatever approval and sandbox policy an implementation chooses.

### 15.2 Filesystem Safety Requirements

Mandatory:

- Workspace path MUST remain under configured workspace root.
- Coding-agent cwd MUST be the per-issue workspace path for the current run.
- Workspace directory names MUST use sanitized identifiers.

RECOMMENDED additional hardening for ports:

- Run under a dedicated OS user.
- Restrict workspace root permissions.
- Mount workspace root on a dedicated volume if possible.

### 15.3 Secret Handling

- Support `$VAR` indirection in workflow config.
- Do not log API tokens or secret env values.
- Validate presence of secrets without printing them.

### 15.4 Hook Script Safety

Workspace hooks are arbitrary shell scripts from `WORKFLOW.md`.

Implications:

- Hooks are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook output SHOULD be truncated in logs.
- Hook timeouts are REQUIRED to avoid hanging the orchestrator.

### 15.5 Harness Hardening Guidance

Running Codex agents against repositories, issue trackers, and other inputs that can contain
sensitive data or externally-controlled content can be dangerous. A permissive deployment can lead
to data leaks, destructive mutations, or full machine compromise if the agent is induced to execute
harmful commands or use overly-powerful integrations.

Implementations SHOULD explicitly evaluate their own risk profile and harden the execution harness
where appropriate. This specification intentionally does not mandate a single hardening posture, but
implementations SHOULD NOT assume that tracker data, repository contents, prompt inputs, or tool
arguments are fully trustworthy just because they originate inside a normal workflow.

Possible hardening measures include:

- Tightening Codex approval and sandbox settings described elsewhere in this specification instead
  of running with a maximally permissive configuration.
- Adding external isolation layers such as OS/container/VM sandboxing, network restrictions, or
  separate credentials beyond the built-in Codex policy controls.
- Filtering which GitHub Issues, Pull Requests, repositories, projects, owners, or labels are
  eligible for dispatch so untrusted or out-of-scope tasks do not automatically reach the agent.
- Narrowing the `github_graphql` tool so it can only read or mutate data inside the intended
  project scope and repository, rather than exposing general account-wide GitHub access. For
  example, implementations MAY enforce a denylist of mutation names, restrict variables to a
  single project ID, or disable mutations entirely when the deployment is read-only.
- Reducing the set of client-side tools, credentials, filesystem paths, and network destinations
  available to the agent to the minimum needed for the workflow.

The correct controls are deployment-specific, but implementations SHOULD document them clearly and
treat harness hardening as part of the core safety model rather than an optional afterthought.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    completed: set(),
    codex_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    codex_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break

    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    identifier: issue.identifier,
    issue,
    session_id: null,
    codex_app_server_pid: null,
    last_codex_message: null,
    last_codex_event: null,
    last_codex_timestamp: null,
    codex_input_tokens: 0,
    codex_output_tokens: 0,
    codex_total_tokens: 0,
    last_reported_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  session = app_server.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  max_turns = config.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(workflow_template, issue, attempt, turn_number, max_turns)
    if prompt failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("prompt error")

    turn_result = app_server.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {codex_update, issue.id, msg})
    )

    if turn_result failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue

    if issue.state is not active:
      break

    if turn_number >= max_turns:
      break

    turn_number = turn_number + 1

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)

  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    state.completed.add(issue_id)  # bookkeeping only
    state = schedule_retry(state, issue_id, 1, {
      identifier: running_entry.identifier,
      delay_type: continuation
    })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing:
    return state

  candidates = tracker.fetch_candidate_issues()
  if fetch failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry poll failed"
    })

  issue = find_by_id(candidates, issue_id)
  if issue is null:
    state.claimed.remove(issue_id)
    return state

  if available_slots(state) == 0:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: issue.identifier,
      error: "no available orchestrator slots"
    })

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

A conforming implementation SHOULD include tests that cover the behaviors defined in this
specification.

Validation profiles:

- `Core Conformance`: deterministic tests REQUIRED for all conforming implementations.
- `Extension Conformance`: REQUIRED only for OPTIONAL features that an implementation chooses to
  ship.
- `Real Integration Profile`: environment-dependent smoke/integration checks RECOMMENDED before
  production use.

Unless otherwise noted, Sections 17.1 through 17.7 are `Core Conformance`. Bullets that begin with
`If ... is implemented` are `Extension Conformance`.

### 17.1 Workflow and Config Parsing

- Workflow file path precedence:
  - explicit runtime path is used when provided
  - cwd default is `WORKFLOW.md` when no explicit runtime path is provided
- Workflow file changes are detected and trigger re-read/re-apply without restart
- Invalid workflow reload keeps last known good effective configuration and emits an
  operator-visible error
- Missing `WORKFLOW.md` returns typed error
- Invalid YAML front matter returns typed error
- Front matter non-map returns typed error
- Config defaults apply when OPTIONAL values are missing
- `tracker.kind` validation enforces currently supported kind (`github`)
- `tracker.api_token` works (including `$VAR` indirection)
- `$VAR` resolution works for the tracker API token and path values
- `~` path expansion works
- `codex.command` is preserved as a shell command string
- Per-state concurrency override map normalizes state names and ignores invalid values
- Prompt template renders `issue` and `attempt`
- Prompt rendering fails on unknown variables (strict mode)

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per issue identifier
- Missing workspace directory is created
- Existing workspace directory is reused
- Existing non-directory path at workspace location is handled safely (replace or fail per
  implementation policy)
- OPTIONAL workspace population/synchronization errors are surfaced
- `after_create` hook runs only on new workspace creation
- `before_run` hook runs before each attempt and failure/timeouts abort the current attempt
- `after_run` hook runs after each attempt and failure/timeouts are logged and ignored
- `before_remove` hook runs on cleanup and failures/timeouts are ignored
- Workspace path sanitization and root containment invariants are enforced before agent launch
- Agent launch uses the per-issue workspace path as cwd and rejects out-of-root paths

### 17.3 Issue Tracker Client

- Candidate issue fetch resolves the configured Project v2 (by `project_id` or by
  `owner` + `project_number` + `owner_type`) and paginates `items` until
  `pageInfo.hasNextPage` is false
- Items are filtered client-side by `active_states`, `include_kinds`, and the optional
  `tracker.repo` scope; archived items are excluded; Draft Issues bypass `tracker.repo`
  filtering and are dropped only when `draft_issue` is not in `include_kinds`
- Empty `fetch_issues_by_states([])` returns empty without API call
- Empty `fetch_issue_states_by_ids([])` returns empty without API call
- Probing the configured `tracker.status_field` against a project that does not define it
  raises `tracker_status_field_missing` and blocks dispatch
- A `tracker.project_id` that resolves to a non-`ProjectV2` node raises
  `tracker_project_not_found`
- Resolving `tracker.project_number` against an `owner_type` that does not match the actual
  login type (e.g. `organization` configured for a user login) raises
  `tracker_project_not_found` rather than silently falling back to the other type
- Items whose `content` resolves to null are skipped silently and do not produce orchestration
  errors
- A token that lacks the configured permissions surfaces `tracker_permission_denied`
  (whether the failure manifests as HTTP 401/403 or as an HTTP 200 with a GraphQL
  `FORBIDDEN`/`INSUFFICIENT_SCOPES` error), and dispatch is refused until the operator
  updates the token
- Primary rate-limit signal (HTTP 200 with `rateLimit.remaining == 0`) defers the next
  tracker call until `rateLimit.resetAt` rather than retrying immediately
- Dependency gate (Section 8.2.1) holds items in `dependency_gating_states` whose
  `blocked_by` includes any non-CLOSED entries; gated items appear in the snapshot `gated`
  bucket; cycle members are dispatched with a one-shot warning rather than frozen
- When `gate_running_on_dependencies` is enabled, a previously-resolved blocker reopening
  during reconciliation Part C terminates the running parent worker with reason
  `dependencies_reopened`
- When `cross_repo_blockers` is `false`, blockers in other repositories are ignored by the
  dependency gate
- If the PR Review and CI Awareness extension (Section 11.7) is implemented:
  - normalized Issues for `kind == "pull_request"` populate `pr.review_decision`,
    `pr.mergeable`, `pr.merge_state_status`, `pr.check_state`,
    `pr.unresolved_review_threads`, `pr.latest_opinionated_reviews`, and
    `pr.requested_reviewers`
  - `null` `reviewDecision` is preserved and not coerced to `REVIEW_REQUIRED`
  - `tracker.pr_dispatch_signals` allows dispatch outside `active_states` per Section 11.7.1
  - `tracker.pr_block_signals` vetoes dispatch even inside `active_states`
  - a PR matching both a dispatch signal and a block signal is treated as blocked
    (block-wins evaluation order from Section 11.7.1)
  - a PR that fails the dependency gate (Section 8.2.1) is not dispatched even when a PR
    dispatch signal would otherwise apply
  - `merge_state_blocked` does NOT veto dispatch when the underlying cause is failing CI
    (`mergeStateStatus == BLOCKED` with `review_decision != REVIEW_REQUIRED`)
  - unknown signal entries raise `unsupported_pr_signal` at preflight
- If the Webhook-Driven Dispatch extension (Appendix B) is implemented:
  - HMAC-SHA256 verification rejects requests with a missing or mismatched
    `X-Hub-Signature-256` header (HTTP 401), without falling back to SHA-1
  - duplicate `X-GitHub-Delivery` UUIDs within the dedup window return HTTP 200 with no
    side effect
  - events outside `webhook.events` return HTTP 200 and are not processed (rather than 4xx,
    which would mark the delivery as failed)
  - the receiver returns within 10 seconds even when downstream tracker calls are slow
  - `ping` deliveries return HTTP 200
  - IP allowlisting (when configured) rejects requests from outside the configured CIDRs
  - when the async event queue is full, the receiver still returns HTTP 200 and logs
    `webhook_queue_full` rather than 5xx-ing the delivery
- If the Comment Control Plane extension (Appendix C) is implemented:
  - comments authored by `comment_commands.bot_login` are silently ignored
  - `comment_commands.allowed_authors` bypasses the repository-permission check
  - authors below `comment_commands.allowed_permissions` are rejected and logged
  - `author_association` is NOT used as a permission proxy; the implementation resolves
    effective permission via the REST endpoint
    `GET /repos/{owner}/{repo}/collaborators/{login}/permission` per command (the GraphQL
    `repository.collaborators` connection is NOT used because it omits team-only members)
  - edited comments whose canonical command line is unchanged are no-ops
  - enabling the extension while `webhook.enabled == false` raises
    `comment_commands_requires_webhook` at preflight
  - commands inside Markdown blockquote lines (`> @bot retry`) and inside fenced or
    indented code blocks are not honored
  - `bot_login` configured without the `[bot]` suffix correctly suppresses self-loops for
    PAT-based deployments but emits an operator-visible warning for App-based deployments
    where the actual login carries `[bot]` (or, equivalently, the implementation requires
    the suffix and rejects mismatched configurations at preflight)
  - a `retry` command issued against an issue currently held by the dependency gate
    releases the claim and logs `comment_command_skipped` with the gate reason
  - a token that lacks org-level `Members: Read` raises
    `comment_commands_token_insufficient` at the startup probe (§C.6), and subsequent
    commands are rejected with an operator-visible warning until the token is corrected
- Pagination preserves order across multiple pages within one fetch
- Blockers are normalized from `Issue.trackedIssues.nodes`; the optional label-based
  fallback is exercised only when explicitly enabled
- Labels are normalized to lowercase
- Draft Issues are returned with empty labels, null repository, null URL, null number, and
  identifier of the form `draft:<short>`
- Pull Requests populate `pr.state`, `pr.merged`, `pr.is_draft`, and `branch_name` from
  `headRefName`
- Issue state refresh by ID uses `nodes(ids: [ID!]!)` and returns minimal normalized issues
- Effective state honours the terminal-OR rule (Section 11.2.1): closed Issues and
  closed/merged PRs are reported as terminal even when the Status field is still active
- Items with no Status field value are treated as inactive but non-terminal
- Error mapping for transport failures, non-200 responses, secondary rate-limit responses
  (`Retry-After` honoured), GraphQL errors, malformed payloads, and missing pagination
  cursors

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch sort order is priority then oldest creation time
- `Todo` issue with non-terminal blockers is not eligible
- `Todo` issue with terminal blockers is eligible
- Active-state issue refresh updates running entry state
- Non-active state stops running agent without workspace cleanup
- Terminal state stops running agent and cleans workspace
- Reconciliation with no running issues is a no-op
- Normal worker exit schedules a short continuation retry (attempt 1)
- Abnormal worker exit increments retries with 10s-based exponential backoff
- Retry backoff cap uses configured `agent.max_retry_backoff_ms`
- Retry queue entries include attempt, due time, identifier, and error
- Stall detection kills stalled sessions and schedules retry
- Slot exhaustion requeues retries with explicit error reason
- If a snapshot API is implemented, it returns running rows, retry rows, token totals, and rate
  limits
- If a snapshot API is implemented, timeout/unavailable cases are surfaced

### 17.5 Coding-Agent App-Server Client

- Launch command uses workspace cwd and invokes `bash -lc <codex.command>`
- Session startup follows the targeted Codex app-server protocol.
- Client identity/capability payloads are valid when the targeted Codex app-server protocol requires
  them.
- Policy-related startup payloads use the implementation's documented approval/sandbox settings
- Thread and turn identities exposed by the targeted protocol are extracted and used to emit
  `session_started`
- Request/response read timeout is enforced
- Turn timeout is enforced
- Transport framing required by the targeted protocol is handled correctly
- For stdio-based transports, diagnostic stderr handling is kept separate from the protocol stream
- Command/file-change approvals are handled according to the implementation's documented policy
- Unsupported dynamic tool calls are rejected without stalling the session
- User input requests are handled according to the implementation's documented policy and do not
  stall indefinitely
- Usage and rate-limit telemetry exposed by the targeted protocol is extracted
- Approval, user-input-required, usage, and rate-limit signals are interpreted according to the
  targeted protocol
- If client-side tools are implemented, session startup advertises the supported tool specs
  using the targeted app-server protocol
- If the `github_graphql` client-side tool extension is implemented:
  - the tool is advertised to the session
  - valid `query` / `variables` inputs execute against the configured GitHub endpoint with the
    configured `Authorization: Bearer <token>` header
  - top-level GraphQL `errors` produce `success=false` while preserving the GraphQL body
  - HTTP 429 / `Retry-After` responses produce `success=false` with the `Retry-After` value in
    the error payload
  - invalid arguments, missing auth, and transport failures return structured failure payloads
  - unsupported tool names still fail without stalling the session

### 17.6 Observability

- Validation failures are operator-visible
- Structured logging includes issue/session context fields
- Logging sink failures do not crash orchestration
- Token/rate-limit aggregation remains correct across repeated agent updates
- If a human-readable status surface is implemented, it is driven from orchestrator state and does
  not affect correctness
- If humanized event summaries are implemented, they cover key wrapper/agent event classes without
  changing orchestrator behavior

### 17.7 CLI and Host Lifecycle

- CLI accepts a positional workflow path argument (`path-to-WORKFLOW.md`)
- CLI uses `./WORKFLOW.md` when no workflow path argument is provided
- CLI errors on nonexistent explicit workflow path or missing default `./WORKFLOW.md`
- CLI surfaces startup failure cleanly
- CLI exits with success when application starts and shuts down normally
- CLI exits nonzero when startup fails or the host process exits abnormally

### 17.8 Agent Workpad Protocol (when enabled)

Required when `agent.workpad.enabled: true` (Section 11.8.9):

- When `agent.workpad.enabled: false`, the prompt context MUST NOT contain
  `thread_id`, `dispatched_at`, `model`, `subject_id`, or `prior_sessions`. A
  template that references any of those variables under strict-mode rendering
  (Section 12.2) MUST fail to render.
- When `agent.workpad.enabled: true` AND `issue.kind ∈ {"issue", "pull_request"}`,
  all five prompt variables MUST be present and non-empty (with `prior_sessions`
  possibly empty list on first dispatch).
- When `agent.workpad.enabled: true` AND `issue.kind == "draft_issue"`, the five
  variables MUST be absent and the template MUST tolerate their absence
  (Section 11.8 item-kind scope).
- The `completed` map (Section 4.1.8) MUST retain at least the K most recent
  per-session records per issue when the protocol is enabled, where K matches
  `agent.workpad.max_sessions_visible` (default 20). Older entries MAY be pruned.
- Each stored session record MUST carry: `thread_id`, `attempt`, `dispatched_at`,
  `completed_at`, `duration_ms`, `model`, `stop_reason`. `stop_reason` MUST come
  from the §13.1 worker-stop reason vocabulary.
- Discovery (Section 11.8.1) MUST paginate the comment list until the marker is
  found or `pageInfo.hasNextPage` is false. A test that creates 101 comments and
  places the marker in the first one MUST locate it.
- Discovery MUST tolerate multiple workpad comments by selecting
  `(createdAt DESC, databaseId DESC)`.
- `updateIssueComment` MUST be present in the mutation allowlist (Section 18.2.1)
  when the protocol is enabled, and MUST be rejected when it is not.
- A workflow template that opts into the protocol MUST be exercised in a
  round-trip test: orchestrator dispatch → prompt render → simulated agent comment
  containing the marker → orchestrator re-dispatch → prior_sessions reflects the
  prior run.

Required when `agent.session_summary.enabled: true` (Section 11.8.10):

- When `agent.session_summary.enabled: false`, the boot-time template
  validation MUST NOT fire and a prompt with zero references to
  `thread_id` / `subject_id` / `dispatched_at` MUST load successfully.
- When `agent.session_summary.enabled: true`, the workflow prompt template
  MUST reference at least one of `{{ thread_id }}`, `{{ subject_id }}`,
  `{{ dispatched_at }}`. A template referencing none MUST fail load with
  an error referencing `§11.8.10`.
- When `agent.session_summary.enabled: true` AND `codex.model` is unset,
  Schema validation MUST refuse boot with an error referencing
  `§11.8.10` and `codex.model`.
- The session-summary marker MUST embed the session's `thread_id` verbatim
  (e.g. `<!-- symphony-session-summary:thr-abc:v1 -->`), distinguishing
  it from the singleton workpad marker. A test that posts a comment with
  the canonical marker MUST be able to round-trip it via the
  `github_graphql` `addComment` mutation and locate it in a subsequent
  comment query.
- The session-summary header block MUST surface the seven RFC822 fields
  (`Session`, `Attempt`, `Dispatched`, `Completed`, `Duration`, `Model`,
  `Stop reason`) in render order. Implementations MUST expose this set
  programmatically (e.g. `Workpad.Protocol.session_summary_header_fields/0`)
  so templates and audit tooling never duplicate the contract.
- Session-summary comments are append-only by spec convention: a test
  that attempts to use `updateIssueComment` on a prior summary comment
  body MUST be a flagged violation. The allowlist itself does not
  enforce append-only — `updateIssueComment` is enabled when the workpad
  protocol is also on — so implementations SHOULD document the
  convention in their `WORKFLOW.md` template.

### 17.9 Real Integration Profile (RECOMMENDED)

These checks are RECOMMENDED for production readiness and MAY be skipped in CI when credentials,
network access, or external service permissions are unavailable.

- A real tracker smoke test can be run with valid credentials supplied by `GITHUB_TOKEN` or a
  documented local bootstrap mechanism (for example `~/.github_token`). The smoke test SHOULD
  resolve a real Project v2 by `owner` + `project_number` (or `project_id`) and successfully
  enumerate at least one item of each configured `include_kinds` value present in the project.
- Real integration tests SHOULD use isolated test identifiers/workspaces and clean up tracker
  artifacts (test items, test labels, test comments) when practical.
- Real integration tests SHOULD verify the rate-limit response contract by issuing at least
  one query that records a non-null `rateLimit { remaining }` value and SHOULD verify that a
  simulated `Retry-After` response is honoured rather than retried immediately.
- A skipped real-integration test SHOULD be reported as skipped, not silently treated as passed.
- If a real-integration profile is explicitly enabled in CI or release validation, failures SHOULD
  fail that job.

## 18. Implementation Checklist (Definition of Done)

Use the same validation profiles as Section 17:

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 REQUIRED for Conformance

- Workflow path selection supports explicit runtime path and cwd default
- `WORKFLOW.md` loader with YAML front matter + prompt body split
- Typed config layer with defaults and `$` resolution
- Dynamic `WORKFLOW.md` watch/reload/re-apply for config and prompt
- Polling orchestrator with single-authority mutable state
- GitHub tracker adapter that:
  - speaks GitHub GraphQL exclusively against `tracker.endpoint` (default
    `https://api.github.com/graphql`),
  - resolves a Project v2 by `project_id` or `owner` + `project_number` + `owner_type`,
  - probes the configured `tracker.status_field` (Section 11.2.4) and refuses dispatch with
    `tracker_status_field_missing` when the field is absent or not a single-select,
  - paginates `items` (page size <= 100) until `pageInfo.hasNextPage` is false,
  - applies `active_states`, `include_kinds`, and the optional `tracker.repo` filters
    client-side (no server-side filter exists for Projects v2 items),
  - applies the terminal-OR rule (Section 11.2.1) before returning normalized issues, and
  - honors primary and secondary GitHub rate-limit signals per Section 11.2.
- Issue tracker client with candidate fetch + state refresh + terminal fetch (the
  `github_graphql` client-side tool extension is OPTIONAL — see 18.2)
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Hook timeout config (`hooks.timeout_ms`, default `60000`)
- Coding-agent app-server subprocess client with JSON line protocol
- Codex launch command config (`codex.command`, default `codex app-server`)
- Strict prompt rendering with `issue` and `attempt` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap (`agent.max_retry_backoff_ms`, default 5m)
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues (startup sweep + active transition)
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`
- Operator-visible observability (structured logs; OPTIONAL snapshot/status surface)

### 18.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- HTTP server extension honors CLI `--port` over `server.port`, uses a safe default bind host, and
  exposes the baseline endpoints/error semantics in Section 13.7 if shipped.
- `github_graphql` client-side tool extension exposes raw GitHub GraphQL access through the
  app-server session using the configured Symphony tracker auth.
- PR Review and CI Awareness extension (Section 11.7): exposes
  `pr.review_decision`/`pr.check_state`/`pr.unresolved_review_threads`/etc. on the
  normalized Issue and adds `tracker.pr_dispatch_signals`/`tracker.pr_block_signals` to the
  candidate-eligibility predicates.
- Webhook-Driven Dispatch extension (Appendix B): HTTP listener with HMAC-SHA256 signature
  verification, `X-GitHub-Delivery` deduplication, IP allowlisting, and immediate
  refresh-tick triggers. Polling remains the safety net.
- Comment Control Plane extension (Appendix C): `@<bot_login> retry|pause|resume|stop|status`
  commands gated by repository permission. Depends on the webhook listener.
- Sub-issue dependency gating is part of Core Conformance (Section 18.1) when shipped via
  the `tracker.dependency_gating_states` config (default `["Todo"]` matches the original
  Section 8.2 behavior); the extended config knobs (`gate_running_on_dependencies`,
  `cross_repo_blockers`) are RECOMMENDED extensions.
- TODO: Persist retry queue and session metadata across process restarts.
- TODO: Make observability settings configurable in workflow front matter without prescribing UI
  implementation details.
- TODO: Add first-class tracker write APIs (Project Status updates, comments, state
  transitions) in the orchestrator instead of only via agent tools.
- TODO: Add pluggable issue tracker adapters beyond GitHub.

### 18.2.1 `github_graphql` Tool Safety (RECOMMENDED)

Implementations of the `github_graphql` extension SHOULD constrain mutations to an
operator-visible allowlist enforced at tool invocation time. Queries (read-only
operations) SHOULD be unrestricted because the configured `tracker.api_token` already
bounds their visibility.

The default RECOMMENDED mutation allowlist covers the tracker-write operations a
coding agent legitimately needs while excluding destructive or
broadly-permissioned operations:

- `addComment`
- `updateProjectV2ItemFieldValue`
- `addLabelsToLabelable`, `removeLabelsFromLabelable`
- `requestReviews`, `addPullRequestReview`, `resolveReviewThread`

Allowlist enforcement SHOULD be operator-configurable so deployments with broader
trust can opt into additional mutations (for example `closeIssue`, `mergePullRequest`,
`createRef`) without forking the implementation. Deployments SHOULD log every
allowlisted-mutation invocation through orchestrator observability with the mutation
name, the resolved `issue_id`, and the agent `session_id`.

Mutation-name extraction is implementation-defined but SHOULD recognize both
single-mutation and named-mutation syntaxes (`mutation { addComment(...) { ... } }`
and `mutation Op { addComment(...) { ... } }`). Implementations that cannot extract
the mutation name (for example a malformed GraphQL document) MUST reject the call
with a `mutation_unparseable` error rather than passing it through.

### 18.3 Operational Validation Before Production (RECOMMENDED)

- Run the `Real Integration Profile` from Section 17.9 with valid credentials and network access.
- Verify hook execution and workflow path resolution on the target host OS/shell environment.
- If the OPTIONAL HTTP server is shipped, verify the configured port behavior and loopback/default
  bind expectations on the target environment.

## Appendix A. SSH Worker Extension (OPTIONAL)

This appendix describes a common extension profile in which Symphony keeps one central
orchestrator but executes worker runs on one or more remote hosts over SSH.

Extension config:

- `worker.ssh_hosts` (list of SSH host strings, OPTIONAL)
  - When omitted, work runs locally.
- `worker.max_concurrent_agents_per_host` (positive integer, OPTIONAL)
  - Shared per-host cap applied across configured SSH hosts.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, and
  reconciliation.
- `worker.ssh_hosts` provides the candidate SSH destinations for remote execution.
- Each worker run is assigned to one host at a time, and that host becomes part of the run's
  effective execution identity along with the issue workspace.
- `workspace.root` is interpreted on the remote host, not on the orchestrator host.
- The coding-agent app-server is launched over SSH stdio instead of as a local subprocess, so the
  orchestrator still owns the session lifecycle even though commands execute remotely.
- Continuation turns inside one worker lifetime SHOULD stay on the same host and workspace.
- A remote host SHOULD satisfy the same basic contract as a local worker environment: reachable
  shell, writable workspace root, coding-agent executable, and any required auth or repository
  prerequisites.

### A.2 Scheduling Notes

- SSH hosts MAY be treated as a pool for dispatch.
- Implementations MAY prefer the previously used host on retries when that host is still
  available.
- `worker.max_concurrent_agents_per_host` is an OPTIONAL shared per-host cap across configured SSH
  hosts.
- When all SSH hosts are at capacity, dispatch SHOULD wait rather than silently falling back to a
  different execution mode.
- Implementations MAY fail over to another host when the original host is unavailable before work
  has meaningfully started.
- Once a run has already produced side effects, a transparent rerun on another host SHOULD be
  treated as a new attempt, not as invisible failover.

### A.3 Problems to Consider

- Remote environment drift:
  - Each host needs the expected shell environment, coding-agent executable, auth, and repository
    prerequisites.
- Workspace locality:
  - Workspaces are usually host-local, so moving an issue to a different host is typically a cold
    restart unless shared storage exists.
- Path and command safety:
  - Remote path resolution, shell quoting, and workspace-boundary checks matter more once execution
    crosses a machine boundary.
- Startup and failover semantics:
  - Implementations SHOULD distinguish host-connectivity/startup failures from in-workspace agent
    failures so the same issue is not accidentally re-executed on multiple hosts.
- Host health and saturation:
  - A dead or overloaded host SHOULD reduce available capacity, not cause duplicate execution or an
    accidental fallback to local work.
- Cleanup and observability:
  - Operators need to know which host owns a run, where its workspace lives, and whether cleanup
    happened on the right machine.

## Appendix B. Webhook-Driven Dispatch Extension (OPTIONAL)

This appendix describes an OPTIONAL extension that supplements the polling loop (Section 8.1)
with a webhook listener. When configured, GitHub events are translated into immediate dispatch
or reconciliation ticks, reducing dispatch latency from `polling.interval_ms` to milliseconds
and reducing GraphQL spend.

The polling loop is **not** removed by this extension — it remains the safety net for missed
events, processing failures, and out-of-order delivery. Webhooks are additive.

### B.1 Configuration

Top-level workflow front-matter key `webhook` (object):

- `webhook.enabled` (boolean)
  - Default: `false`.
- `webhook.bind` (string, OPTIONAL)
  - Listen address. Default: `127.0.0.1`. Bind to `0.0.0.0` only when fronted by a reverse
    proxy or running inside an isolation boundary that allows public ingress.
  - **TLS**: Symphony does not implement TLS itself. When exposing the receiver to the
    public Internet, operators MUST terminate TLS at the reverse proxy or load balancer.
    The webhook secret protects the **integrity** of the payload (HMAC), but not its
    **confidentiality**; payload contents (project state changes, comment bodies, PR
    titles) travel in cleartext to a non-TLS receiver and should be considered exposed.
- `webhook.port` (integer, OPTIONAL)
  - TCP port. Default: `8787`. May be the same process listener as the OPTIONAL HTTP server
    extension (Section 13.7); when both are configured to the same port, the webhook
    receiver MUST be mounted at a distinct path (default `/webhooks/github`) and routed
    explicitly.
- `webhook.path` (string, OPTIONAL)
  - HTTP path receiving webhook deliveries. Default: `/webhooks/github`.
- `webhook.secret` (string)
  - REQUIRED when `webhook.enabled == true`. MAY be a literal value or `$VAR_NAME`. The
    same secret MUST be configured on the GitHub-side webhook. If `$VAR_NAME` resolves to
    an empty string, dispatch preflight (Section 6.3) fails with `webhook_secret_missing`.
- `webhook.events` (list of strings, OPTIONAL)
  - Whitelist of GitHub event names the receiver acts on. Defaults are listed in Section
    B.5. Events received but not in this list are signature-verified and 200-OK'd (so the
    GitHub-side delivery is recorded as success), then discarded.
- `webhook.allowlist_cidrs` (list of strings, OPTIONAL)
  - When non-empty, requests whose source IP does not fall within any listed CIDR are
    rejected with HTTP 403. Implementations SHOULD populate this from the `hooks` array
    returned by `GET https://api.github.com/meta` and SHOULD periodically refresh it.
- `webhook.delivery_dedup_ttl_ms` (integer, OPTIONAL)
  - Default: `86400000` (24 hours). Cache window for `X-GitHub-Delivery` IDs (Section B.3).

Cheat-sheet entries (Section 6.4):

- `webhook.enabled`: boolean, default `false`
- `webhook.bind`: string, default `127.0.0.1`
- `webhook.port`: integer, default `8787`
- `webhook.path`: string, default `/webhooks/github`
- `webhook.secret`: string or `$VAR`, REQUIRED when enabled
- `webhook.events`: list of strings, default per Section B.5
- `webhook.allowlist_cidrs`: list of CIDR strings, default empty
- `webhook.delivery_dedup_ttl_ms`: integer, default `86400000`

### B.2 Provisioning

This specification does NOT require Symphony to create the GitHub-side webhook automatically.
Operators provision the webhook in one of three ways:

- **Org webhook** (RECOMMENDED for `projects_v2_item` coverage):
  `POST /orgs/{org}/hooks` with body:

  ```json
  {
    "name": "web",
    "active": true,
    "events": ["projects_v2_item", "issues", "pull_request",
               "pull_request_review", "pull_request_review_thread",
               "pull_request_review_comment", "issue_comment",
               "check_suite", "check_run"],
    "config": {
      "url": "https://symphony.example.com/webhooks/github",
      "content_type": "json",
      "secret": "<value matching webhook.secret>",
      "insecure_ssl": "0"
    }
  }
  ```

  Required token scope: `admin:org_hook`.

- **Repo webhook**: `POST /repos/{owner}/{repo}/hooks` with the same body. Required token
  scope: `admin:repo_hook`. NOTE: `projects_v2_item` is **not** delivered at the repo level;
  this option is sufficient for Issue/PR-only deployments but cannot fully replace the
  polling loop for project-Status changes.

- **GitHub App**: register a single webhook URL in the App's settings; the App receives
  events from every installation it is installed on. RECOMMENDED for multi-org deployments.

### B.3 Receiver Contract

For every incoming HTTP request on `webhook.path`, the receiver MUST:

1. **IP allowlist check** (when configured): reject with HTTP 403 if the source IP is not in
   `webhook.allowlist_cidrs`.

2. **Read the raw body** as bytes. Signature verification is over the raw body, not a
   re-serialized JSON form.

3. **Signature verification**:
   - Header: `X-Hub-Signature-256`, value format `sha256=<hex>`.
   - Compute HMAC-SHA256 over the raw body using `webhook.secret` (UTF-8 encoded).
   - Compare hex-encoded digests using a constant-time comparator (e.g. `hmac.compare_digest`,
     `crypto.timingSafeEqual`, `Plug.Crypto.secure_compare`). Reject mismatches with HTTP 401.
   - If `X-Hub-Signature-256` is missing entirely, reject with HTTP 401.
   - The legacy `X-Hub-Signature` (HMAC-SHA1) header MUST be ignored. Implementations MUST
     NOT fall back to SHA-1 verification.

4. **Delivery deduplication**:
   - Read `X-GitHub-Delivery` (UUID, unique per delivery attempt).
   - If this UUID has been observed within `webhook.delivery_dedup_ttl_ms`, return HTTP 200
     with an empty body and stop processing.
   - Otherwise, record the UUID with the current timestamp, then continue.
   - GitHub does **not** auto-retry failed deliveries (Section B.6), so duplicate deliveries
     occur only when an operator manually redelivers via the GitHub UI or the deliveries API.
     Reprocessing such a redelivery is acceptable; suppressing it via the dedup window
     prevents accidental double-application within a few seconds.

5. **Event routing**:
   - Read `X-GitHub-Event` (the canonical event name).
   - If the event name is not in `webhook.events`, return HTTP 200 with an empty body and
     stop processing. Do NOT 4xx; that would mark the delivery as failed in GitHub's UI.
   - Otherwise, parse the JSON body and dispatch per Section B.5.

6. **Respond within 10 seconds**. GitHub treats deliveries that exceed this timeout as
   failures. The receiver MUST NOT block on tracker GraphQL calls or worker dispatch; it
   MUST queue the work asynchronously and return HTTP 200 immediately (a 2xx within 10s,
   typically <100 ms). Long-running orchestration happens on the next tick triggered by
   the webhook.
   - **Queue overflow**: when the receiver's internal in-memory event queue is bounded and
     full, the receiver MUST still respond HTTP 200 (a 5xx response would mark the
     delivery as failed in GitHub's UI without prompting auto-retry — a worse outcome than
     dropping the event). The receiver SHOULD log `webhook_queue_full` with the dropped
     `X-GitHub-Delivery` UUID. The polling loop (Section 8.1) is the recovery path; the
     next tick will reconcile any state changes the dropped event would have surfaced.

7. **Ping handling**: when `X-GitHub-Event == "ping"`, return HTTP 200 with body
   `{"pong": true}`. Implementations MAY log the ping payload's `zen` field for diagnostic
   value.

### B.4 Bridge to the Orchestrator

A successful, deduplicated, in-allowlist event triggers an **immediate tick**:

- The receiver enqueues a request equivalent to `POST /api/v1/refresh` (Section 13.7.2)
  carrying optional hints about which issue IDs were touched.
- The orchestrator's tick loop coalesces multiple webhook-triggered refreshes within a short
  window (RECOMMENDED: 1 second) to avoid storms during bulk project edits.
- Hinted IDs are passed to `fetch_issue_states_by_ids` so reconciliation does not need to
  enumerate the entire project to reflect a single-item change.

For events that carry `changes.field_value.from`/`to` (specifically `projects_v2_item.edited`
on a single-select field — the canonical "Status changed" signal), implementations MAY skip
the GraphQL refresh entirely and apply the new state in-memory. This is an OPTIONAL
optimization; the conservative path is to always re-fetch.

### B.5 Default Event Whitelist and Dispatch Effect

| Event | Action(s) | Effect |
|---|---|---|
| `projects_v2_item` | `created`, `edited`, `archived`, `restored`, `deleted`, `reordered`, `converted` | Refresh the affected item (or full candidate sweep on `archived`/`deleted`). **Org-level webhooks only**; not delivered to repo-level webhooks (see §B.2). |
| `issues` | `opened`, `closed`, `reopened`, `labeled`, `unlabeled`, `edited`, `transferred` | Refresh the project items that wrap this issue, if any. |
| `pull_request` | `opened`, `closed`, `reopened`, `synchronize`, `ready_for_review`, `converted_to_draft`, `edited`, `labeled`, `unlabeled`, `review_requested`, `review_request_removed` | Refresh the project items that wrap this PR. `synchronize` indicates new commits and SHOULD trigger a CI/check-state re-evaluation per Section 11.7. |
| `pull_request_review` | `submitted`, `edited`, `dismissed` | Refresh the wrapping project item; if `pr_dispatch_signals` includes `changes_requested` and the new review is `CHANGES_REQUESTED`, the next tick may dispatch immediately. |
| `pull_request_review_thread` | `resolved`, `unresolved` | Refresh `pr.unresolved_review_threads` for the wrapping item. Requires GitHub.com or GitHub Enterprise Server 3.10+; older GHES versions silently do not deliver these and `pr.unresolved_review_threads` updates only on the next poll. |
| `pull_request_review_comment` | `created`, `edited`, `deleted` | Inline diff comment events. Used by the comment control plane (Appendix C) when configured. |
| `issue_comment` | `created`, `edited`, `deleted` | PR-conversation and issue comment events. Note: PR-level conversation comments arrive as `issue_comment`, NOT `pull_request_review_comment`. The comment control plane subscribes to both. |
| `check_suite` | `completed` | Refresh PR `check_state`. |
| `check_run` | `completed`, `rerequested` | Refresh PR `check_state`. |

Other events SHOULD be ignored even if delivered; implementations MAY add events to
`webhook.events` for workflow-specific extensions but MUST treat unknown payload shapes as
non-fatal (parse, fail, 200-OK, log).

### B.6 Out-of-Order Delivery and Reliability

- GitHub does NOT guarantee event ordering. Two near-simultaneous edits MAY arrive out of
  order. Reconciliation handles this naturally because each event triggers a fresh
  `fetch_issue_states_by_ids` (or a full sweep) — the latest state always wins.
- GitHub does NOT auto-retry failed deliveries. The polling loop (Section 8.1) is the
  authoritative recovery path. Operators MAY redeliver failed events from the GitHub UI or
  via `POST /orgs/{org}/hooks/{hook_id}/deliveries/{delivery_id}/attempts`; implementations
  SHOULD treat redelivered events identically to first-time deliveries (the dedup window
  in Section B.3 prevents tight-loop double-processing).
- The maximum payload size is approximately 25 MB (per GitHub documentation, mid-2026).
  Implementations SHOULD reject larger requests with HTTP 413 before parsing.

### B.7 Validation and Errors

Dispatch preflight additions (Section 6.3) when `webhook.enabled == true`:

- `webhook_secret_missing`: `webhook.secret` is unset or resolves to empty.
- `webhook_port_in_use`: bind to `webhook.bind:webhook.port` failed.

Receiver-side error categories (logged per request; not orchestrator state):

- `webhook_signature_invalid`
- `webhook_signature_missing`
- `webhook_ip_disallowed`
- `webhook_payload_too_large`
- `webhook_payload_unparseable`
- `webhook_event_ignored` (DEBUG-level; expected when an event arrives outside `webhook.events`)
- `webhook_queue_full` (the receiver's async queue could not accept the event; the delivery
  is acknowledged with HTTP 200 and the polling loop is relied on for recovery)

### B.8 Conformance Notes

This appendix is `Extension Conformance` (Section 17). Implementations that do not ship the
webhook listener MUST still validate that `webhook.enabled` defaults to `false`, and MUST
ignore any webhook-related front-matter keys when the listener is absent. Implementations that
do ship it MUST cover the receiver contract (Section B.3) in tests, including signature
mismatch, missing signature, IP rejection, dedup, ping handling, and the 10-second response
budget.

## Appendix C. Comment Control Plane Extension (OPTIONAL)

This appendix describes an OPTIONAL extension that lets repository contributors control a
running Symphony deployment by leaving slash-command comments on Issues and Pull Requests.
The extension depends on the webhook listener (Appendix B); polling-only deployments cannot
implement low-latency comment commands.

### C.1 Configuration

Top-level workflow front-matter key `comment_commands` (object):

- `comment_commands.enabled` (boolean)
  - Default: `false`.
- `comment_commands.bot_login` (string)
  - REQUIRED when enabled. The GitHub login that owns `tracker.api_token` (e.g. the App's
    bot user or the PAT owner). Used for two reasons:
    1. Symphony's own comments are detected and ignored, preventing self-trigger loops.
    2. The mention prefix `@<bot_login>` is the canonical command marker (e.g. `@symphony`).
  - For GitHub Apps, the login appearing in `comment.user.login` includes the literal
    `[bot]` suffix (for example `symphony[bot]`). The configured `bot_login` MUST match
    that exact form including the suffix; configuring just `symphony` would break
    self-loop suppression because the strings would not be equal. The mention prefix
    `@<bot_login>` is matched the same way: GitHub renders mentions of App bots as
    `@symphony[bot]`, and the spec parses the prefix as configured. Implementations MAY
    additionally accept the bare login (without `[bot]`) as a convenience alias for the
    mention prefix when this is documented in the deployment runbook.
- `comment_commands.allowed_permissions` (list of strings)
  - Default: `["ADMIN", "MAINTAIN", "WRITE"]`. Subset of GitHub's repository permission
    levels: `READ`, `TRIAGE`, `WRITE`, `MAINTAIN`, `ADMIN`. A command is honored only if its
    author's effective repository permission is one of the listed values.
  - The implementation MUST resolve the author's permission via the REST
    `GET /repos/{owner}/{repo}/collaborators/{login}/permission` endpoint at command time
    (see §C.4 step 4 for rationale); permissions are NOT cached across deliveries.
- `comment_commands.allowed_authors` (list of strings, OPTIONAL)
  - When non-empty, an explicit allowlist of GitHub logins. Authors in this list bypass the
    `allowed_permissions` check. Useful for narrowly authorizing specific operators on
    public repos.
- `comment_commands.commands` (list of strings, OPTIONAL)
  - Subset of the canonical command names listed in Section C.3. Default: all canonical
    commands. Use this to disable a specific command (e.g. drop `stop` for read-only
    deployments).
- `comment_commands.reaction_acknowledge` (string, OPTIONAL)
  - When set to a GitHub reaction content (e.g. `eyes`, `+1`, `rocket`), the implementation
    MAY post that reaction on the triggering comment as a synchronous acknowledgement. When
    unset or null, no reaction is posted. Posting reactions consumes a GraphQL mutation
    budget; deployments with very large comment volume MAY want to leave this null.

Cheat-sheet entries:

- `comment_commands.enabled`: boolean, default `false`
- `comment_commands.bot_login`: string, REQUIRED when enabled
- `comment_commands.allowed_permissions`: list of strings, default `["ADMIN","MAINTAIN","WRITE"]`
- `comment_commands.allowed_authors`: list of strings, default empty
- `comment_commands.commands`: list of strings, default all canonical commands
- `comment_commands.reaction_acknowledge`: string or null, default null

### C.2 Trigger Events

Comment commands are processed on the following webhook events (subscribed via Appendix B):

- `issue_comment.created`, `issue_comment.edited`
- `pull_request_review_comment.created`, `pull_request_review_comment.edited`

PR-level conversation comments fire `issue_comment`, NOT `pull_request_review_comment`. The
latter is fired only for inline diff comments. Both subscriptions are required for full PR
coverage.

`deleted` actions are intentionally ignored: a command's effect persists past comment
deletion, and processing deletions would let an actor cancel their own command after the
fact in a way that diverges from the visible comment history.

### C.3 Canonical Commands

The mention prefix is `@<comment_commands.bot_login>`. Commands are case-insensitive,
single-line, and parsed only when the prefix appears at the start of a comment body line
(ignoring leading whitespace). Multiple commands in one comment are NOT supported in this
spec version; the first matching command on the first matching line wins. Subsequent
commands in the same comment SHOULD be logged but ignored.

The following lines MUST be ignored when scanning for commands. They are common Markdown
constructs that allow third parties to forge command-like text inside an unrelated
comment, and accepting them would be a privilege-escalation vector on shared repos:

- Lines that begin (after leading whitespace) with `>` — Markdown blockquote, often a
  reply that quotes another comment verbatim.
- Lines inside a fenced code block, where a fence is a line whose first non-whitespace
  token is `\`\`\`` or `~~~` and the matching closing fence is the next line with the same
  fence character. Open-but-unclosed fences MUST also suppress every following line. (A
  user who needs to lead a comment with a code block and then issue a command must close
  the block with a matching fence before the command line.)
- Lines inside a four-space-indented code block (legacy Markdown indented-code syntax).

Implementations MAY parse the comment body as Markdown to apply these exclusions, or apply
the line-level heuristic above; both are acceptable.

| Command | Effect | Notes |
|---|---|---|
| `@bot retry` | Schedule an immediate retry of the issue/PR identified by the comment's parent. | If the issue is not currently claimed, falls back to a normal dispatch attempt subject to all eligibility rules. Issues that fail the dependency gate (Section 8.2.1) are not retried — the claim is released and a `comment_command_skipped` log entry SHOULD record the gate reason so the operator can see why the command did not produce a run. |
| `@bot pause` | Add the issue to an in-memory pause set; the orchestrator skips dispatch for paused issues. | Persists for the lifetime of the orchestrator process only — restart clears the set. |
| `@bot resume` | Remove the issue from the pause set. | No-op if not paused. |
| `@bot stop` | Terminate the running worker for the issue (if any) without workspace cleanup; leave the issue in `claimed` until the next reconciliation re-evaluates. | If the issue is not running, equivalent to `pause`. |
| `@bot status` | Reply with a short status comment summarizing the orchestrator's current view of this issue (running session id, attempt count, last event, paused state). | Always allowed — informational only. |

Implementations MAY add deployment-specific commands as long as they:

1. Use a distinct prefix (e.g. `@bot ext.<name>`) to avoid colliding with future canonical
   commands.
2. Document them clearly in the deployment's runbook.
3. Apply the same author-authorization rules (Section C.4).

### C.4 Author Authorization

For every command:

1. Resolve `comment.user.login` from the webhook payload.
2. If `comment.user.login == comment_commands.bot_login`, ignore the comment silently
   (Symphony's own status replies must not retrigger commands).
3. If `comment_commands.allowed_authors` is non-empty AND `comment.user.login` is in that
   list, allow the command and skip the permission check.
4. Otherwise, query the author's **effective** repository permission for the comment's
   repository. Use the REST endpoint, not GraphQL:

   ```http
   GET /repos/{owner}/{repo}/collaborators/{login}/permission
   Authorization: Bearer <tracker.api_token>
   Accept: application/vnd.github+json
   ```

   The response includes `permission` (one of `read`, `triage`, `write`, `maintain`,
   `admin`, or `none`) and `role_name`. This endpoint returns the **effective** permission
   merging direct collaborator grants and team-membership grants — the GraphQL
   `repository.collaborators(query:)` connection silently omits org members whose access
   comes only via team membership, which is the common case in real organizations.

   The resolved `permission` (compared case-insensitively to
   `comment_commands.allowed_permissions`) MUST be in the allowlist for the command to be
   honored. A `permission` of `none` MUST be rejected.

   Implementations on GitHub Enterprise Server MAY substitute the equivalent
   `/api/v3/repos/...` path; the response shape is identical.

   This endpoint requires org-level `Members: Read` (fine-grained PAT) or `members: read`
   (GitHub App) — see Section 11.6. A token scoped only to repository permissions returns
   HTTP 403 here even though it can read everything else the spec requires; preflight
   raises `comment_commands_token_insufficient` (Section C.6) so the misconfiguration is
   surfaced at startup rather than at first-command time.

5. If authorization fails, the implementation:
   - MUST NOT execute the command,
   - SHOULD post a one-line reply comment with the reason
     (`unauthorized: requires WRITE or higher`), unless
     `comment_commands.reaction_acknowledge` is null AND the deployment opts out of all
     reply traffic via deployment policy,
   - MUST log the rejection with author login, command name, and resolved permission.

The rejection comment posting itself must NOT honor commands embedded in author profile
text or anywhere else; the implementation parses commands only from the structured comment
bodies of the events listed in Section C.2.

### C.5 Idempotency and Comment Edits

`issue_comment.edited` deliveries MAY contain a previously-seen command (from the original
`created` event) plus new text. The implementation:

- SHOULD compare the previous body (available in `changes.body.from` for `edited` events)
  with the current body. If the canonical command on the matching line is unchanged, the
  edit is treated as a no-op.
- SHOULD process the command if and only if the canonical command on the matching line is
  newly introduced or changed by the edit.
- MUST honor the dedup window in Appendix B.3 to prevent rapid edit-storms from amplifying
  command frequency.

### C.6 Validation and Errors

Dispatch preflight additions (Section 6.3) when `comment_commands.enabled == true`:

- `comment_commands_bot_login_missing`: `comment_commands.bot_login` is unset.
- `comment_commands_requires_webhook`: `webhook.enabled` is `false`. The comment control
  plane has no polling-mode equivalent in this specification version.
- `comment_commands_token_insufficient`: a one-shot probe of
  `GET /repos/{owner}/{repo}/collaborators/{login}/permission` (using
  `comment_commands.bot_login` as the test login against any repository in the polled
  project) returned HTTP 401 or HTTP 403. The token lacks the org-level `Members: Read`
  permission required to resolve comment-author permission (§11.6). The implementation
  MUST run this probe at startup and on workflow reloads that change `tracker.api_token`
  or `comment_commands.enabled`. Dispatch is not blocked, but commands are refused with a
  visible operator warning until the token is corrected.

Receiver-side log categories:

- `comment_command_unauthorized` (with author login, resolved permission, rejected command)
- `comment_command_unknown` (the parsed command is not in `comment_commands.commands`)
- `comment_command_self_loop_skipped` (author is `comment_commands.bot_login`)
- `comment_command_executed` (with author login, command, target issue identifier)
- `comment_command_skipped` (the command was authorized and parsed but produced no run —
  for example a `retry` whose target is currently held by the dependency gate; payload
  includes the skip reason)

### C.7 Security Notes

- Command authorization checks MUST NOT trust webhook payload fields like
  `comment.author_association` as a permission proxy. `author_association` reflects an
  author's relationship to the repository at comment time, but its enum (`OWNER`, `MEMBER`,
  `COLLABORATOR`, `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, `FIRST_TIMER`, `MANNEQUIN`,
  `NONE`) is informational and does not map cleanly onto write capability. Always resolve
  via the REST endpoint described in Section C.4 step 4.
- Comment bodies are arbitrary user input. Any content the agent receives via the comment
  control plane (for example via a future `@bot run <freeform>` extension) MUST be treated
  with the same caution as tracker data per Section 15.5.
- The pause set is in-memory only and clears on restart. Implementations that want
  persistent pausing SHOULD use a label (e.g. `symphony:paused`) plus an
  `include_kinds`/`active_states` filter, or extend `tracker.repo` semantics — not in-memory
  state.

### C.8 Conformance Notes

This appendix is `Extension Conformance`. Implementations that do not ship the comment
control plane MUST still validate that `comment_commands.enabled` defaults to `false`. When
shipped, the test matrix MUST cover: bot self-loop suppression (C.4 step 2),
`allowed_authors` bypass, permission-denied flow, command-not-in-`commands`-list rejection,
edit no-op (C.5), and webhook prerequisite validation (C.6).


