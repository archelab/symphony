# Initial Prompt

This file records the publishable startup payload for the Symphony-spawned Codex agent on GitHub issue `archelab/symphony#210`.

It intentionally does not reproduce hidden platform/system/developer instructions, Codex runtime internals, or repo/skill instructions loaded outside the Symphony prompt. In this run, repo-level `AGENTS.md` and the `agent-browser` skill were also present in the Codex session, but they are not part of the rendered Symphony first-turn prompt below.

## Runtime Envelope

- `cwd`: `/Users/pedrocunha/code/symphony-workspaces/archelab_symphony_210`
- Thread `approvalPolicy`: `never`
- Thread `sandbox`: `workspace-write`
- Turn `sandboxPolicy`: `{"type":"workspaceWrite","networkAccess":true}`
- Network access for the turn sandbox: `true`
- Writable workspace root: the issue workspace
- Shell: prepared by Symphony; commands should run directly without prefixing `source ~/.zshrc`.

## Injected Environment

The Symphony app-server injects the following environment variables by name. Secret values are not reproduced.

- `GH_TOKEN`
- `GITHUB_TOKEN`
- `AGENT_BROWSER_HOME`
- `XDG_RUNTIME_DIR`
- `AGENT_BROWSER_IDLE_TIMEOUT_MS`
- `AGENT_BROWSER_CONTENT_BOUNDARIES`

## Dynamic Tools

The thread registered these dynamic tool schemas.

```json
[
  {
    "description": "Execute a GitHub GraphQL query or mutation against the Symphony tracker. Mutations are restricted by allowlist; queries are unrestricted.",
    "inputSchema": {
      "properties": {
        "query": {
          "description": "GraphQL query or mutation source",
          "type": "string"
        },
        "variables": {
          "default": {},
          "description": "Variables map",
          "type": "object"
        }
      },
      "required": [
        "query"
      ],
      "type": "object"
    },
    "name": "github_graphql"
  },
  {
    "description": "Run constrained host-side agent-browser checks for local UI verification. Only localhost/127.0.0.1 URLs and safe read/capture actions are supported.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "action": {
          "description": "Browser action to run.",
          "enum": [
            "open",
            "wait_networkidle",
            "wait_text",
            "wait_selector",
            "wait_ms",
            "snapshot_interactive",
            "screenshot",
            "get_title",
            "get_url",
            "click",
            "fill",
            "type",
            "press",
            "select",
            "console",
            "errors",
            "close"
          ],
          "type": "string"
        },
        "annotate": {
          "description": "Annotate screenshot with interactive element labels.",
          "type": "boolean"
        },
        "full": {
          "description": "Capture a full-page screenshot.",
          "type": "boolean"
        },
        "key": {
          "description": "Key or key combination for press, such as Enter, Tab, Escape, or Control+a.",
          "type": "string"
        },
        "ms": {
          "description": "Milliseconds for wait_ms.",
          "maximum": 60000,
          "minimum": 0,
          "type": "integer"
        },
        "new_tab": {
          "description": "Open clicked link in a new tab when action=click.",
          "type": "boolean"
        },
        "path": {
          "description": "Optional relative workspace path for screenshot output.",
          "type": "string"
        },
        "selector": {
          "description": "Element selector or @ref for click, fill, type, select, wait_selector, and optional screenshot scoping.",
          "type": "string"
        },
        "text": {
          "description": "Text for fill, type, or wait_text.",
          "type": "string"
        },
        "url": {
          "description": "Required for action=open. Must be http(s)://localhost, http(s)://127.0.0.1, or http(s)://[::1].",
          "type": "string"
        },
        "value": {
          "description": "Single select dropdown value.",
          "type": "string"
        },
        "values": {
          "description": "One or more select dropdown values.",
          "items": {
            "type": "string"
          },
          "type": "array"
        }
      },
      "required": [
        "action"
      ],
      "type": "object"
    },
    "name": "agent_browser"
  }
]
```

## Rendered Symphony Prompt

