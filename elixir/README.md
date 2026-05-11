# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls GitHub Projects v2 for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `github_graphql` tool so that repo
skills can make raw GitHub GraphQL calls. Mutations are gated by an allowlist; by default the
following mutation field names are permitted: `addComment`, `updateProjectV2ItemFieldValue`,
`addLabelsToLabelable`, `removeLabelsFromLabelable`, `requestReviews`, `addPullRequestReview`,
`resolveReviewThread`. To narrow or widen, set
`:symphony_elixir, :github_graphql_mutation_allowlist` to a list of GraphQL mutation field names
in your release config.

If a claimed issue moves to a terminal state (configured via `tracker.terminal_states`, e.g.
`Done`, `Closed`, `Cancelled`, or `Duplicate` in your Project Status field), Symphony stops the
active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Provide a GitHub token via the `GITHUB_TOKEN` environment variable. The simplest path is
   `export GITHUB_TOKEN=$(gh auth token)` if you already use the `gh` CLI; otherwise create a
   GitHub Personal Access Token with the `project` and `repo` scopes and export it as
   `GITHUB_TOKEN`.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `github` skills to your repo.
   - The `github` skill expects Symphony's `github_graphql` app-server tool for raw GitHub
     GraphQL operations such as comment editing, Project field updates, label changes, or
     review-thread resolution.
5. Customize the copied `WORKFLOW.md` file for your project.
   - Set `tracker.owner`, `tracker.owner_type` (`organization` or `user`), `tracker.repo`, and
     `tracker.project_number` to point at your GitHub Project v2.
   - `tracker.status_field` names the single-select field that drives dispatch; configure
     `active_states`, `terminal_states`, `dependency_gating_states`, and any
     `cross_repo_blockers` to match your team's Project Status options.
6. Follow the instructions below to install the required runtime dependencies and start the service.

> [!NOTE]
> Migrating from the legacy Linear adapter? Any `WORKFLOW.md` still declaring `tracker.kind:
> linear` will now fail `Config.validate_semantics/1` with `:unsupported_tracker_kind` at boot.
> Switch the front matter to the GitHub config shown below.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: github
  endpoint: https://api.github.com/graphql
  api_token: $GITHUB_TOKEN
  owner: your-org
  owner_type: organization
  project_number: 1
  repo: your-repo
  status_field: Status
  active_states: ["In Progress", "Rework"]
  terminal_states: ["Done", "Closed", "Cancelled", "Duplicate"]
  dependency_gating_states: ["Blocked"]
  cross_repo_blockers: []
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a GitHub Projects v2 item {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_token` resolves `$GITHUB_TOKEN` by default when unset or when the value is the
  literal `$GITHUB_TOKEN`. Other `$VAR` env-backed tokens are also resolved.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_token: $GITHUB_TOKEN
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to talk to a real GitHub
Project v2 and launch a real `codex app-server` session:

```bash
cd elixir
export GITHUB_TOKEN=$(gh auth token)
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_GITHUB_OWNER` / `SYMPHONY_LIVE_GITHUB_REPO` / `SYMPHONY_LIVE_GITHUB_PROJECT_NUMBER`
  point the live scenario at the GitHub Project v2 Symphony should drive.
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list.

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary GitHub issue inside the configured Project v2, writes a
temporary `WORKFLOW.md`, runs a real agent turn, verifies the workspace side effect, requires
Codex to comment on the issue and move its Status field to a terminal state, then archives or
removes the disposable Project item so the run remains visible in GitHub.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