The following block is the full rendered `elixir/WORKFLOW.md` prompt for issue `archelab/symphony#210` for this Rework dispatch, using the workpad variables supplied to the agent.

```text
You are working on GitHub item `archelab/symphony#210` in project Symphony.



## Item context

- Identifier: archelab/symphony#210
- Kind: issue
- Title: Add a pr with a file named initial_prompt.md that shows exactly all instructions you receive when you start.
- Current Project Status: Rework
- Labels: 
- URL: https://github.com/archelab/symphony/issues/210


## Description


Add a pr with a file named initial_prompt.md that shows exactly all instructions you receive when you start.


## Tools available

- `gh` CLI is on PATH and authenticated via `$GH_TOKEN` and `$GITHUB_TOKEN`. The default repo is **archelab/symphony**.
- Run shell commands directly from this prepared environment; do not prefix
  commands with `source ~/.zshrc`.
- The `github_graphql` tool is registered in this Codex session for tracker
  reads/writes that need raw GraphQL.
- The `agent_browser` tool is registered for constrained host-side local UI
  checks. It can open only localhost/127.0.0.1/[::1] HTTP(S) URLs and supports
  safe local inspection/interactions such as `open`, `wait_networkidle`,
  `wait_text`, `wait_selector`, `wait_ms`, `snapshot_interactive`,
  `screenshot`, `get_title`, `get_url`, `click`, `fill`, `type`, `press`,
  `select`, `console`, `errors`, and `close`.
- `$agent-browser` may be available for live UI checks. For local workers, its
  runtime state is prepared under the issue workspace via `$AGENT_BROWSER_HOME`
  and `$XDG_RUNTIME_DIR`, so do not override those paths unless the operator
  asks. These paths make browser state writable; they do not guarantee that the
  host browser can launch inside the current sandbox.

## Verification scope

- For helper agents, review-only agents, smoke-test probes, and browser-check
  probes, use `gpt-5.4-mini` by default to keep validation cost low. If that
  model is unavailable, fall back to `gpt-5.4`. Reserve the workflow's primary
  `codex.model` for implementation sessions that need it.
- If your change touches UI files (LiveView modules/templates, router-visible
  pages, static assets, or user-facing CSS/JS), run the app on a secondary port
  such as `4001` and inspect the live UI with browser evidence. Use the
  registered `agent_browser` tool first when it is available. If it is not
  available or cannot launch, use `$agent-browser`; use `browser-use:browser`
  only as a fallback when the first two paths are unavailable.
- Do not satisfy a UI verification requirement by assuming tests are enough.
  Capture browser evidence from the live app: at minimum open the page, wait for
  it to load, take an interactive snapshot or screenshot, inspect console/errors
  when supported, and close the browser/session.
- If your change is backend-only, do not spend time on browser snapshots unless
  the issue explicitly asks for them. Prefer API calls, logs, tests, and bounded
  runtime smoke checks.
- If browser tooling fails twice because of host/browser launch constraints,
  stop retrying and record the blocker or caveat in reviewer notes. If the
  operator asks for a host-side browser check, provide the exact commands they
  can run outside the Codex sandbox instead of switching to a more expensive
  model.

## Local runtime smoke checks

- Never leave `mix phx.server`, `./bin/symphony --port ...`, or any other
  long-running local web runtime attached in the foreground inside this agent
  session. Foreground servers can block the agent turn, stream dashboard output
  forever, and burn tokens without making progress.
- Start temporary UI/smoke runtimes in the background with a timeout, log file,
  and `trap` cleanup that kills the PID on exit. Record the PID, poll the health
  or API endpoint, then shut the process down before finishing.
- Use a secondary port such as `4001+`; the operator may already have the main
  Symphony process running on `4000`.
- Print one compact result block with the assertions you checked.

## Reading feedback


- Read issue conversation:
  `gh issue view 210 -R archelab/symphony --comments`


## Writing tracker updates

Use `gh issue comment`, `gh pr comment`, `gh pr review`, or the
`github_graphql` tool. To move this item to a new Status option, use the
`updateProjectV2ItemFieldValue` mutation; the project + status field IDs
are pre-resolved by Symphony but you can re-derive them via
`gh project field-list 1 --owner archelab`.

## Branch policy (derived from GitHub, not hardcoded)


Open work on a feature branch and submit a Pull Request against
`main`. Do not commit to
`main` directly.
When opening the PR, include an official closing/linking keyword in the PR body
so GitHub links the PR to this issue, for example: `Closes #210`.


Both `pr.base_ref_name` and `repository.default_branch` come straight from
GitHub via the candidate query, so this guidance updates automatically if
the protected branch changes upstream.

<!-- The markers below MUST stay in lock-step with SymphonyElixir.Workpad.Protocol.marker_open/marker_close. -->

## Agent Workpad Protocol (SPEC §11.8)

You have a cross-session workpad — a single GitHub Issue/PullRequest comment
identified by an HTML marker. Manage it via the `github_graphql` tool.

**Find or create the workpad:**

1. Query comments on the underlying issue (subject_id `I_kwDOSZFFec8AAAABCLpyGA`),
   paginating with `comments(first: 100, after: $cursor)` until you find a comment
   whose trimmed body starts with `<!-- symphony-workpad:v1 -->` OR `pageInfo.hasNextPage`
   is false.
2. If no match: post a new workpad with `addComment(input: { subjectId: "I_kwDOSZFFec8AAAABCLpyGA", body: $body })`.
3. If exactly one match: capture its node id and use `updateIssueComment(input: { id: $node_id, body: $body })`.
4. If multiple matches: operate on the newest by `(createdAt DESC, databaseId DESC)`.

The comment body MUST begin with `<!-- symphony-workpad:v1 -->` and end with
`<!-- /symphony-workpad:v1 -->` so future dispatches can find it.

**On first turn, append your row to the sessions table:**

| `019e2364-5554-7aa2-b0ee-982533639bb5` |  | 2026-05-13T22:10:37.207662Z | — | — | gpt-5.5 | — |


**Prior sessions** (most recent first; orchestrator-authoritative — do not invent values):


- `019e234f-43dc-7b51-bb1a-d9941cd205de` attempt=0 dispatched=2026-05-13T21:47:33.289617Z completed=2026-05-13T21:51:09.952185Z duration_ms=216662 model=gpt-5.5 stop_reason=agent_exit_normal



On voluntary final-turn completion: update your row's Ended/Duration/Stop reason
(use `agent_exit_normal` unless you know otherwise) AND archive your "Current session"
body under a `### Session 019e2364-5554-7aa2-b0ee-982533639bb5 notes` heading.

**Rate-limit handling (SPEC §11.8.6):** the workpad is best-effort. If `addComment` or
`updateIssueComment` returns a secondary-throttle `Retry-After` header, honour it and
SKIP the workpad write for the current turn rather than retrying in a tight loop. On
primary-quota exhaustion (`rateLimit.resetAt`), wait for reset before the next attempt.
The orchestrator's §13.1 structured logs remain the authoritative session record while
the workpad is unwritable.

## Status-transition rituals

You only ever flip the Project Status. Before doing so, ALWAYS execute the
ritual for the destination state. Do not flip Status first.

### Status → In Progress

When the current Project Status is `Agent Ready`, claim the item before code
work so the board shows that someone is actively working:

1. Read feedback/context first using the "Reading feedback" section above.
2. Find or create the workpad and append/update your current session row.
3. THEN flip Status to `In Progress` via `updateProjectV2ItemFieldValue`.

If the status update fails because of GitHub auth, rate limits, or GraphQL
allowlist constraints, record the failure in the workpad and continue only if
you can still safely perform the requested task. Do not move blocked dependent
items forward just to claim them; dependency gating still applies in both
`Agent Ready` and `In Progress`.

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
   your Current-session body under a `### Session 019e2364-5554-7aa2-b0ee-982533639bb5 notes`
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
```
