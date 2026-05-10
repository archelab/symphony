# Symphony Elixir: Linear → GitHub Projects v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Linear tracker adapter in `elixir/` with a GitHub Projects v2 adapter conforming to SPEC.md (sections 1–18.1, the `Core Conformance` profile), using `archelab/symphony` Project #1 as the real-integration target.

**Architecture:** A single rewrite branch (`feat/github-tracker-spec`) with eight ordered commits. Each commit keeps the modules it touches green; the orchestrator's end-to-end loop is broken between commits 3 and 6 by design (the period when GitHub adapter exists but Linear is gone) and re-greens at commit 7. Linear code is deleted in commit 8 only after the GitHub path passes a real-integration test against `archelab/symphony`. Tracker writes (comments, Status changes) are agent-driven via a `github_graphql` Codex dynamic tool registered in `lib/symphony_elixir/codex/dynamic_tool.ex`; the `Tracker` behaviour drops `create_comment/2` and `update_issue_state/2`.

**Tech Stack:** Elixir 1.19, Phoenix 1.8, `req` HTTP client, `ecto` (schemaless changesets for config), `solid` (Liquid templates), `yaml_elixir`, `jason`, ExUnit + `Plug.Test`.

**Source spec:** `/Users/pedrocunha/repos/symphony/SPEC.md` — quote section numbers in commit messages.

**Real-integration target:**
- Project URL: `https://github.com/orgs/archelab/projects/1`
- Project node ID: `PVT_kwDODDTPxM4BXSCK`
- Status field ID: `PVTSSF_lADODDTPxM4BXSCKzhSf6vY`
- Repo: `archelab/symphony` (default branch `main`, kept clean — agent works on PR branches)

**Decisions baked into this plan:**
- Linear is deleted (no parallel adapter).
- Tracker writes go through a `github_graphql` Codex dynamic tool; orchestrator owns no write APIs (spec §11.5).
- One branch, many commits, one PR for Phase 1; three additive PRs for Phases 2–4.
- `pr.*` Tier 1 fields (`state`, `merged`, `is_draft`, `base_ref_name`, `merged_at`, `closed_at`, plus `branch_name` from `headRefName`) are CORE; Tier 2 fields ship in Phase 2 with §11.7 predicates.

---

## File Structure

### Files created in Phase 1
- `lib/symphony_elixir/github/client.ex` — low-level GraphQL POST: rate-limit handling, retry-after, pagination helpers, error categorization (spec §11.2, §11.4).
- `lib/symphony_elixir/github/adapter.ex` — implements the `SymphonyElixir.Tracker` behaviour: `fetch_candidate_issues/0`, `fetch_issues_by_states/1`, `fetch_issue_states_by_ids/1`. Owns query templates and post-fetch filters (`active_states`, `include_kinds`, `tracker.repo`, terminal-OR rule).
- `lib/symphony_elixir/github/normalize.ex` — pure functions converting raw GraphQL responses into the spec §4.1.1 Issue domain model (ProjectV2Item.type → kind, content → repository/number/labels/blocked_by/pr, etc.).
- `lib/symphony_elixir/github/project_resolver.ex` — first-use resolution of `tracker.project_id` OR `(owner, owner_type, project_number)`; caches resolved node ID + Status field ID + Status option map for the lifetime of the process. Runs the Status field probe (§11.2.4).
- `lib/symphony_elixir/github/issue.ex` — Issue struct matching domain model fields; replaces `lib/symphony_elixir/linear/issue.ex`.
- `lib/symphony_elixir/codex/github_graphql_tool.ex` — Codex dynamic tool registration: takes `{query, variables}`, calls `GitHub.Client.graphql/2`, returns response with `rateLimit` surfaced; enforces a configurable mutation-name allowlist.
- `test/symphony_elixir/github/client_test.exs` — unit tests with `Bypass` (or hand-rolled `Plug` server) for HTTP behavior.
- `test/symphony_elixir/github/adapter_test.exs` — adapter behavior using a fake client module.
- `test/symphony_elixir/github/normalize_test.exs` — pure-function tests on canned GraphQL payloads (no I/O).
- `test/symphony_elixir/github/project_resolver_test.exs` — resolution + cache + status-field-probe failures.
- `test/symphony_elixir/github_live_test.exs` — env-gated real-integration test against `archelab/symphony`.
- `test/fixtures/github/` — JSON fixtures of representative GraphQL payloads (issue, PR, draft issue, redacted, archived, status-unset).

### Files modified in Phase 1
- `elixir/WORKFLOW.md` — front matter rewrite to GitHub config; prompt template `gh`-aware with PR/issue/draft branches.
- `lib/symphony_elixir/config/schema.ex` — `Tracker` embedded schema rewritten; new `Github` sub-shape with all spec §5.3.1 fields; environment indirection now defaults to `GITHUB_TOKEN`.
- `lib/symphony_elixir/tracker.ex` — drop `create_comment/2` and `update_issue_state/2` callbacks; route to GitHub adapter.
- `lib/symphony_elixir/tracker/memory.ex` — drop write callbacks; expand domain to new `Issue` shape.
- `lib/symphony_elixir/orchestrator.ex` — predicate updates: terminal-OR (§11.2.1), `<no status>` rule, dependency-gating knobs (`dependency_gating_states`, `gate_running_on_dependencies`, `cross_repo_blockers`), workspace key sanitizer (`/` and `#`).
- `lib/symphony_elixir/workspace.ex` — sanitizer fix for `/` and `#` per spec §4.2.
- `lib/symphony_elixir/prompt_builder.ex` — render new domain fields; thread `attempt` and `last_run_completed_at`.
- `lib/symphony_elixir/codex/dynamic_tool.ex` — register `github_graphql` tool from `Codex.GithubGraphqlTool`.
- `lib/symphony_elixir/specs_check.ex` — spec compliance assertions adjusted for the new domain.
- `test/support/test_support.exs` — `workflow_content/1` rewritten to emit GitHub front matter; helpers for fake GitHub responses.
- `test/symphony_elixir/*_test.exs` — touched-up identifier strings (`openai/symphony#42` style) and new domain shape.

### Files deleted in Phase 1 (commit 8)
- `lib/symphony_elixir/linear/` (entire directory).
- `test/symphony_elixir/` Linear-specific tests (identified during the deletion commit).

### Phase 2-4 file deltas (outlines only)
- Phase 2: extend `github/normalize.ex` + `github/adapter.ex` (Tier 2 PR fields + selection set), new `lib/symphony_elixir/orchestrator/pr_predicates.ex`.
- Phase 3: new `lib/symphony_elixir_web/webhook_controller.ex`, `lib/symphony_elixir/webhook/dedup.ex`, `lib/symphony_elixir/webhook/signature.ex`, `lib/symphony_elixir/webhook/dispatcher.ex`. Phoenix endpoint pipeline tweak (raw-body plug for HMAC).
- Phase 4: `lib/symphony_elixir/comments/parser.ex`, `lib/symphony_elixir/comments/authz.ex`, `lib/symphony_elixir/comments/dispatcher.ex`.

---

## Phase 1 — Core Conformance (two PRs, eleven commits)

> Phase 1 ships as **two PRs** to keep the highest-risk commit (Task 6 orchestrator predicate rewrite) from being buried at position 8/10 of a single 3500-LOC review. PR1 is purely additive (no behavior change to the running orchestrator); PR2 swaps the orchestrator and deletes Linear.

### PR Strategy

**PR1 — Foundation (Tasks 0, 1, 2, 3, 4, 5a; 6 commits, ~1500 LOC)**

| Commit | Task | What lands | Linear after this PR |
|---|---|---|---|
| 1 | Task 0 | Strict toolchain (lint, dialyzer, mox, bypass, stream_data, CI). | Still working — `lint.baseline` covers Linear-era code without dialyzer noise. |
| 2 | Task 1 | Tracker schema gains GitHub fields + `kind` validation that allows `["github", "memory", "linear"]` during PR1, NOT just `["github", "memory"]`. Linear-shaped configs still parse. | Still working. |
| 3 | Task 2 | `Github.Issue` domain model + workspace sanitizer fix. | Untouched. |
| 4 | Task 3 | GitHub GraphQL client. | Untouched. |
| 5 | Task 4 | Project resolver + Status field probe. | Untouched. |
| 6 | Task 5a | Github.Normalize + RateLimitGate + Github.Adapter (implements `SymphonyElixir.Tracker` behaviour) + **env-gated live integration test against `archelab/symphony` Project #1**. **Tracker.adapter/0 routing is NOT modified yet** — `tracker.kind == "github"` is unreachable at runtime in PR1; Github.Adapter is exercised via unit tests (fake client) + a live test the implementer runs locally with `GITHUB_TOKEN` set. | Still wired through `Tracker.adapter/0`'s catch-all. |

PR1 outcome: GitHub adapter exists, fully unit-tested, validated against real GitHub, dormant at runtime. WORKFLOW.md still points at Linear. CI green via `lint.baseline` (live test tagged `:live_github` is skipped without a token).

**Why live testing in PR1.** The implementer iterates against real GitHub data while building the adapter — surfaces GraphQL schema drift, rate-limit behavior, encoding quirks, real PVTI_ / PVT_ node ID shapes that fakes cannot capture. This catches "the spec says X but GitHub actually returns Y" before the cutover in PR2.

**PR2 — Cutover (Tasks 5b, 6, 7, 8a, 8b; 5 commits, ~2000 LOC)**

| Commit | Task | What lands |
|---|---|---|
| 7 | Task 5b | `tracker.ex` rewrite — drop `create_comment/2` + `update_issue_state/2` callbacks, route `"github"` to `Github.Adapter`, drop the catch-all-to-Linear fallback. `kind` validation tightens to `["github", "memory"]`. |
| 8 | Task 6 | Orchestrator predicates: terminal-OR, `<no status>` reconcile, dependency gating, `dispatchable?/2`, `stop_worker/2` logging, `completed`-as-map state change. |
| 9 | Task 7 | WORKFLOW.md flips to GitHub front matter; `github_graphql` Codex tool registered; prompt template switches to `gh`-aware multi-kind branching. |
| 10 | Task 8a | Real-integration test (`github_live_test.exs`) against `archelab/symphony` Project #1. Gated by `GITHUB_TOKEN`. |
| 11 | Task 8b | Delete Linear modules + Linear-specific tests + tracker `kind` validation that allowed `"linear"` in PR1. |

PR2 outcome: orchestrator dispatches against GitHub, Linear deleted, full `mix lint` (with dialyzer) green.

### Why this split works

- PR1 keeps the running system (Linear) untouched; Github.Adapter is dead weight that's exercised only by unit tests. Reviewers verify the static contract without worrying about live regressions.
- PR2's first commit (Task 5b) is the seam — once the routing flip lands, Linear is unreachable but still compiled. The remaining commits in PR2 build on each other.
- Each PR is independently revertable. If PR2 fails in production after merge, `git revert` of PR2's commits restores Linear via the catch-all that PR1 left intact (until Task 8b).

### Why Task 0 lands first

Task 0 lands the strict toolchain BEFORE any rewrite work so dialyzer / set-theoretic type warnings / formatter / credo / coverage all fail loudly during Tasks 1–8 instead of at PR-time. Skipping Task 0 leaves the existing weaker `mix lint` in place and makes the rewrite harder to validate incrementally. PR1 uses `lint.baseline` (no dialyzer) per-commit; PR2 uses full `lint`.

### Task 0: Strict toolchain (lint, type check, test, coverage)

**Spec coverage:** none — this is a deployment-quality concern, not a SPEC.md requirement. Bakes in the strictest static analysis Elixir 1.19 supports as of mid-2026.

**What this commit installs:**

| Concern | Tool | Strict mode |
|---|---|---|
| Formatter | `mix format` | `--check-formatted` fails CI on drift |
| Compile warnings | Elixir 1.19 set-theoretic checker | `--warnings-as-errors` |
| @spec presence | existing `mix specs.check` | already strict |
| Style/refactor | `credo ~> 1.7` | `--strict` |
| Static analysis | `dialyxir ~> 1.4` | `--halt-exit-status` + `:underspecs`, `:unmatched_returns`, `:error_handling`, `:extra_return`, `:missing_return`, `:unknown` |
| HTTP test stubs | `bypass ~> 2.1` | required by Task 3 |
| Behavior mocks | `mox ~> 1.2` | replaces `Application.put_env` injection in Task 5 / Task 7 tool tests |
| Property tests | `stream_data ~> 1.1` | covers normalization + dispatch predicate branches |
| Coverage | `mix test --cover` | 100% threshold (already in `mix.exs`) |

**Files:**
- Modify: `elixir/mix.exs` — deps, dialyzer flags, aliases.
- Create: `elixir/.formatter.exs` (already exists; verify line length + import_deps).
- Modify: `elixir/.credo.exs` — switch to strict ruleset (create if missing).
- Modify: `.github/workflows/elixir.yml` (or equivalent CI file) — add `mix lint` step.

- [ ] **Step 1: Add new dev/test dependencies**

In `elixir/mix.exs`, replace the `defp deps` body with:

```elixir
defp deps do
  [
    {:bandit, "~> 1.8"},
    {:floki, ">= 0.30.0", only: :test},
    {:lazy_html, ">= 0.1.0", only: :test},
    {:phoenix, "~> 1.8.0"},
    {:phoenix_html, "~> 4.2"},
    {:phoenix_live_view, "~> 1.1.0"},
    {:req, "~> 0.5"},
    {:jason, "~> 1.4"},
    {:yaml_elixir, "~> 2.12"},
    {:solid, "~> 1.2"},
    {:ecto, "~> 3.13"},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:bypass, "~> 2.1", only: :test},
    {:mox, "~> 1.2", only: :test},
    {:stream_data, "~> 1.1", only: [:dev, :test]}
  ]
end
```

`dialyxir` moves to `[:dev, :test]` so CI can run it without a separate dev install.

- [ ] **Step 2: Add strict dialyzer flags**

In `elixir/mix.exs` `project/0`, replace the `dialyzer:` keyword with:

```elixir
dialyzer: [
  plt_local_path: "priv/plts",
  plt_core_path: "priv/plts",
  plt_add_apps: [:mix, :ex_unit],
  flags: [
    :error_handling,
    :extra_return,
    :missing_return,
    :underspecs,
    :unmatched_returns,
    :unknown
  ]
],
```

`:underspecs` is the strict knob — it fails when an `@spec` is broader than success typing infers, equivalent to `noImplicitAny` in TypeScript. `:unmatched_returns` flags ignored return values that aren't explicitly bound to `_`.

**Verify flag names against your installed dialyxir before committing:**

```bash
cd elixir && mise exec -- mix help dialyzer | grep -A 30 "Warning options"
```

Confirm `:underspecs`, `:unmatched_returns`, `:error_handling`, `:extra_return`, `:missing_return`, `:unknown` are listed. If any flag has been renamed in your dialyxir version, fail-fix at this step rather than after the PLT build.

- [ ] **Step 3: Rewire the `lint` alias and add `test_strict`**

In `elixir/mix.exs` `defp aliases`, replace with:

```elixir
defp aliases do
  [
    setup: ["deps.get", "deps.compile", "dialyzer --plt"],
    build: ["escript.build"],
    # `mix lint` is the strict gate run on every PR. Linear-era carry-over
    # modules may surface :underspecs warnings that Task 8 will retire when
    # Linear is deleted; until then, run `lint.baseline` to capture the
    # acceptable noise floor and track regressions only against that floor.
    lint: [
      "format --check-formatted",
      "compile --warnings-as-errors",
      "specs.check",
      "credo --strict",
      "dialyzer --halt-exit-status"
    ],
    "lint.baseline": [
      "format --check-formatted",
      "compile --warnings-as-errors",
      "specs.check",
      "credo --strict"
    ],
    test_strict: ["test --cover --warnings-as-errors"]
  ]
end
```

`mix setup` now also builds the dialyzer PLT once; subsequent `mix lint` runs are fast (single-file diff).

- [ ] **Step 4: Build the PLT once**

```bash
cd elixir && mise exec -- mix deps.get && mise exec -- mix dialyzer --plt
```

Expected: PLT built. First run is slow (~2 min). Subsequent runs hit the cached PLT.

- [ ] **Step 4.5: Baseline check BEFORE committing Task 0**

```bash
cd elixir && mise exec -- mix lint
```

Expected: one of two outcomes.

**Outcome A (clean):** Carry-over Linear-era code already has tight specs. Proceed to Step 5.

**Outcome B (noisy):** `dialyzer` surfaces `:underspecs` / `:unmatched_returns` warnings on Linear-era modules (`workflow_store.ex`, `codex/app_server.ex`, `prompt_builder.ex`, `orchestrator.ex`). This is expected — those modules pre-date the strict toolchain. Capture the warnings as a baseline:

```bash
mise exec -- mix dialyzer --halt-exit-status 2>&1 | tee dialyzer_baseline.txt
```

Then choose ONE of the following:

- **(B-fix)** Tighten the offending `@spec` annotations in carry-over code as part of Task 0. Preferred when the count is < ~10 warnings.
- **(B-defer)** Use `lint.baseline` (which omits dialyzer) as the per-PR gate for PR1, and require `lint` (with dialyzer) green ONLY on the PR2 cutover (where Task 8 deletes Linear). Document this in the Task 0 commit message and the CI workflow.

Do NOT add `:nowarn` flags, do NOT relax the dialyzer config, do NOT commit `dialyzer_baseline.txt`. The choice is binary: fix at the spec site or temporarily run the cheaper alias.

- [ ] **Step 5: Run the chosen lint pipeline against the current tree**

```bash
cd elixir && mise exec -- mix lint   # if B-fix or A
# OR
cd elixir && mise exec -- mix lint.baseline  # if B-defer
```

Expected: passes.

- [ ] **Step 6: Run `mix test_strict`**

```bash
cd elixir && mise exec -- mix test_strict
```

Expected: existing tests pass with `--warnings-as-errors`. Coverage report shows ≥100% on non-ignored modules.

- [ ] **Step 7: Update CI**

Find `.github/workflows/*.yml` (or whichever CI file is in use). Replace the test job's run-step with:

```yaml
- name: Restore PLT cache
  uses: actions/cache@v4
  with:
    path: elixir/priv/plts
    key: plts-${{ runner.os }}-${{ hashFiles('elixir/mix.lock') }}

- name: Lint (format, warnings, specs, credo, dialyzer)
  run: |
    cd elixir
    mix deps.get
    mix deps.compile
    mix dialyzer --plt
    mix lint

- name: Test (strict, with coverage)
  run: |
    cd elixir
    mix test_strict
```

The PLT path `priv/plts` is NOT dialyxir's default (it writes to `_build/<env>/dialyxir_*.plt`). Pin it explicitly in `mix.exs` so the CI cache key actually hits — see Step 2's `dialyzer:` block which sets both `plt_local_path:` and `plt_core_path:`. Add `priv/plts/` to `.gitignore`.

- [ ] **Step 8: Commit**

```bash
git add elixir/mix.exs elixir/.credo.exs .github/workflows/*.yml
git commit -m "$(cat <<'EOF'
chore(elixir): tighten lint/type/test pipeline

mix lint now runs:
- mix format --check-formatted (was missing)
- mix compile --warnings-as-errors (Elixir 1.19 set-theoretic types fail CI)
- mix specs.check (existing)
- mix credo --strict (existing)
- mix dialyzer --halt-exit-status with strict flags:
    :error_handling, :extra_return, :missing_return,
    :underspecs, :unmatched_returns, :unknown

mix test_strict adds --cover --warnings-as-errors on top of the existing
100% coverage threshold.

Adds bypass (HTTP stubs), mox (behaviour mocks), stream_data (property
tests) as test deps. Dialyxir moves to [:dev, :test] so CI runs it
without a separate dev install. PLT cached under priv/plts for CI reuse.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1: Rewrite the Tracker config schema for GitHub

**Spec coverage:** §5.3.1 (`tracker` block), §11.4 (error categories `missing_tracker_api_token`, `missing_tracker_project_identifier`, `unsupported_tracker_kind`).

**Files:**
- Modify: `lib/symphony_elixir/config/schema.ex`
- Modify: `test/support/test_support.exs` (helper fixture)
- Create: `test/symphony_elixir/config/github_tracker_test.exs`

- [ ] **Step 1: Write the failing config-parse test**

Create `test/symphony_elixir/config/github_tracker_test.exs`:

```elixir
defmodule SymphonyElixir.Config.GithubTrackerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "parses a minimal GitHub tracker config" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "ghp_test",
        "owner" => "archelab",
        "owner_type" => "organization",
        "project_number" => 1,
        "repo" => "symphony"
      }
    }

    assert {:ok, settings} = Schema.parse(config)
    assert settings.tracker.kind == "github"
    assert settings.tracker.endpoint == "https://api.github.com/graphql"
    assert settings.tracker.api_token == "ghp_test"
    assert settings.tracker.owner == "archelab"
    assert settings.tracker.owner_type == "organization"
    assert settings.tracker.project_number == 1
    assert settings.tracker.repo == "symphony"
    assert settings.tracker.status_field == "Status"
    assert settings.tracker.include_kinds == ["issue", "pull_request"]
    assert settings.tracker.active_states == ["Todo", "In Progress"]
    assert settings.tracker.terminal_states == ["Done"]
    assert settings.tracker.dependency_gating_states == ["Todo"]
    assert settings.tracker.cross_repo_blockers == true
    assert settings.tracker.gate_running_on_dependencies == false
  end

  test "resolves $GITHUB_TOKEN env reference" do
    System.put_env("GITHUB_TOKEN", "ghp_resolved")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "$GITHUB_TOKEN",
        "owner" => "archelab",
        "project_number" => 1
      }
    }

    assert {:ok, settings} = Schema.parse(config)
    assert settings.tracker.api_token == "ghp_resolved"
  end

  test "accepts project_id and ignores owner_type for resolution" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "ghp_test",
        "project_id" => "PVT_kwDODDTPxM4BXSCK"
      }
    }

    assert {:ok, settings} = Schema.parse(config)
    assert settings.tracker.project_id == "PVT_kwDODDTPxM4BXSCK"
    assert settings.tracker.project_number == nil
  end

  test "rejects neither project_id nor project_number" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "ghp_test",
        "owner" => "archelab"
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "project_id"
  end

  test "rejects unknown owner_type" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "ghp_test",
        "owner" => "archelab",
        "owner_type" => "team",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(config)
  end

  test "rejects unknown tracker kind with unsupported_tracker_kind" do
    # PR1 still accepts "linear" as a transition kind (see Schema.@valid_kinds);
    # use a truly unsupported value here. PR2 (Task 8b) tightens this further.
    config = %{
      "tracker" => %{
        "kind" => "jira",
        "api_token" => "ghp_test",
        "owner" => "archelab",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "unsupported_tracker_kind"
  end

  test "rejects github kind with missing api_token" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "owner" => "archelab",
        "owner_type" => "organization",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "missing_tracker_api_token"
  end

  test "rejects github kind with empty api_token after env resolution" do
    System.put_env("GITHUB_TOKEN", "")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

    config = %{
      "tracker" => %{
        "kind" => "github",
        "api_token" => "$GITHUB_TOKEN",
        "owner" => "archelab",
        "project_number" => 1
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "missing_tracker_api_token"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/config/github_tracker_test.exs
```

Expected: FAIL — Tracker schema still has Linear fields, `kind: "github"` not recognized, missing fields raise.

- [ ] **Step 3: Replace the Tracker embedded schema**

Replace the entire `defmodule Tracker` block at `lib/symphony_elixir/config/schema.ex:40-66` with:

```elixir
defmodule Tracker do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @valid_owner_types ~w(organization user)
  # PR1 transition window: "linear" is accepted so existing WORKFLOW.md
  # configs continue to parse while the GitHub adapter lands as dead code.
  # PR2 commit 11 (Task 8b) tightens this to ~w(github memory).
  @valid_kinds ~w(github memory linear)
  @valid_kinds_for_dispatch ~w(issue pull_request draft_issue)

  embedded_schema do
    field(:kind, :string)
    field(:endpoint, :string, default: "https://api.github.com/graphql")
    field(:api_token, :string)
    field(:owner, :string)
    field(:owner_type, :string, default: "organization")
    field(:project_number, :integer)
    field(:project_id, :string)
    field(:repo, :string)
    field(:status_field, :string, default: "Status")
    field(:priority_field, :string, default: "Priority")
    field(:priority_mapping, :map, default: %{})
    field(:include_kinds, {:array, :string}, default: ["issue", "pull_request"])
    field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
    field(:terminal_states, {:array, :string}, default: ["Done"])
    field(:dependency_gating_states, {:array, :string}, default: ["Todo"])
    field(:gate_running_on_dependencies, :boolean, default: false)
    field(:cross_repo_blockers, :boolean, default: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :kind, :endpoint, :api_token, :owner, :owner_type, :project_number, :project_id, :repo,
        :status_field, :priority_field, :priority_mapping, :include_kinds, :active_states,
        :terminal_states, :dependency_gating_states, :gate_running_on_dependencies,
        :cross_repo_blockers
      ],
      empty_values: []
    )
    |> validate_inclusion(:kind, @valid_kinds, message: "unsupported_tracker_kind")
    |> validate_inclusion(:owner_type, @valid_owner_types)
    |> validate_subset(:include_kinds, @valid_kinds_for_dispatch)
    |> validate_project_identifier()
    |> validate_api_token_present()
  end

  defp validate_api_token_present(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :api_token)} do
      {"github", token} when is_binary(token) and token != "" -> changeset
      {"github", _} -> add_error(changeset, :api_token, "missing_tracker_api_token")
      _ -> changeset
    end
  end

  defp validate_project_identifier(changeset) do
    project_id = get_field(changeset, :project_id)
    project_number = get_field(changeset, :project_number)
    owner = get_field(changeset, :owner)
    kind = get_field(changeset, :kind)

    cond do
      kind != "github" -> changeset
      is_binary(project_id) and project_id != "" -> changeset
      is_integer(project_number) and is_binary(owner) and owner != "" -> changeset
      true -> add_error(changeset, :project_id, "project_id or (owner + project_number) is required")
    end
  end
end
```

- [ ] **Step 4: Update `finalize_settings/1` to resolve `GITHUB_TOKEN`**

Replace the `finalize_settings/1` body in `lib/symphony_elixir/config/schema.ex` so the tracker secret-resolution uses the new `api_token` field and `GITHUB_TOKEN` env var:

```elixir
defp finalize_settings(settings) do
  tracker = %{
    settings.tracker
    | api_token: resolve_secret_setting(settings.tracker.api_token, System.get_env("GITHUB_TOKEN"))
  }

  workspace = %{
    settings.workspace
    | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
  }

  codex = %{
    settings.codex
    | approval_policy: normalize_keys(settings.codex.approval_policy),
      turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
  }

  %{settings | tracker: tracker, workspace: workspace, codex: codex}
end
```

- [ ] **Step 5: Update `test/support/test_support.exs` defaults to GitHub shape**

Replace the tracker-related keys in `defp workflow_content/1` (lines ~95–101 and ~166–175) so the helper emits GitHub front matter:

```elixir
config =
  Keyword.merge(
    [
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "ghp_test_token",
      tracker_owner: "archelab",
      tracker_owner_type: "organization",
      tracker_project_number: 1,
      tracker_project_id: nil,
      tracker_repo: "symphony",
      tracker_status_field: "Status",
      tracker_include_kinds: ["issue", "pull_request"],
      tracker_active_states: ["Agent Ready", "In Progress", "Rework"],
      tracker_terminal_states: ["Done"],
      tracker_dependency_gating_states: ["Agent Ready"],
      # ... keep the rest of the keys unchanged
```

Replace the tracker YAML emission block to the new shape:

```elixir
"tracker:",
"  kind: #{yaml_value(tracker_kind)}",
"  endpoint: #{yaml_value(tracker_endpoint)}",
"  api_token: #{yaml_value(tracker_api_token)}",
"  owner: #{yaml_value(tracker_owner)}",
"  owner_type: #{yaml_value(tracker_owner_type)}",
"  project_number: #{yaml_value(tracker_project_number)}",
"  project_id: #{yaml_value(tracker_project_id)}",
"  repo: #{yaml_value(tracker_repo)}",
"  status_field: #{yaml_value(tracker_status_field)}",
"  include_kinds: #{yaml_value(tracker_include_kinds)}",
"  active_states: #{yaml_value(tracker_active_states)}",
"  terminal_states: #{yaml_value(tracker_terminal_states)}",
"  dependency_gating_states: #{yaml_value(tracker_dependency_gating_states)}",
```

- [ ] **Step 6: Run the new test to verify it passes**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/config/github_tracker_test.exs
```

Expected: PASS (5 tests).

- [ ] **Step 7: Run the existing config tests — many will fail temporarily**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs
```

Expected: many failures referencing `tracker_project_slug` / `tracker_assignee`. Skip fixing them — those tests are about workspace, the Tracker shape change cascades. Catalog the failures, defer to Task 6 where the orchestrator predicates land. Don't try to make the orchestrator e2e green here; only the new schema test must pass.

Mark deferred breakages with `@tag :skip_until_task_6` ONE at a time as they appear, and add a comment `# TODO(Task 6): re-enable after orchestrator predicates land`.

- [ ] **Step 8: Commit**

```bash
git add lib/symphony_elixir/config/schema.ex \
        test/support/test_support.exs \
        test/symphony_elixir/config/github_tracker_test.exs \
        test/symphony_elixir/workspace_and_config_test.exs
git commit -m "$(cat <<'EOF'
feat(elixir): rewrite Tracker config schema for GitHub Projects v2

Per SPEC.md §5.3.1, replace Linear-shaped Tracker embedded schema with the
GitHub field set: owner, owner_type, project_number, project_id, repo,
status_field, priority_field, priority_mapping, include_kinds, active_states,
terminal_states, dependency_gating_states, gate_running_on_dependencies,
cross_repo_blockers. Default endpoint flips to api.github.com; GITHUB_TOKEN
replaces LINEAR_API_KEY for $VAR resolution.

Tests skipped with :skip_until_task_6 will be re-enabled once orchestrator
predicates use the new shape.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Domain model — Issue + PR sub-struct (Tier 1)

**Spec coverage:** §4.1.1 (Issue fields), §4.2 (workspace key sanitization for `/` and `#`).

**Files:**
- Create: `lib/symphony_elixir/github/issue.ex`
- Modify: `lib/symphony_elixir/workspace.ex` (sanitizer)
- Create: `test/symphony_elixir/github/issue_test.exs`
- Create: `test/symphony_elixir/workspace_sanitize_test.exs`

- [ ] **Step 1: Write failing tests for the new Issue struct**

Create `test/symphony_elixir/github/issue_test.exs`:

```elixir
defmodule SymphonyElixir.Github.IssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Github.Issue

  test "issue kind has nil pr struct and populated repository" do
    issue =
      Issue.new(%{
        id: "PVTI_xxx",
        identifier: "archelab/symphony#42",
        kind: "issue",
        title: "Refactor",
        description: "body",
        state: "Agent Ready",
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        number: 42,
        labels: ["bug"],
        blocked_by: [],
        url: "https://github.com/archelab/symphony/issues/42",
        issue_state: "OPEN"
      })

    assert issue.kind == "issue"
    assert issue.pr == nil
    assert issue.repository.name_with_owner == "archelab/symphony"
    assert issue.branch_name == nil
  end

  test "pull_request kind populates pr Tier-1 fields and branch_name" do
    issue =
      Issue.new(%{
        id: "PVTI_yyy",
        identifier: "archelab/symphony#7",
        kind: "pull_request",
        title: "Fix CI",
        state: "In Progress",
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        number: 7,
        branch_name: "fix-ci",
        labels: [],
        blocked_by: [],
        url: "https://github.com/archelab/symphony/pull/7",
        issue_state: "OPEN",
        pr: %{
          state: "OPEN",
          merged: false,
          merged_at: nil,
          closed_at: nil,
          is_draft: false,
          base_ref_name: "main"
        }
      })

    assert issue.kind == "pull_request"
    assert issue.branch_name == "fix-ci"
    assert issue.pr.state == "OPEN"
    assert issue.pr.merged == false
    assert issue.pr.is_draft == false
    assert issue.pr.base_ref_name == "main"
  end

  test "draft_issue identifier uses LAST 8 characters of the project item node ID" do
    # Spec §4.1.1: "where <short> is the last 8 characters of the Project item
    # node ID". The adapter normalization is the source of truth for this rule;
    # this test pins the contract at the domain layer so a later refactor that
    # accidentally takes the FIRST 8 chars is caught before it reaches a fixture.
    full_id = "PVTI_lAHOAAAAAAFAF6gQ123"
    short = String.slice(full_id, -8, 8)
    assert short == "AF6gQ123"

    issue =
      Issue.new(%{
        id: full_id,
        identifier: "draft:" <> short,
        kind: "draft_issue",
        title: "Idea",
        state: "Todo",
        labels: [],
        blocked_by: [],
        repository: nil,
        number: nil,
        url: nil,
        issue_state: nil
      })

    assert issue.identifier == "draft:AF6gQ123"
  end

  test "draft_issue kind has nil repository, nil number, identifier prefix draft:" do
    issue =
      Issue.new(%{
        id: "PVTI_AF6gQ123",
        identifier: "draft:AF6gQ123",
        kind: "draft_issue",
        title: "Idea",
        state: "Todo",
        labels: [],
        blocked_by: [],
        repository: nil,
        number: nil,
        url: nil,
        issue_state: nil
      })

    assert issue.kind == "draft_issue"
    assert issue.repository == nil
    assert issue.number == nil
    assert issue.url == nil
    assert issue.labels == []
    assert String.starts_with?(issue.identifier, "draft:")
  end
end
```

- [ ] **Step 2: Run the test, expect failure**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/issue_test.exs
```

Expected: FAIL — module `SymphonyElixir.Github.Issue` does not exist.

- [ ] **Step 3: Implement the Issue struct**

Create `lib/symphony_elixir/github/issue.ex`:

```elixir
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
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/issue_test.exs
```

Expected: PASS (4 tests).

- [ ] **Step 5: Write failing test for workspace sanitizer**

Create `test/symphony_elixir/workspace_sanitize_test.exs`:

```elixir
defmodule SymphonyElixir.WorkspaceSanitizeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workspace

  test "replaces / and # in GitHub identifier" do
    assert Workspace.workspace_key("archelab/symphony#42") == "archelab_symphony_42"
  end

  test "replaces / and # in cross-repo PR identifier" do
    assert Workspace.workspace_key("archelab/arche#1234") == "archelab_arche_1234"
  end

  test "preserves dashes and dots" do
    assert Workspace.workspace_key("myorg/my-repo.x#1") == "myorg_my-repo.x_1"
  end

  test "passes through draft identifier" do
    assert Workspace.workspace_key("draft:AF6gQ123") == "draft_AF6gQ123"
  end

  test "no path separator survives" do
    refute String.contains?(Workspace.workspace_key("a/b#c"), "/")
    refute String.contains?(Workspace.workspace_key("a/b#c"), "#")
  end

  test "control chars and whitespace are replaced" do
    assert Workspace.workspace_key("a\tb c\n#1") == "a_b_c__1"
  end

  test "dot-only identifier survives sanitizer (spec §4.2 allows .)" do
    # `.` and `..` are intentionally not stripped here. Spec §9.5 path-prefix
    # containment is the defense in depth — every workspace path computed from
    # the result of workspace_key/1 must pass through PathSafety.canonicalize/1
    # and a workspace-root prefix check before any filesystem operation.
    assert Workspace.workspace_key("..") == ".."
    assert Workspace.workspace_key(".") == "."
  end
end
```

- [ ] **Step 6: Run test, expect failure**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/workspace_sanitize_test.exs
```

Expected: FAIL — function `workspace_key/1` not exported, or sanitizer leaves `/` intact.

- [ ] **Step 7: Add `workspace_key/1` to `lib/symphony_elixir/workspace.ex`**

In `lib/symphony_elixir/workspace.ex`, locate the existing private sanitization (search for `Regex.replace` or similar over the issue identifier). Promote it to a public, exported function and ensure the regex matches `[^A-Za-z0-9._-]`:

```elixir
@doc """
Sanitize an issue identifier into a workspace directory name per spec §4.2.

The `/` and `#` characters MUST be replaced; otherwise the identifier
would either escape the workspace root (path-separator collision) or
collide with a literal `#` in shell expansions.
"""
@spec workspace_key(String.t()) :: String.t()
def workspace_key(identifier) when is_binary(identifier) do
  Regex.replace(~r/[^A-Za-z0-9._-]/, identifier, "_")
end
```

Update internal call sites that compute the workspace directory to use `workspace_key/1`.

- [ ] **Step 8: Run sanitizer test to verify pass**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/workspace_sanitize_test.exs
```

Expected: PASS (7 tests).

- [ ] **Step 9: Commit**

```bash
git add lib/symphony_elixir/github/issue.ex \
        lib/symphony_elixir/workspace.ex \
        test/symphony_elixir/github/issue_test.exs \
        test/symphony_elixir/workspace_sanitize_test.exs
git commit -m "$(cat <<'EOF'
feat(elixir): add Github.Issue domain model + workspace sanitizer for /, #

SPEC.md §4.1.1 normalized Issue, with Tier 1 PR sub-struct (state, merged,
merged_at, closed_at, is_draft, base_ref_name). Tier 2 PR fields (review
decision, check state, threads, opinionated reviews) deferred to Phase 2.

Workspace.workspace_key/1 promoted to public; replaces all chars outside
[A-Za-z0-9._-] including the / and # required by GitHub identifiers
(`<owner>/<repo>#<number>`). Fixes spec §4.2 / §9.5 containment.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: GitHub GraphQL client (low-level HTTP)

**Spec coverage:** §11.2 (transport, headers, pagination), §11.4 (error categories), §11.2 rate-limit signals (primary `rateLimit.remaining/resetAt` vs secondary HTTP 429/403 + `Retry-After`).

**Files:**
- Create: `lib/symphony_elixir/github/client.ex`
- Create: `test/symphony_elixir/github/client_test.exs`
- Create: `test/fixtures/github/error_forbidden.json`
- Create: `test/fixtures/github/rate_limit_response.json`

- [ ] **Step 1: Write failing tests for the client**

Create `test/symphony_elixir/github/client_test.exs`:

```elixir
defmodule SymphonyElixir.Github.ClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Github.Client

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}/graphql"}
  end

  test "sends Bearer token and Next-Global-ID header", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      assert ["Bearer ghp_test"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["1"] = Plug.Conn.get_req_header(conn, "x-github-next-global-id")
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")

      Plug.Conn.resp(conn, 200, ~s({"data": {"viewer": {"login": "x"}}}))
    end)

    assert {:ok, %{"data" => %{"viewer" => %{"login" => "x"}}}} =
             Client.graphql(
               "query { viewer { login } }",
               %{},
               endpoint: url,
               token: "ghp_test"
             )
  end

  test "maps HTTP 401 to tracker_permission_denied", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"message": "Bad credentials"}))
    end)

    assert {:error, {:tracker_permission_denied, _}} =
             Client.graphql("query { viewer { login } }", %{}, endpoint: url, token: "ghp_x")
  end

  test "maps HTTP 429 with Retry-After to github_rate_limited", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "60")
      |> Plug.Conn.resp(429, "")
    end)

    assert {:error, {:github_rate_limited, %{retry_after_seconds: 60}}} =
             Client.graphql("query { viewer { login } }", %{}, endpoint: url, token: "ghp_x")
  end

  test "maps HTTP 200 with FORBIDDEN GraphQL error to tracker_permission_denied",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      body = ~s({"errors":[{"type":"FORBIDDEN","message":"Read access denied"}]})
      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:error, {:tracker_permission_denied, _}} =
             Client.graphql("query { viewer { login } }", %{}, endpoint: url, token: "ghp_x")
  end

  test "maps HTTP 200 with primary rate limit exhaustion", %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      body =
        ~s({"data":{"rateLimit":{"remaining":0,"resetAt":"2026-05-10T12:00:00Z"}}})

      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:ok, %{"data" => %{"rateLimit" => rl}}} =
             Client.graphql("query { rateLimit { remaining resetAt } }", %{},
               endpoint: url,
               token: "ghp_x"
             )

    assert rl["remaining"] == 0
    assert rl["resetAt"] == "2026-05-10T12:00:00Z"
  end

  test "returns github_graphql_errors when top-level errors are not FORBIDDEN",
       %{bypass: bypass, base_url: url} do
    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      body = ~s({"errors":[{"type":"NOT_FOUND","message":"thing not found"}]})
      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:error, {:github_graphql_errors, [%{"type" => "NOT_FOUND"}]}} =
             Client.graphql("query { thing { id } }", %{}, endpoint: url, token: "ghp_x")
  end
end
```

Add `{:bypass, "~> 2.1", only: :test}` to `mix.exs` deps; run `mise exec -- mix deps.get`.

- [ ] **Step 2: Run, expect failure**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/client_test.exs
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement `lib/symphony_elixir/github/client.ex`**

```elixir
defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  Low-level GitHub GraphQL client. Spec §11.2.

  Public surface:
    graphql(query, variables, opts) :: {:ok, map} | {:error, {category, payload}}

  Recognized error categories (spec §11.4):
    :github_api_request, :github_api_status, :github_rate_limited,
    :github_graphql_errors, :github_unknown_payload, :tracker_permission_denied
  """

  require Logger

  @default_timeout_ms 30_000
  @user_agent "symphony-elixir/0.1"

  @type opts :: [
          endpoint: String.t(),
          token: String.t(),
          timeout_ms: pos_integer()
        ]

  @spec graphql(String.t(), map(), opts) ::
          {:ok, map()} | {:error, {atom(), term()}}
  def graphql(query, variables, opts \\ []) when is_binary(query) and is_map(variables) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    token = Keyword.fetch!(opts, :token)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    body = Jason.encode!(%{"query" => query, "variables" => variables})

    headers = [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/json"},
      {"x-github-next-global-id", "1"},
      {"user-agent", @user_agent}
    ]

    request =
      Req.new(
        url: endpoint,
        method: :post,
        headers: headers,
        body: body,
        receive_timeout: timeout,
        retry: false
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} -> handle_200(body)
      {:ok, %Req.Response{status: 401}} -> {:error, {:tracker_permission_denied, %{http: 401}}}
      {:ok, %Req.Response{status: 403, headers: headers}} -> handle_403(headers)
      {:ok, %Req.Response{status: 429, headers: headers}} -> rate_limited(headers)
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_api_status, %{http: status, body: truncate(body)}}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp handle_200(%{"errors" => [_ | _] = errors} = body) do
    if Enum.any?(errors, &forbidden?/1) do
      {:error, {:tracker_permission_denied, errors}}
    else
      _ = body
      {:error, {:github_graphql_errors, errors}}
    end
  end

  defp handle_200(%{"data" => _} = body), do: {:ok, body}
  defp handle_200(_other), do: {:error, {:github_unknown_payload, "missing data and errors"}}

  defp forbidden?(%{"type" => type}) when type in ["FORBIDDEN", "INSUFFICIENT_SCOPES"], do: true
  defp forbidden?(_), do: false

  defp handle_403(headers) do
    case fetch_header(headers, "retry-after") do
      nil -> {:error, {:tracker_permission_denied, %{http: 403}}}
      value -> {:error, {:github_rate_limited, %{retry_after_seconds: parse_int(value)}}}
    end
  end

  defp rate_limited(headers) do
    seconds =
      headers
      |> fetch_header("retry-after")
      |> parse_int()

    {:error, {:github_rate_limited, %{retry_after_seconds: seconds || 60}}}
  end

  defp fetch_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) -> if String.downcase(k) == name, do: v
      _ -> nil
    end)
  end

  defp fetch_header(headers, name) when is_map(headers) do
    headers[name] || headers[String.upcase(name)] || nil
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      _ -> nil
    end
  end
  defp parse_int(value) when is_integer(value), do: value
  defp parse_int([value | _]), do: parse_int(value)

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 1_000)
  defp truncate(other), do: inspect(other) |> String.slice(0, 1_000)
end
```

- [ ] **Step 4: Run client tests to verify pass**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/client_test.exs
```

Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock \
        lib/symphony_elixir/github/client.ex \
        test/symphony_elixir/github/client_test.exs
git commit -m "$(cat <<'EOF'
feat(elixir): add GitHub GraphQL client with rate-limit + error mapping

SPEC.md §11.2 transport contract. Maps HTTP status and GraphQL error shapes
to the §11.4 categories: tracker_permission_denied (401, 403 w/o Retry-After,
top-level FORBIDDEN/INSUFFICIENT_SCOPES errors), github_rate_limited (429
or 403 + Retry-After), github_api_status (other non-200), github_api_request
(transport), github_graphql_errors (other GraphQL errors), github_unknown_payload.

Honors X-Github-Next-Global-ID: 1 per §11.2 to keep node IDs in the new
global format.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Project resolver + Status field probe

**Spec coverage:** §11.2 project resolution, §11.2.4 Status field probe, error `tracker_status_field_missing`, `tracker_project_not_found`.

**Files:**
- Create: `lib/symphony_elixir/github/project_resolver.ex`
- Create: `test/symphony_elixir/github/project_resolver_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/symphony_elixir/github/project_resolver_test.exs`:

```elixir
defmodule SymphonyElixir.Github.ProjectResolverTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Github.ProjectResolver

  defmodule FakeClient do
    def respond(query_to_response) do
      pid = self()

      fn query, variables, _opts ->
        send(pid, {:graphql, query, variables})

        case Enum.find(query_to_response, fn {pat, _} -> String.contains?(query, pat) end) do
          {_pat, response} -> response
          nil -> {:error, {:github_unknown_payload, "no fake match"}}
        end
      end
    end
  end

  test "resolves by project_id and confirms ProjectV2 typename" do
    fake =
      FakeClient.respond([
        {"node(id:",
         {:ok,
          %{
            "data" => %{
              "node" => %{
                "__typename" => "ProjectV2",
                "id" => "PVT_xxx",
                "title" => "Symphony",
                "number" => 1
              }
            }
          }}}
      ])

    assert {:ok, project} =
             ProjectResolver.resolve(
               %{project_id: "PVT_xxx", project_number: nil, owner: nil, owner_type: "organization"},
               fake
             )

    assert project.id == "PVT_xxx"
    assert project.number == 1
  end

  test "non-ProjectV2 node id raises tracker_project_not_found" do
    fake =
      FakeClient.respond([
        {"node(id:",
         {:ok,
          %{"data" => %{"node" => %{"__typename" => "Issue", "id" => "I_xxx"}}}}}
      ])

    assert {:error, {:tracker_project_not_found, _}} =
             ProjectResolver.resolve(
               %{project_id: "I_xxx", project_number: nil, owner: nil, owner_type: "organization"},
               fake
             )
  end

  test "resolves by owner + project_number when owner_type is organization" do
    fake =
      FakeClient.respond([
        {"organization(login:",
         {:ok,
          %{
            "data" => %{
              "organization" => %{
                "projectV2" => %{"id" => "PVT_yyy", "title" => "Symphony", "number" => 1}
              }
            }
          }}}
      ])

    assert {:ok, project} =
             ProjectResolver.resolve(
               %{project_id: nil, project_number: 1, owner: "archelab", owner_type: "organization"},
               fake
             )

    assert project.id == "PVT_yyy"
  end

  test "null project on owner+number resolution raises tracker_project_not_found" do
    fake =
      FakeClient.respond([
        {"organization(login:",
         {:ok, %{"data" => %{"organization" => %{"projectV2" => nil}}}}}
      ])

    assert {:error, {:tracker_project_not_found, _}} =
             ProjectResolver.resolve(
               %{project_id: nil, project_number: 99, owner: "archelab", owner_type: "organization"},
               fake
             )
  end

  test "probe Status field returns options when SingleSelect" do
    fake =
      FakeClient.respond([
        {"field(name:",
         {:ok,
          %{
            "data" => %{
              "node" => %{
                "field" => %{
                  "__typename" => "ProjectV2SingleSelectField",
                  "id" => "PVTSSF_xxx",
                  "name" => "Status",
                  "options" => [
                    %{"id" => "f75ad846", "name" => "Todo"},
                    %{"id" => "5264dd8c", "name" => "Agent Ready"}
                  ]
                }
              }
            }
          }}}
      ])

    assert {:ok, %{id: "PVTSSF_xxx", options: options}} =
             ProjectResolver.probe_status_field("PVT_xxx", "Status", fake)

    assert {"todo", "f75ad846"} in options
    assert {"agent ready", "5264dd8c"} in options
  end

  test "probe returns tracker_status_field_missing when field is null" do
    fake =
      FakeClient.respond([
        {"field(name:",
         {:ok, %{"data" => %{"node" => %{"field" => nil}}}}}
      ])

    assert {:error, {:tracker_status_field_missing, _}} =
             ProjectResolver.probe_status_field("PVT_xxx", "Status", fake)
  end

  test "probe returns tracker_status_field_missing when field is not SingleSelect" do
    fake =
      FakeClient.respond([
        {"field(name:",
         {:ok,
          %{
            "data" => %{
              "node" => %{
                "field" => %{"__typename" => "ProjectV2Field", "id" => "PVTF_x", "name" => "Status"}
              }
            }
          }}}
      ])

    assert {:error, {:tracker_status_field_missing, _}} =
             ProjectResolver.probe_status_field("PVT_xxx", "Status", fake)
  end
end
```

- [ ] **Step 2: Run, expect failure**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/project_resolver_test.exs
```

Expected: FAIL — module missing.

- [ ] **Step 3: Implement `lib/symphony_elixir/github/project_resolver.ex`**

```elixir
defmodule SymphonyElixir.Github.ProjectResolver do
  @moduledoc """
  Resolve a Project v2 node ID and probe the configured Status field.
  Spec §11.2 / §11.2.4. Caches the resolved ID + Status options for the
  lifetime of the process.
  """

  alias SymphonyElixir.Github.Client

  @resolve_by_id """
  query SymphonyResolveProjectById($id: ID!) {
    node(id: $id) { __typename ... on ProjectV2 { id title number } }
  }
  """

  @resolve_by_org """
  query SymphonyResolveProjectByOrg($owner: String!, $number: Int!) {
    organization(login: $owner) { projectV2(number: $number) { id title number } }
  }
  """

  @resolve_by_user """
  query SymphonyResolveProjectByUser($owner: String!, $number: Int!) {
    user(login: $owner) { projectV2(number: $number) { id title number } }
  }
  """

  @probe_status_field """
  query SymphonyStatusFieldProbe($projectId: ID!, $name: String!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        field(name: $name) {
          __typename
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      }
    }
  }
  """

  @type project :: %{id: String.t(), title: String.t() | nil, number: integer() | nil}

  @spec resolve(map(), function()) :: {:ok, project()} | {:error, {atom(), term()}}
  def resolve(tracker_settings, graphql_fn \\ &Client.graphql/3)

  def resolve(%{project_id: id} = _settings, graphql_fn) when is_binary(id) and id != "" do
    case graphql_fn.(@resolve_by_id, %{"id" => id}, []) do
      {:ok, %{"data" => %{"node" => %{"__typename" => "ProjectV2"} = node}}} ->
        {:ok, %{id: node["id"], title: node["title"], number: node["number"]}}

      {:ok, %{"data" => %{"node" => %{"__typename" => other}}}} ->
        {:error, {:tracker_project_not_found, %{project_id: id, typename: other}}}

      {:ok, %{"data" => %{"node" => nil}}} ->
        {:error, {:tracker_project_not_found, %{project_id: id, typename: nil}}}

      {:ok, _} ->
        {:error, {:tracker_project_not_found, %{project_id: id}}}

      {:error, _} = err ->
        err
    end
  end

  def resolve(
        %{owner: owner, owner_type: "organization", project_number: n},
        graphql_fn
      )
      when is_binary(owner) and is_integer(n) do
    resolve_by_query(@resolve_by_org, %{"owner" => owner, "number" => n}, "organization", graphql_fn, owner)
  end

  def resolve(
        %{owner: owner, owner_type: "user", project_number: n},
        graphql_fn
      )
      when is_binary(owner) and is_integer(n) do
    resolve_by_query(@resolve_by_user, %{"owner" => owner, "number" => n}, "user", graphql_fn, owner)
  end

  def resolve(_settings, _graphql_fn) do
    {:error, {:missing_tracker_project_identifier, "neither project_id nor owner+project_number"}}
  end

  defp resolve_by_query(query, vars, root, graphql_fn, owner) do
    case graphql_fn.(query, vars, []) do
      {:ok, %{"data" => %{^root => %{"projectV2" => %{} = project}}}} ->
        {:ok, %{id: project["id"], title: project["title"], number: project["number"]}}

      {:ok, _} ->
        {:error, {:tracker_project_not_found, %{owner: owner, owner_type: root}}}

      {:error, _} = err ->
        err
    end
  end

  @spec probe_status_field(String.t(), String.t(), function()) ::
          {:ok, %{id: String.t(), name: String.t(), options: [{String.t(), String.t()}]}}
          | {:error, {atom(), term()}}
  def probe_status_field(project_id, field_name, graphql_fn \\ &Client.graphql/3)
      when is_binary(project_id) and is_binary(field_name) do
    case graphql_fn.(@probe_status_field, %{"projectId" => project_id, "name" => field_name}, []) do
      {:ok, %{"data" => %{"node" => %{"field" => %{"__typename" => "ProjectV2SingleSelectField"} = f}}}} ->
        options =
          for o <- f["options"] || [] do
            {String.downcase(o["name"] || ""), o["id"]}
          end

        {:ok, %{id: f["id"], name: f["name"], options: options}}

      {:ok, %{"data" => %{"node" => %{"field" => nil}}}} ->
        {:error, {:tracker_status_field_missing, %{field_name: field_name, project_id: project_id}}}

      {:ok, %{"data" => %{"node" => %{"field" => %{"__typename" => other}}}}} ->
        {:error,
         {:tracker_status_field_missing,
          %{field_name: field_name, project_id: project_id, type: other}}}

      {:ok, _} ->
        {:error, {:github_unknown_payload, "status field probe"}}

      {:error, _} = err ->
        err
    end
  end
end
```

- [ ] **Step 4: Run probe tests, expect pass**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/project_resolver_test.exs
```

Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/github/project_resolver.ex \
        test/symphony_elixir/github/project_resolver_test.exs
git commit -m "$(cat <<'EOF'
feat(elixir): add Project v2 resolver + Status field probe

SPEC.md §11.2 (project resolution by id or owner+number, owner_type
selection between organization and user) and §11.2.4 (Status field probe
that distinguishes "field unset on item" from "field missing on project").

Returns {:error, {:tracker_project_not_found, _}} on null projectV2 or
non-ProjectV2 node, and {:error, {:tracker_status_field_missing, _}} when
the field is absent or not a single-select. Caller is expected to cache
the resolved IDs for the process lifetime.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Normalization + GitHub adapter (candidate fetch + state refresh + terminal-OR + rate-limit gate)

**Spec coverage:** §11.1 (REQUIRED ops), §11.2.1 (terminal-OR rule), §11.2.2 (candidate query), §11.2.3 (refresh query), §11.3 (normalization rules), §11.4 (rate-limit gating MUST), §11.5 (no orchestrator writes).

> **Commit boundary — REQUIRED, not recommended:** This task spans the PR1/PR2 seam. Commit 5a (PR1 commit 6) contains `Github.Normalize`, fixtures, normalization tests, `Github.Adapter`, adapter unit tests, `RateLimitGate`, and the env-gated live test. Commit 5b (PR2 commit 7) is the `tracker.ex` rewrite alone — see Step 11.5 below. The Tracker behaviour change is a public boundary and MUST be its own commit on the PR2 branch; staging it with PR1 work breaks the PR strategy.

> **Phase 2 forward-compatibility:** the candidate query MUST be expressed as composable module attributes — `@issue_fragment`, `@pr_fragment_tier1`, `@draft_fragment` — concatenated into `@candidate_query`. Phase 2 adds `@pr_fragment_tier2` (review_decision, mergeable, mergeStateStatus, statusCheckRollup, latestOpinionatedReviews, reviewThreads, reviewRequests) as a single +diff without rewriting the surrounding query.

> **Priority normalization is deferred to Phase 2.** Phase 1 emits `priority: nil` for every item and does not query the configured `priority_field`. SPEC.md §11.3's priority rule is documented in `Github.Normalize.priority/2` as a `# Phase 2` comment with the exact branch table (single-select via mapping / number / text-as-int / label-fallback). This keeps the Phase 1 selection set minimal.

**Files:**
- Create: `lib/symphony_elixir/github/normalize.ex`
- Create: `lib/symphony_elixir/github/adapter.ex`
- Create: `lib/symphony_elixir/github/rate_limit_gate.ex`
- Create: `test/symphony_elixir/github/normalize_test.exs`
- Create: `test/symphony_elixir/github/adapter_test.exs`
- Create: `test/symphony_elixir/github/rate_limit_gate_test.exs`
- Create: `test/fixtures/github/items_page.json` (canned candidate query response)
- Modify: `lib/symphony_elixir/tracker.ex` (drop write callbacks, route GitHub kind)

- [ ] **Step 1: Capture a representative candidate-query payload as fixture**

Hand-author `test/fixtures/github/items_page.json` covering: an open Issue in "Agent Ready", a merged PR (so terminal-OR removes it), a draft PR, an archived item (filtered), a `<no status>` item, a redacted item, an issue with one open and one closed `trackedIssues` entry. Use this exact shape so tests can pin every spec branch:

```json
{
  "data": {
    "rateLimit": {"remaining": 4990, "resetAt": "2026-05-10T13:00:00Z"},
    "node": {
      "id": "PVT_kwDODDTPxM4BXSCK",
      "title": "Symphony",
      "number": 1,
      "items": {
        "pageInfo": {"hasNextPage": false, "endCursor": null},
        "nodes": [
          {
            "id": "PVTI_iss1",
            "type": "ISSUE",
            "isArchived": false,
            "createdAt": "2026-05-01T00:00:00Z",
            "updatedAt": "2026-05-01T00:00:00Z",
            "fieldValueByName": {"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": "Agent Ready", "optionId": "5264dd8c"},
            "content": {
              "__typename": "Issue",
              "id": "I_iss1", "number": 42, "title": "Refactor", "body": "do it",
              "url": "https://github.com/archelab/symphony/issues/42",
              "state": "OPEN", "createdAt": "2026-05-01T00:00:00Z", "updatedAt": "2026-05-01T00:00:00Z",
              "repository": {"nameWithOwner": "archelab/symphony", "owner": {"login": "archelab"}, "name": "symphony", "defaultBranchRef": {"name": "main"}},
              "labels": {"nodes": [{"name": "Bug"}, {"name": "P1"}]},
              "trackedIssues": {"nodes": [
                {"id": "I_b1", "number": 7, "state": "CLOSED", "repository": {"nameWithOwner": "archelab/symphony"}},
                {"id": "I_b2", "number": 8, "state": "OPEN", "repository": {"nameWithOwner": "archelab/symphony"}}
              ]}
            }
          },
          {
            "id": "PVTI_pr_merged",
            "type": "PULL_REQUEST",
            "isArchived": false,
            "fieldValueByName": {"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": "In Progress", "optionId": "47fc9ee4"},
            "content": {
              "__typename": "PullRequest",
              "id": "PR_m", "number": 3, "title": "Old PR", "body": "",
              "url": "https://github.com/archelab/symphony/pull/3",
              "state": "MERGED", "merged": true, "mergedAt": "2026-04-30T00:00:00Z", "closedAt": "2026-04-30T00:00:00Z",
              "isDraft": false, "headRefName": "old-branch", "baseRefName": "main",
              "repository": {"nameWithOwner": "archelab/symphony", "owner": {"login": "archelab"}, "name": "symphony", "defaultBranchRef": {"name": "main"}},
              "labels": {"nodes": []}
            }
          },
          {
            "id": "PVTI_archived",
            "type": "ISSUE",
            "isArchived": true,
            "fieldValueByName": {"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": "Agent Ready"},
            "content": {"__typename": "Issue", "id": "I_archived", "number": 100, "title": "Archived", "state": "OPEN",
                        "repository": {"nameWithOwner": "archelab/symphony", "owner": {"login": "archelab"}, "name": "symphony", "defaultBranchRef": {"name": "main"}},
                        "labels": {"nodes": []}, "trackedIssues": {"nodes": []}}
          },
          {
            "id": "PVTI_no_status",
            "type": "ISSUE",
            "isArchived": false,
            "fieldValueByName": null,
            "content": {"__typename": "Issue", "id": "I_ns", "number": 200, "title": "No Status", "state": "OPEN",
                        "repository": {"nameWithOwner": "archelab/symphony", "owner": {"login": "archelab"}, "name": "symphony", "defaultBranchRef": {"name": "main"}},
                        "labels": {"nodes": []}, "trackedIssues": {"nodes": []}}
          },
          {
            "id": "PVTI_redacted",
            "type": "REDACTED",
            "isArchived": false,
            "content": null
          },
          {
            "id": "PVTI_draft1",
            "type": "DRAFT_ISSUE",
            "isArchived": false,
            "fieldValueByName": {"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": "Agent Ready"},
            "content": {"__typename": "DraftIssue", "id": "DI_AF6gQ123abcdef", "title": "Idea", "body": "rough", "createdAt": "2026-05-01T00:00:00Z", "updatedAt": "2026-05-01T00:00:00Z"}
          }
        ]
      }
    }
  }
}
```

- [ ] **Step 2: Write failing normalization test**

Create `test/symphony_elixir/github/normalize_test.exs`:

```elixir
defmodule SymphonyElixir.Github.NormalizeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Github.{Issue, Normalize}

  setup do
    payload = "test/fixtures/github/items_page.json" |> File.read!() |> Jason.decode!()
    items = get_in(payload, ["data", "node", "items", "nodes"])
    {:ok, items: items}
  end

  test "normalizes an issue with mixed-state blockers", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_iss1"))

    assert {:ok, %Issue{} = issue} = Normalize.item(item, status_field: "Status")
    assert issue.id == "PVTI_iss1"
    assert issue.identifier == "archelab/symphony#42"
    assert issue.kind == "issue"
    assert issue.state == "Agent Ready"
    assert issue.labels == ["bug", "p1"]
    assert issue.repository.name_with_owner == "archelab/symphony"
    assert issue.repository.default_branch == "main"
    assert issue.number == 42
    assert issue.url == "https://github.com/archelab/symphony/issues/42"
    assert issue.issue_state == "OPEN"

    assert [closed, open] = issue.blocked_by
    assert closed.identifier == "archelab/symphony#7"
    assert closed.state == "CLOSED"
    assert open.identifier == "archelab/symphony#8"
    assert open.state == "OPEN"
  end

  test "normalizes a merged PR with Tier 1 fields", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_pr_merged"))

    assert {:ok, %Issue{kind: "pull_request"} = issue} = Normalize.item(item, status_field: "Status")
    assert issue.identifier == "archelab/symphony#3"
    assert issue.branch_name == "old-branch"
    assert issue.pr.state == "MERGED"
    assert issue.pr.merged == true
    assert issue.pr.is_draft == false
    assert issue.pr.base_ref_name == "main"
    assert issue.issue_state == "MERGED"
  end

  test "filters archived item", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_archived"))
    assert {:skip, :archived} = Normalize.item(item, status_field: "Status")
  end

  test "filters REDACTED item", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_redacted"))
    assert {:skip, :redacted} = Normalize.item(item, status_field: "Status")
  end

  test "no-status item gets <no status> sentinel", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_no_status"))
    assert {:ok, %Issue{state: "<no status>"}} = Normalize.item(item, status_field: "Status")
  end

  test "draft_issue identifier uses last 8 chars of node id", %{items: items} do
    item = Enum.find(items, &(&1["id"] == "PVTI_draft1"))
    assert {:ok, %Issue{kind: "draft_issue", identifier: "draft:" <> short} = issue} =
             Normalize.item(item, status_field: "Status")

    assert String.length(short) == 8
    assert issue.repository == nil
    assert issue.url == nil
  end
end
```

- [ ] **Step 3: Run, expect failure**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/normalize_test.exs
```

Expected: FAIL — `Normalize` module missing.

- [ ] **Step 4: Implement `lib/symphony_elixir/github/normalize.ex`**

```elixir
defmodule SymphonyElixir.Github.Normalize do
  @moduledoc """
  Convert raw GitHub GraphQL item nodes into the SPEC.md §4.1.1 Issue
  domain model. Also see §11.3 normalization rules.
  """

  alias SymphonyElixir.Github.Issue

  @no_status "<no status>"

  @spec item(map(), keyword()) :: {:ok, Issue.t()} | {:skip, atom()}
  def item(%{"isArchived" => true}, _opts), do: {:skip, :archived}
  def item(%{"type" => "REDACTED"}, _opts), do: {:skip, :redacted}
  def item(%{"content" => nil}, _opts), do: {:skip, :no_content}

  def item(%{"type" => type, "id" => item_id, "content" => content} = item, opts) do
    kind = type_to_kind(type)
    state = effective_state(item)
    repository = build_repository(content["repository"])

    {identifier, number, url} = identifier_for(kind, item_id, content, repository)

    issue =
      Issue.new(%{
        id: item_id,
        identifier: identifier,
        kind: kind,
        title: content["title"] || "",
        description: content["body"],
        priority: nil,
        state: state,
        repository: repository,
        number: number,
        branch_name: branch_name(kind, content),
        url: url,
        labels: labels(content),
        blocked_by: blockers(kind, content),
        pr: pr(kind, content),
        issue_state: issue_state(kind, content),
        created_at: content["createdAt"],
        updated_at: content["updatedAt"]
      })

    _ = opts
    {:ok, issue}
  end

  defp type_to_kind("ISSUE"), do: "issue"
  defp type_to_kind("PULL_REQUEST"), do: "pull_request"
  defp type_to_kind("DRAFT_ISSUE"), do: "draft_issue"

  defp effective_state(%{"fieldValueByName" => %{"name" => name}}) when is_binary(name), do: name
  defp effective_state(_), do: @no_status

  defp build_repository(nil), do: nil
  defp build_repository(%{"nameWithOwner" => nwo, "owner" => %{"login" => login}, "name" => name} = repo) do
    %Issue.Repository{
      owner: login,
      name: name,
      name_with_owner: nwo,
      default_branch: get_in(repo, ["defaultBranchRef", "name"])
    }
  end
  defp build_repository(%{"nameWithOwner" => nwo} = repo) do
    [owner, name] = String.split(nwo, "/", parts: 2)
    %Issue.Repository{
      owner: owner,
      name: name,
      name_with_owner: nwo,
      default_branch: get_in(repo, ["defaultBranchRef", "name"])
    }
  end

  defp identifier_for("draft_issue", item_id, _content, _repo) do
    short = String.slice(item_id, -8, 8)
    {"draft:" <> short, nil, nil}
  end

  defp identifier_for(_kind, _item_id, content, %Issue.Repository{name_with_owner: nwo}) do
    number = content["number"]
    {nwo <> "#" <> Integer.to_string(number), number, content["url"]}
  end

  defp identifier_for(_kind, item_id, content, nil) do
    {"unknown:" <> item_id, content["number"], content["url"]}
  end

  defp branch_name("pull_request", %{"headRefName" => name}) when is_binary(name), do: name
  defp branch_name(_kind, _content), do: nil

  defp labels(%{"labels" => %{"nodes" => nodes}}) when is_list(nodes) do
    for %{"name" => name} <- nodes, is_binary(name), do: String.downcase(name)
  end
  defp labels(_), do: []

  defp blockers("issue", %{"trackedIssues" => %{"nodes" => nodes}}) when is_list(nodes) do
    for %{"id" => id, "number" => n, "state" => state, "repository" => %{"nameWithOwner" => nwo}} <- nodes do
      %Issue.Blocker{
        id: id,
        identifier: nwo <> "#" <> Integer.to_string(n),
        state: state
      }
    end
  end
  defp blockers(_kind, _content), do: []

  defp pr("pull_request", c) do
    %Issue.PR{
      state: c["state"],
      merged: c["merged"] == true,
      merged_at: c["mergedAt"],
      closed_at: c["closedAt"],
      is_draft: c["isDraft"] == true,
      base_ref_name: c["baseRefName"]
    }
  end
  defp pr(_kind, _c), do: nil

  defp issue_state("issue", %{"state" => state}), do: state
  defp issue_state("pull_request", %{"state" => state}), do: state
  defp issue_state(_, _), do: nil
end
```

- [ ] **Step 5: Run normalization tests, expect pass**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/normalize_test.exs
```

Expected: PASS (6 tests).

- [ ] **Step 6: Write failing adapter test (terminal-OR + filters)**

Create `test/symphony_elixir/github/adapter_test.exs`. Stub the resolver + Client via `Application.put_env`:

```elixir
defmodule SymphonyElixir.Github.AdapterTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Github.{Adapter, Issue}

  defmodule FakeClient do
    def respond(payloads) do
      pid = self()

      fn query, vars, _opts ->
        send(pid, {:graphql, query, vars})

        case Enum.find(payloads, fn {pat, _} -> String.contains?(query, pat) end) do
          {_pat, response} -> response
          nil -> {:error, {:github_unknown_payload, "no fake match"}}
        end
      end
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Agent Ready", "In Progress", "Rework"],
      tracker_terminal_states: ["Done"],
      tracker_include_kinds: ["issue", "pull_request"]
    )

    payload = "test/fixtures/github/items_page.json" |> File.read!() |> Jason.decode!()
    project_resolved = {:ok, %{id: "PVT_kwDODDTPxM4BXSCK", title: "Symphony", number: 1}}
    status_probed =
      {:ok,
       %{
         id: "PVTSSF_x",
         name: "Status",
         options: [
           {"todo", "f75ad846"},
           {"agent ready", "5264dd8c"},
           {"in progress", "47fc9ee4"},
           {"in review", "593a70e3"},
           {"rework", "a3ea437a"},
           {"blocked", "9bb46c25"},
           {"done", "98236657"}
         ]
       }}

    fake =
      FakeClient.respond([
        {"SymphonyResolveProjectByOrg", project_resolved |> wrap_resolve()},
        {"SymphonyStatusFieldProbe", status_probed |> wrap_probe()},
        {"SymphonyProjectItems", {:ok, payload}}
      ])

    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    :ok
  end

  defp wrap_resolve({:ok, p}),
    do: {:ok, %{"data" => %{"organization" => %{"projectV2" => %{"id" => p.id, "title" => p.title, "number" => p.number}}}}}

  defp wrap_probe({:ok, p}),
    do: {:ok,
         %{
           "data" => %{
             "node" => %{
               "field" => %{
                 "__typename" => "ProjectV2SingleSelectField",
                 "id" => p.id,
                 "name" => p.name,
                 "options" => Enum.map(p.options, fn {n, id} -> %{"id" => id, "name" => String.capitalize(n)} end)
               }
             }
           }
         }}

  test "fetch_candidate_issues filters terminal-OR (merged PR), archived, REDACTED, <no status>" do
    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    ids = Enum.map(issues, & &1.id)

    # Issue PVTI_iss1 (Agent Ready) and PVTI_draft1 (Agent Ready, draft) — but include_kinds excludes draft_issue
    assert "PVTI_iss1" in ids
    refute "PVTI_pr_merged" in ids   # terminal-OR (merged)
    refute "PVTI_archived" in ids    # archived
    refute "PVTI_redacted" in ids    # redacted
    refute "PVTI_no_status" in ids   # <no status> => not active
    refute "PVTI_draft1" in ids      # excluded by include_kinds default
  end
end
```

- [ ] **Step 7: Run, expect failure**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/adapter_test.exs
```

Expected: FAIL — `Adapter` module missing.

- [ ] **Step 8: Implement `lib/symphony_elixir/github/adapter.ex`**

```elixir
defmodule SymphonyElixir.Github.Adapter do
  @moduledoc """
  Implements the Tracker behaviour for GitHub Projects v2.
  Spec §11.1 / §11.2 / §11.3.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Github.{Client, Normalize, ProjectResolver}

  # Composable fragments — Phase 2 adds @pr_fragment_tier2 by concatenation
  # without rewriting the surrounding query. Spec §11.7 expansion.
  @issue_fragment """
  ... on Issue {
    id number title body url state createdAt updatedAt
    repository {
      nameWithOwner owner { login } name
      defaultBranchRef { name }
    }
    labels(first: 50) { nodes { name } }
    trackedIssues(first: 50) {
      nodes { id number state repository { nameWithOwner } }
    }
  }
  """

  @pr_fragment_tier1 """
  ... on PullRequest {
    id number title body url state merged mergedAt closedAt isDraft headRefName baseRefName createdAt updatedAt
    repository {
      nameWithOwner owner { login } name
      defaultBranchRef { name }
    }
    labels(first: 50) { nodes { name } }
  }
  """

  @draft_fragment """
  ... on DraftIssue {
    id title body createdAt updatedAt
  }
  """

  @candidate_query """
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
              #{@issue_fragment}
              #{@pr_fragment_tier1}
              #{@draft_fragment}
            }
          }
        }
      }
    }
  }
  """

  @refresh_query """
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
  """

  @page_size 100

  @impl true
  def fetch_candidate_issues do
    with {:ok, _project} <- ensure_resolved(),
         {:ok, items} <- paginate_items() do
      tracker = Config.settings!().tracker
      active = Enum.map(tracker.active_states, &String.downcase/1)
      terminal = Enum.map(tracker.terminal_states, &String.downcase/1)

      issues =
        items
        |> Stream.map(&Normalize.item(&1, status_field: tracker.status_field))
        |> Stream.flat_map(fn
          {:ok, issue} -> [issue]
          {:skip, _} -> []
        end)
        |> Stream.filter(&keep_kind?(&1, tracker.include_kinds))
        |> Stream.filter(&keep_repo?(&1, tracker.repo, tracker.owner))
        |> Stream.filter(&active?(&1, active, terminal))
        |> Enum.to_list()

      {:ok, issues}
    end
  end

  @impl true
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, _project} <- ensure_resolved(),
         {:ok, items} <- paginate_items() do
      tracker = Config.settings!().tracker
      wanted = Enum.map(state_names, &String.downcase/1)

      issues =
        items
        |> Stream.map(&Normalize.item(&1, status_field: tracker.status_field))
        |> Stream.flat_map(fn
          {:ok, issue} -> [issue]
          {:skip, _} -> []
        end)
        |> Stream.filter(&keep_kind?(&1, tracker.include_kinds))
        |> Stream.filter(&keep_repo?(&1, tracker.repo, tracker.owner))
        |> Stream.filter(fn issue -> String.downcase(issue.state) in wanted end)
        |> Enum.to_list()

      {:ok, issues}
    end
  end

  @impl true
  def fetch_issue_states_by_ids([]), do: {:ok, []}

  def fetch_issue_states_by_ids(ids) when is_list(ids) do
    case graphql(@refresh_query, %{"ids" => ids}) do
      {:ok, %{"data" => %{"nodes" => nodes}}} ->
        result =
          for node <- nodes,
              is_map(node),
              node["__typename"] == "ProjectV2Item",
              node["type"] != "REDACTED",
              node["isArchived"] != true do
            state = get_in(node, ["fieldValueByName", "name"]) || "<no status>"

            %{
              id: node["id"],
              identifier: identifier_from_refresh(node),
              state: terminal_or_state(node, state)
            }
          end

        {:ok, result}

      {:error, _} = err ->
        err
    end
  end

  defp identifier_from_refresh(%{"content" => %{"__typename" => "Issue", "number" => n, "repository" => %{"nameWithOwner" => nwo}}}),
    do: "#{nwo}##{n}"

  defp identifier_from_refresh(%{
         "content" => %{"__typename" => "PullRequest", "number" => n, "repository" => %{"nameWithOwner" => nwo}}
       }),
       do: "#{nwo}##{n}"

  defp identifier_from_refresh(%{"content" => %{"__typename" => "DraftIssue", "id" => id}}),
    do: "draft:" <> String.slice(id, -8, 8)

  defp identifier_from_refresh(%{"id" => id}), do: "unknown:" <> id

  defp terminal_or_state(%{"content" => %{"__typename" => "Issue", "state" => "CLOSED"}}, _), do: "<closed>"
  defp terminal_or_state(%{"content" => %{"__typename" => "PullRequest", "state" => state}}, _) when state in ["CLOSED", "MERGED"], do: "<#{String.downcase(state)}>"
  defp terminal_or_state(_node, state), do: state

  defp paginate_items, do: paginate_items(nil, [])

  defp paginate_items(after_cursor, acc) do
    project_id = ensure_resolved!() |> Map.fetch!(:id)

    case graphql(@candidate_query, %{"projectId" => project_id, "first" => @page_size, "after" => after_cursor}) do
      {:ok, %{"data" => %{"node" => %{"items" => %{"pageInfo" => page_info, "nodes" => nodes}}}}} ->
        new_acc = acc ++ (nodes || [])
        cond do
          page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) ->
            paginate_items(page_info["endCursor"], new_acc)
          page_info["hasNextPage"] == true ->
            {:error, {:github_missing_end_cursor, %{}}}
          true ->
            {:ok, new_acc}
        end

      {:ok, _} ->
        {:error, {:github_unknown_payload, "candidate items"}}

      {:error, _} = err ->
        err
    end
  end

  defp keep_kind?(%{kind: kind}, include_kinds) when is_list(include_kinds), do: kind in include_kinds

  defp keep_repo?(%{kind: "draft_issue"}, _repo, _owner), do: true
  defp keep_repo?(_, repo, _owner) when repo in [nil, ""], do: true
  defp keep_repo?(%{repository: nil}, _repo, _owner), do: false

  defp keep_repo?(%{repository: %{owner: r_owner, name: r_name}}, repo_filter, owner_filter) do
    case String.split(repo_filter, "/", parts: 2) do
      [bare_name] ->
        # Short form: "<repo>". Requires owner match against tracker.owner.
        is_binary(owner_filter) and
          String.downcase(r_owner) == String.downcase(owner_filter) and
          r_name == bare_name

      [filter_owner, filter_name] ->
        # Cross-owner long form: "<owner>/<repo>".
        String.downcase(r_owner) == String.downcase(filter_owner) and r_name == filter_name

      _ ->
        false
    end
  end

  defp active?(%{kind: "draft_issue"} = issue, active_states, terminal_states) do
    state_lc = String.downcase(issue.state)
    state_lc != "<no status>" and state_lc in active_states and state_lc not in terminal_states
  end

  defp active?(issue, active_states, terminal_states) do
    state_lc = String.downcase(issue.state)
    cond do
      state_lc == "<no status>" -> false
      state_lc in terminal_states -> false
      issue.issue_state in ["CLOSED", "MERGED"] -> false
      state_lc in active_states -> true
      true -> false
    end
  end

  defp ensure_resolved! do
    {:ok, project} = ensure_resolved()
    project
  end

  defp ensure_resolved do
    tracker = Config.settings!().tracker
    cache_key = config_cache_key(tracker)

    case :persistent_term.get({__MODULE__, :resolved}, :unset) do
      {^cache_key, project, _status} ->
        {:ok, project}

      _ ->
        with {:ok, project} <- ProjectResolver.resolve(tracker, &graphql/3),
             {:ok, status} <-
               ProjectResolver.probe_status_field(project.id, tracker.status_field, &graphql/3) do
          :persistent_term.put({__MODULE__, :resolved}, {cache_key, project, status})
          {:ok, project}
        end
    end
  end

  # Cache key changes when any tracker setting that affects resolution changes,
  # so a WORKFLOW.md reload that points at a new project transparently
  # invalidates the cache. Spec §11.2 says the resolved ID SHOULD be cached
  # for the lifetime of the process — but only while the underlying config is
  # unchanged.
  defp config_cache_key(tracker) do
    {tracker.endpoint, tracker.api_token, tracker.owner, tracker.owner_type,
     tracker.project_id, tracker.project_number, tracker.status_field}
  end

  @doc false
  @spec invalidate_cache() :: :ok
  def invalidate_cache, do: :persistent_term.erase({__MODULE__, :resolved}) |> then(fn _ -> :ok end)

  defp graphql(query, variables, opts \\ []) do
    fun = Application.get_env(:symphony_elixir, :github_client, &Client.graphql/3)
    tracker = Config.settings!().tracker

    fun.(query, variables, Keyword.merge([endpoint: tracker.endpoint, token: tracker.api_token], opts))
  end
end
```

- [ ] **Step 8a: Wire `Adapter.invalidate_cache/0` into workflow reload + add regression test**

The `config_cache_key/1` invariant guarantees the cache rebuilds when any tracker setting changes, but the Linear-era code lazily reads `Config.settings!()`. To make reload-driven invalidation observable, hook the explicit invalidation call into `WorkflowStore.force_reload/0`.

Grep target: `grep -n "def force_reload\|def handle_call\|notify_subscribers" lib/symphony_elixir/workflow_store.ex`. The hook lands at the bottom of `force_reload/0` after the new workflow is written into ETS / state, before the function returns. If `notify_subscribers/1` (or equivalent) already exists, attach the call there instead — it's already the documented seam for post-reload side effects.

Concretely add:

```elixir
defp after_reload(_old, _new) do
  if Code.ensure_loaded?(SymphonyElixir.Github.Adapter) do
    SymphonyElixir.Github.Adapter.invalidate_cache()
  end

  :ok
end
```

The `Code.ensure_loaded?/1` guard keeps tests that don't load the GitHub adapter green.

Add to `test/symphony_elixir/github/adapter_test.exs`:

```elixir
test "workflow reload re-resolves the project (cache invalidation)" do
  resolve_calls = :counters.new(1, [:atomics])

  fake =
    fn query, vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          :counters.add(resolve_calls, 1, 1)
          number = vars["number"]
          {:ok,
           %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_#{number}", "title" => "x", "number" => number}}}}}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok,
           %{"data" => %{"node" => %{"field" => %{"__typename" => "ProjectV2SingleSelectField", "id" => "PVTSSF_x", "name" => "Status", "options" => []}}}}}

        true ->
          {:ok, %{"data" => %{"node" => %{"id" => "x", "title" => "x", "number" => 1, "items" => %{"pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}, "nodes" => []}}}}}
      end
    end

  Application.put_env(:symphony_elixir, :github_client, fake)
  on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

  write_workflow_file!(Workflow.workflow_file_path(), tracker_project_number: 1)
  {:ok, _} = Adapter.fetch_candidate_issues()

  write_workflow_file!(Workflow.workflow_file_path(), tracker_project_number: 2)
  {:ok, _} = Adapter.fetch_candidate_issues()

  assert :counters.get(resolve_calls, 1) == 2
end
```

Run:

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/adapter_test.exs
```

Expected: PASS.

- [ ] **Step 8b: Add `RateLimitGate` and wire it into the adapter (BLOCKER per spec §11.4)**

Spec §11.4 mandates that on `github_rate_limited` the implementation MUST delay the next tracker call by at least `Retry-After` seconds (secondary), and SHOULD delay until `rateLimit.resetAt` (primary). Without this gate the orchestrator's next tick re-hits GitHub immediately and burns credits. When both signals fire, prefer the longer wait (§11.2 "prefer the longer of the two waits").

Create `lib/symphony_elixir/github/rate_limit_gate.ex`:

```elixir
defmodule SymphonyElixir.Github.RateLimitGate do
  @moduledoc """
  In-process gate that records GitHub rate-limit signals and short-circuits
  subsequent calls until the gate clears. Spec §11.2 / §11.4.
  """

  @key {__MODULE__, :until_ms}

  @spec record_secondary(non_neg_integer()) :: :ok
  def record_secondary(retry_after_seconds) when is_integer(retry_after_seconds) do
    until = System.monotonic_time(:millisecond) + retry_after_seconds * 1_000
    update_gate(until)
  end

  @spec record_primary(String.t() | nil) :: :ok
  def record_primary(nil), do: :ok
  def record_primary(reset_at_iso) when is_binary(reset_at_iso) do
    case DateTime.from_iso8601(reset_at_iso) do
      {:ok, dt, _} ->
        delta_ms = max(0, DateTime.diff(dt, DateTime.utc_now(), :millisecond))
        until = System.monotonic_time(:millisecond) + delta_ms
        update_gate(until)

      _ ->
        :ok
    end
  end

  @spec gated?() :: {:gated, non_neg_integer()} | :open
  def gated? do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@key, 0) do
      until when until > now -> {:gated, until - now}
      _ -> :open
    end
  end

  @spec clear() :: :ok
  def clear, do: :persistent_term.put(@key, 0)

  defp update_gate(until) do
    current = :persistent_term.get(@key, 0)
    :persistent_term.put(@key, max(current, until))
    :ok
  end
end
```

Wrap the adapter's `graphql/3` to consult the gate first:

```elixir
defp graphql(query, variables, opts \\ []) do
  case SymphonyElixir.Github.RateLimitGate.gated?() do
    {:gated, ms_remaining} ->
      {:error, {:github_rate_limited, %{retry_after_seconds: div(ms_remaining, 1_000) + 1}}}

    :open ->
      fun = Application.get_env(:symphony_elixir, :github_client, &Client.graphql/3)
      tracker = Config.settings!().tracker
      result = fun.(query, variables, Keyword.merge([endpoint: tracker.endpoint, token: tracker.api_token], opts))

      case result do
        {:error, {:github_rate_limited, %{retry_after_seconds: n}}} ->
          SymphonyElixir.Github.RateLimitGate.record_secondary(n)
          result

        {:ok, %{"data" => %{"rateLimit" => %{"remaining" => 0, "resetAt" => reset_at}}}} ->
          SymphonyElixir.Github.RateLimitGate.record_primary(reset_at)
          result

        _ ->
          result
      end
  end
end
```

Tests in `test/symphony_elixir/github/rate_limit_gate_test.exs`:

```elixir
defmodule SymphonyElixir.Github.RateLimitGateTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Github.RateLimitGate

  setup do
    RateLimitGate.clear()
    on_exit(&RateLimitGate.clear/0)
    :ok
  end

  test "secondary signal gates subsequent reads" do
    :ok = RateLimitGate.record_secondary(60)
    assert {:gated, ms} = RateLimitGate.gated?()
    assert ms > 50_000 and ms <= 60_000
  end

  test "primary signal gates until resetAt" do
    future = DateTime.utc_now() |> DateTime.add(30, :second) |> DateTime.to_iso8601()
    :ok = RateLimitGate.record_primary(future)
    assert {:gated, _} = RateLimitGate.gated?()
  end

  test "longer of two signals wins (max gate)" do
    :ok = RateLimitGate.record_secondary(10)
    far_future = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601()
    :ok = RateLimitGate.record_primary(far_future)
    assert {:gated, ms} = RateLimitGate.gated?()
    assert ms > 200_000
  end

  test "clear resets gate" do
    :ok = RateLimitGate.record_secondary(60)
    RateLimitGate.clear()
    assert :open = RateLimitGate.gated?()
  end
end
```

Run:

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/rate_limit_gate_test.exs
```

Expected: PASS (4 tests).

- [ ] **Step 9: Update `lib/symphony_elixir/tracker.ex` — drop write callbacks, route GitHub kind**

> **PR1 vs PR2 boundary:** This step is the **first commit of PR2** (commit 7 overall). PR1 leaves `tracker.ex` untouched so Linear keeps working. The change here flips routing in one shot — afterwards `tracker.kind == "linear"` will route to a Linear adapter that's about to be deleted in commit 11 (Task 8b), so the routing window is short. If you find yourself here in PR1, stop — back this commit out and keep PR1 additive.

Replace the contents of `lib/symphony_elixir/tracker.ex` with:

```elixir
defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads. Per spec §11.5 the orchestrator
  performs no writes; comments and Status updates are agent-driven via the
  github_graphql Codex tool.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: adapter().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: adapter().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: adapter().fetch_issue_states_by_ids(issue_ids)

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      "github" -> SymphonyElixir.Github.Adapter
    end
  end
end
```

- [ ] **Step 10: Run adapter test**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/github/adapter_test.exs
```

Expected: PASS. Other tests still failing — that's the orchestrator predicate work in Task 6.

- [ ] **Step 10a: Add the env-gated live integration test (Task 5a/PR1)**

This file was previously planned for Task 8 (PR2). It moves into PR1 so the implementer validates the adapter against real GitHub data WHILE building it — catching schema drift, rate-limit reality, and node-ID shape assumptions before the cutover. The test is tagged `:live_github` and skips when `GITHUB_TOKEN` is unset, so CI stays green without a token.

Create `test/symphony_elixir/github_live_test.exs`:

```elixir
defmodule SymphonyElixir.GithubLiveTest do
  @moduledoc """
  Real-integration profile (spec §17.8). Polls archelab/symphony Project #1.
  Skipped unless GITHUB_TOKEN is set. Implementer should run this locally
  during PR1 development: `GITHUB_TOKEN=... mix test --only live_github`.
  """
  use SymphonyElixir.TestSupport
  @moduletag :live_github

  alias SymphonyElixir.Github.Adapter

  setup do
    token = System.get_env("GITHUB_TOKEN")
    if token == nil, do: ExUnit.skip("GITHUB_TOKEN not set")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: token,
      tracker_owner: "archelab",
      tracker_owner_type: "organization",
      tracker_project_number: 1,
      tracker_repo: "symphony",
      tracker_active_states: ["Agent Ready", "In Progress", "Rework"],
      tracker_terminal_states: ["Done"]
    )

    Application.delete_env(:symphony_elixir, :github_client)
    # Step 8 caches the resolved project under {Adapter, :resolved}.
    Adapter.invalidate_cache()

    :ok
  end

  test "fetch_candidate_issues hits real GitHub and returns a list" do
    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    assert is_list(issues)

    Enum.each(issues, fn issue ->
      assert issue.id =~ "PVTI_"
      assert issue.kind in ["issue", "pull_request"]
      assert issue.repository.name_with_owner == "archelab/symphony"
      assert issue.repository.default_branch == "main"
    end)
  end

  test "fetch_issue_states_by_ids round-trips a real ID" do
    {:ok, issues} = Adapter.fetch_candidate_issues()

    case issues do
      [%{id: id} | _] ->
        assert {:ok, [%{id: ^id, state: state}]} =
                 Adapter.fetch_issue_states_by_ids([id])

        assert is_binary(state) or state in ["<no status>", "<closed>", "<merged>"]

      [] ->
        assert {:ok, []} = Adapter.fetch_issue_states_by_ids([])
    end
  end

  test "Status field probe resolves seven options matching the project board" do
    {:ok, _issues} = Adapter.fetch_candidate_issues()

    # Step 8 stores the resolved cache as {cache_key, project, status} under
    # the {Adapter, :resolved} key. Pull the status map out of that tuple.
    {_cache_key, _project, %{options: options}} =
      :persistent_term.get({SymphonyElixir.Github.Adapter, :resolved})

    names = Enum.map(options, fn {name, _id} -> name end)

    for expected <- ["todo", "agent ready", "in progress", "in review",
                     "rework", "blocked", "done"] do
      assert expected in names, "Status option #{inspect(expected)} missing from project"
    end
  end
end
```

Run locally during development:

```bash
GITHUB_TOKEN=$(gh auth token) mise exec -- mix test --only live_github
```

Expected: 3 tests pass against `archelab/symphony` Project #1. The implementer SHOULD run this after every meaningful change to `Github.Adapter` or `Github.Normalize` — when a real-GitHub assertion fails, the unit-test fake was wrong, not the adapter.

- [ ] **Step 11: Commit**

```bash
git add lib/symphony_elixir/github/normalize.ex \
        lib/symphony_elixir/github/adapter.ex \
        lib/symphony_elixir/github/rate_limit_gate.ex \
        lib/symphony_elixir/workflow_store.ex \
        test/symphony_elixir/github/normalize_test.exs \
        test/symphony_elixir/github/adapter_test.exs \
        test/symphony_elixir/github/rate_limit_gate_test.exs \
        test/symphony_elixir/github_live_test.exs \
        test/fixtures/github/items_page.json

# DO NOT stage lib/symphony_elixir/tracker.ex here. The Tracker behaviour
# rewrite is PR2 commit 7 (Step 11.5 below). PR1 leaves tracker.ex
# untouched so Linear keeps routing via the existing catch-all.

git commit -m "$(cat <<'EOF'
feat(elixir): add GitHub Projects v2 adapter (candidate fetch + refresh)

Implements SPEC.md §11.1 REQUIRED operations:
- fetch_candidate_issues/0 with active_states + include_kinds + repo filters
  applied client-side (Projects v2 has no server-side item filter, §11.2)
- fetch_issues_by_states/1 with empty-list short-circuit
- fetch_issue_states_by_ids/1 using nodes(ids:) form

Terminal-OR rule (§11.2.1): an item is terminal when Status is in
terminal_states OR the underlying Issue.state == CLOSED OR
PullRequest.state ∈ {CLOSED, MERGED}. Items whose Status is unset render
as the literal "<no status>" sentinel and are always inactive.

Github.Adapter is dead code at runtime in PR1 — Tracker.adapter/0 still
routes "github" through the legacy catch-all. PR2 commit 7 flips that
routing. Spec §11.5 (no orchestrator writes) governs the eventual rewrite.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 11.5: PR2 commit 7 — `tracker.ex` rewrite (do NOT execute during PR1)**

> Stop here when working on PR1. The next step belongs to PR2's branch (`feat/github-tracker-pr2`), after PR1 has merged to `main`. Re-checkout the PR2 branch before running it.

The actual code change is in Step 9 above (Tracker behaviour drops `create_comment/2` and `update_issue_state/2`; `Tracker.adapter/0` routes `"github"` to `Github.Adapter` and removes the Linear catch-all). On the PR2 branch:

```bash
git add lib/symphony_elixir/tracker.ex
git commit -m "$(cat <<'EOF'
feat(elixir): route tracker callbacks to Github.Adapter; drop write APIs

Tracker behaviour drops create_comment/2 and update_issue_state/2 per
SPEC.md §11.5 — Issue/PR mutations move to the agent via the
github_graphql Codex dynamic tool (§18.2.1).

Tracker.adapter/0 now routes "github" -> Github.Adapter (Phase 1 PR1 +
PR2 commit 7). The Linear catch-all is removed; tracker.kind == "linear"
becomes unreachable. Task 8b (Linear deletion) is the next commit on
this branch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Orchestrator predicates — terminal-OR, dependency gating, reconciliation

**Spec coverage:** §8.2 (eligibility), §8.2.1 (dependency gating), §8.5 Part B (reconciliation), §11.2.1 terminal-OR for the orchestrator side.

**Files:**
- Modify: `lib/symphony_elixir/orchestrator.ex` (predicate updates)
- Modify: `lib/symphony_elixir/tracker/memory.ex` (new domain shape so memory adapter still backs tests)
- Modify: existing tests previously marked `:skip_until_task_6` — re-enable.

- [ ] **Step 1: Update `Tracker.Memory` to emit the new Issue struct**

Modify `lib/symphony_elixir/tracker/memory.ex`. Replace the legacy `SymphonyElixir.Linear.Issue` references with `SymphonyElixir.Github.Issue`. Drop `create_comment/2` and `update_issue_state/2`. Make `fetch_candidate_issues/0` honor terminal-OR by reading both Status and `issue_state` on each fixture issue.

- [ ] **Step 2: Update orchestrator dispatch eligibility test**

Open `test/symphony_elixir/core_test.exs`, find tests asserting "an issue with state in active_states dispatches", and add a new test (or extend an existing one) covering terminal-OR:

```elixir
test "merged PR is treated as terminal even if Project Status is active" do
  pr_issue =
    SymphonyElixir.Github.Issue.new(%{
      id: "PVTI_pr",
      identifier: "archelab/symphony#5",
      kind: "pull_request",
      title: "merged",
      state: "In Progress",
      issue_state: "MERGED",
      pr: %{state: "MERGED", merged: true, is_draft: false, base_ref_name: "main"},
      labels: [],
      blocked_by: [],
      repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
      number: 5
    })

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [pr_issue])
  # ... assert orchestrator does NOT dispatch this issue
end
```

- [ ] **Step 3: Update predicate code in orchestrator**

In `lib/symphony_elixir/orchestrator.ex` find the dispatch eligibility filter (search for `active_states` or `state in tracker_active_states`). Replace with a single `dispatchable?/2` helper that consults BOTH the project state AND the underlying issue/PR state per §11.2.1:

```elixir
defp dispatchable?(issue, tracker_settings) do
  state_lc = String.downcase(issue.state)
  active = Enum.map(tracker_settings.active_states, &String.downcase/1)
  terminal = Enum.map(tracker_settings.terminal_states, &String.downcase/1)

  cond do
    # Spec §11.2.1: "<no status>" is inactive AND non-terminal.
    state_lc == "<no status>" -> false
    state_lc in terminal -> false
    state_lc not in active -> false
    # Spec §11.2.1 active rule has an explicit AND clause.
    issue.kind == "draft_issue" -> not blocked_for_state?(issue, state_lc, tracker_settings)
    issue.issue_state == "OPEN" -> not blocked_for_state?(issue, state_lc, tracker_settings)
    # Issue/PR not OPEN ⇒ inactive (covers CLOSED, MERGED, and malformed nil).
    true -> false
  end
end

defp blocked_for_state?(issue, state_lc, tracker_settings) do
  gating = Enum.map(tracker_settings.dependency_gating_states || [], &String.downcase/1)

  cond do
    gating == [] -> false
    state_lc not in gating -> false
    Enum.empty?(open_blockers(issue, tracker_settings)) -> false
    true -> true
  end
end

defp open_blockers(issue, tracker_settings) do
  # Spec §8.2.1: a blocker is resolved iff state == CLOSED. Any other state
  # (OPEN, nil, future enum value) keeps it unresolved — fail loud, not soft.
  for b <- issue.blocked_by,
      b.state != "CLOSED",
      honor_blocker?(b, issue, tracker_settings),
      do: b
end

defp honor_blocker?(_blocker, _issue, %{cross_repo_blockers: true}), do: true

defp honor_blocker?(%{identifier: identifier}, %{repository: %{name_with_owner: nwo}}, _)
     when is_binary(identifier) do
  case String.split(identifier, "#") do
    [b_repo, _num] -> String.downcase(b_repo) == String.downcase(nwo)
    # Draft blocker (`draft:<short>`) or malformed: no repository to compare,
    # cannot prove same-repo, so DROP under cross_repo_blockers: false.
    _ -> false
  end
end

defp honor_blocker?(_blocker, _issue, _tracker_settings), do: false
```

- [ ] **Step 4: Update reconciliation termination logic**

Find the reconciliation path that consumes `fetch_issue_states_by_ids/1` results (search for `fetch_issue_states_by_ids` calls). When the returned `state` field is one of the sentinels `<closed>` or `<merged>` (emitted by the adapter), treat the issue as terminal: stop the running worker, schedule workspace cleanup. Add `gate_running_on_dependencies` handling: when `true`, when reconciliation observes blocker transitions from all-closed to any-open during a running worker, call the worker stop path.

Sketch:

```elixir
defp reconcile_running({issue_id, running_entry}, refresh_results, tracker_settings) do
  case Enum.find(refresh_results, &(&1.id == issue_id)) do
    nil ->
      # Item disappeared from project — treat as no-longer-active.
      stop_worker(running_entry, :reconciled_missing)

    %{state: "<no status>"} ->
      # Spec §11.2.1: never stop on <no status> alone.
      :ok

    %{state: "<closed>"} ->
      stop_worker(running_entry, :terminal_or_closed)

    %{state: "<merged>"} ->
      stop_worker(running_entry, :terminal_or_merged)

    %{state: state} ->
      state_lc = String.downcase(state)
      cond do
        state_lc in Enum.map(tracker_settings.terminal_states, &String.downcase/1) ->
          stop_worker(running_entry, :terminal_state)

        state_lc not in Enum.map(tracker_settings.active_states, &String.downcase/1) ->
          stop_worker(running_entry, :inactive_state)

        tracker_settings.gate_running_on_dependencies and
            any_blockers_reopened?(running_entry, refresh_results) ->
          stop_worker(running_entry, :dependencies_reopened)

        true ->
          :ok
      end
  end
end
```

The atom `:dependencies_reopened` matches SPEC.md §8.5 Part C's reason string and the §13.1 worker-stop reason vocabulary added during this patch pass.

`any_blockers_reopened?/2` reads the previous blocker snapshot off the `running_entry` struct (snapshotted on dispatch from `issue.blocked_by`) and compares against the freshly normalized `blocked_by` returned by the refresh. Extend the running-entry record with a `blocked_by_snapshot` field if it doesn't already exist:

```elixir
defp any_blockers_reopened?(running_entry, refresh_results) do
  case Enum.find(refresh_results, &(&1.id == running_entry.issue_id)) do
    %{blocked_by: current} ->
      previously_all_closed? = Enum.all?(running_entry.blocked_by_snapshot, &(&1.state == "CLOSED"))
      now_any_open? = Enum.any?(current, &(&1.state != "CLOSED"))
      previously_all_closed? and now_any_open?

    _ ->
      false
  end
end
```

For this to compile, the refresh-results shape must carry `blocked_by` — extend `fetch_issue_states_by_ids/1` in Task 5 to return `blocked_by` for `Issue` kind in addition to `state`. (The current refresh query only selects `id number state repository`; add `trackedIssues(first: 50) { nodes { id number state repository { nameWithOwner } } }` to the `Issue` fragment in `@refresh_query`.)

- [ ] **Step 4a: Extend orchestrator state for `completed_at` (spec §4.1.8)**

SPEC.md §4.1.8 (patched in this rewrite cycle) upgrades `completed` from a set of issue IDs to a map `issue_id → %{completed_at: timestamp}` whenever `last_run_completed_at` is exposed to prompts. Phase 1 exposes it (Task 7 prompt), so the map shape is REQUIRED here.

In `lib/symphony_elixir/orchestrator.ex` (or wherever the orchestrator state struct is defined — look for `defstruct` with `:completed`), change:

```elixir
defstruct [
  # ...
  completed: MapSet.new(),
  # ...
]
```

to:

```elixir
defstruct [
  # ...
  completed: %{},
  # ...
]
```

Update every site that previously did `MapSet.put(state.completed, issue_id)` to:

```elixir
%{state | completed: Map.put(state.completed, issue_id, %{completed_at: DateTime.utc_now() |> DateTime.to_iso8601()})}
```

Update lookups: `MapSet.member?(state.completed, id)` → `Map.has_key?(state.completed, id)`.

Add a test in `test/symphony_elixir/core_test.exs`:

```elixir
test "completed records ISO8601 completed_at on normal worker exit" do
  # ... drive an issue through normal completion via the test harness ...
  state = Orchestrator.state()
  assert %{completed_at: timestamp} = Map.fetch!(state.completed, "PVTI_x")
  assert {:ok, _, _} = DateTime.from_iso8601(timestamp)
end
```

The prompt builder (Task 7) reads `state.completed[issue_id][:completed_at]` to derive `last_run_completed_at`.

- [ ] **Step 4b: Ensure `stop_worker/2` emits structured logs (spec §13.1)**

Every termination path goes through `stop_worker/2`. Confirm (or add) a `Logger.info/2` call inside it that emits the §13.1 REQUIRED context fields plus the canonical reason vocabulary added to SPEC.md:

```elixir
defp stop_worker(running_entry, reason) do
  Logger.info("worker stop",
    issue_id: running_entry.issue_id,
    issue_identifier: running_entry.issue_identifier,
    session_id: running_entry.session_id,
    reason: reason
  )

  # ... existing stop logic
end
```

Add assertions in the orchestrator test suite covering:

```elixir
test ":terminal_or_closed, :terminal_or_merged, :terminal_state, :inactive_state, :reconciled_missing, :dependencies_reopened all log via stop_worker/2" do
  # drive each branch and capture_log/1 — assert reason key=value pair
end

test "<no status> reconciliation is a no-op (spec §11.2.1) — no worker stop" do
  refresh = [%{id: "PVTI_x", state: "<no status>"}]
  running = %{issue_id: "PVTI_x", issue_identifier: "archelab/symphony#1", session_id: "t-1"}

  log =
    capture_log(fn ->
      assert :ok = Orchestrator.reconcile_running({"PVTI_x", running}, refresh, settings_fixture())
    end)

  refute log =~ "worker stop"
end
```

The `<no status>` test pins the BLOCKER fix from Wave 1B (a future refactor that flips branch order or removes the guard would be caught immediately).

- [ ] **Step 5: Re-enable `:skip_until_task_6` tests**

Find every `@tag :skip_until_task_6` and remove it. Run each test individually to confirm it now passes:

```bash
cd elixir && mise exec -- mix test --include skip_until_task_6
```

Fix any remaining failures by adjusting fixture identifiers (`MT-1` → `archelab/symphony#1`) and Issue shapes (use `Github.Issue.new/1`). Do NOT change the orchestrator's actual logic to make a test pass — that's a sign the test expectation is stale.

- [ ] **Step 6: Run the full suite (still has Linear specs that will fail)**

```bash
cd elixir && mise exec -- mix test --exclude live_e2e
```

Expected: predicate-related tests pass; Linear-specific tests (`linear/client.ex` references) are still red. Do not delete them yet — that's Task 8.

- [ ] **Step 7: Commit**

```bash
git add lib/symphony_elixir/orchestrator.ex \
        lib/symphony_elixir/tracker/memory.ex \
        test/symphony_elixir/core_test.exs
git commit -m "$(cat <<'EOF'
feat(elixir): orchestrator predicates honor terminal-OR + dependency gating

SPEC.md §11.2.1 (terminal-OR), §8.2 (eligibility), §8.2.1 (dependency
gating). dispatchable?/2 short-circuits on:
- "<no status>" sentinel (always inactive, never terminal)
- terminal_states match on the project Status field
- issue.issue_state ∈ {CLOSED, MERGED} (the OR clause)
- empty active_states intersection

Dependency gating reads dependency_gating_states + cross_repo_blockers
from tracker config, so a parent issue with one open trackedIssue is
withheld from dispatch when its Status is in the gating list.
gate_running_on_dependencies, when true, also stops a running worker
when its blockers reopen during reconciliation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: WORKFLOW.md rewrite + github_graphql Codex tool + prompt template

**Spec coverage:** §5.3 front matter, §11.5 (writes via agent), §12.1–12.3 prompt rendering, §18.2 RECOMMENDED extension `github_graphql` client-side tool.

**Files:**
- Modify: `elixir/WORKFLOW.md`
- Create: `lib/symphony_elixir/codex/github_graphql_tool.ex`
- Modify: `lib/symphony_elixir/codex/dynamic_tool.ex`
- Modify: `lib/symphony_elixir/prompt_builder.ex`
- Create: `test/symphony_elixir/codex/github_graphql_tool_test.exs`
- Modify: `test/symphony_elixir/dynamic_tool_test.exs`

- [ ] **Step 1: Write failing test for github_graphql tool registration**

Create `test/symphony_elixir/codex/github_graphql_tool_test.exs`:

```elixir
defmodule SymphonyElixir.Codex.GithubGraphqlToolTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.GithubGraphqlTool

  test "tool definition declares query+variables schema" do
    %{name: name, description: desc, parameters: params} = GithubGraphqlTool.definition()
    assert name == "github_graphql"
    assert desc =~ "GitHub"
    assert get_in(params, ["properties", "query"])
    assert get_in(params, ["properties", "variables"])
    assert params["required"] == ["query"]
  end

  test "rejects mutations not on the allowlist" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_workflow_file!(Workflow.workflow_file_path())

    {:error, {:mutation_not_allowed, name}} =
      GithubGraphqlTool.handle(%{
        "query" => "mutation Drop { deleteProjectV2Field(input:{fieldId:\"x\"}) { __typename } }",
        "variables" => %{}
      })

    assert name == "deleteProjectV2Field"
  end

  test "passes through allowlisted mutation" do
    fake =
      fn query, _v, _opts ->
        assert query =~ "addComment"
        {:ok, %{"data" => %{"addComment" => %{"clientMutationId" => "x"}}}}
      end

    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, %{"data" => %{"addComment" => _}}} =
             GithubGraphqlTool.handle(%{
               "query" => "mutation { addComment(input:{subjectId:\"x\", body:\"hi\"}) { clientMutationId } }",
               "variables" => %{}
             })
  end

  test "rejects multi-mutation document where any field is not allowlisted" do
    write_workflow_file!(Workflow.workflow_file_path())

    {:error, {:mutation_not_allowed, name}} =
      GithubGraphqlTool.handle(%{
        "query" => """
        mutation {
          addComment(input: {subjectId: "x", body: "hi"}) { clientMutationId }
          deleteIssue(input: {issueId: "y"}) { clientMutationId }
        }
        """,
        "variables" => %{}
      })

    assert name == "deleteIssue"
  end

  test "named mutation with variables extracts the field name correctly" do
    fake =
      fn query, _v, _opts ->
        assert query =~ "addComment"
        {:ok, %{"data" => %{"addComment" => %{}}}}
      end

    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{
               "query" =>
                 "mutation Op($id: ID!, $body: String!) { addComment(input: {subjectId: $id, body: $body}) { clientMutationId } }",
               "variables" => %{"id" => "x", "body" => "hi"}
             })
  end

  test "rejects malformed mutation with mutation_unparseable" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{"query" => "mutation Op", "variables" => %{}})

    assert {:error, {:mutation_unparseable, _}} =
             GithubGraphqlTool.handle(%{"query" => "mutation { ", "variables" => %{}})
  end

  test "shorthand query syntax {} is allowed without mutation gating" do
    fake = fn _q, _v, _opts -> {:ok, %{"data" => %{"viewer" => %{"login" => "x"}}}} end
    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, _} =
             GithubGraphqlTool.handle(%{"query" => "{ viewer { login } }", "variables" => %{}})
  end
end
```

- [ ] **Step 2: Run, expect failure**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/codex/github_graphql_tool_test.exs
```

Expected: FAIL — module missing.

- [ ] **Step 3: Implement `lib/symphony_elixir/codex/github_graphql_tool.ex`**

```elixir
defmodule SymphonyElixir.Codex.GithubGraphqlTool do
  @moduledoc """
  Codex dynamic tool registration for GitHub GraphQL access.
  Spec §11.5 (agent-driven writes) and §18.2 (github_graphql extension).
  """

  alias SymphonyElixir.{Config, Github.Client}

  @default_mutation_allowlist ~w(
    addComment
    updateProjectV2ItemFieldValue
    addLabelsToLabelable
    removeLabelsFromLabelable
    requestReviews
    addPullRequestReview
    resolveReviewThread
  )

  @spec definition() :: map()
  def definition do
    %{
      name: "github_graphql",
      description: "Execute a GitHub GraphQL query or mutation against the Symphony tracker. " <>
                   "Mutations are restricted by allowlist; queries are unrestricted.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "GraphQL query or mutation source"},
          "variables" => %{"type" => "object", "description" => "Variables map", "default" => %{}}
        },
        "required" => ["query"]
      }
    }
  end

  @spec handle(map()) :: {:ok, map()} | {:error, term()}
  def handle(%{"query" => query} = args) do
    variables = Map.get(args, "variables", %{}) || %{}

    with {:ok, _kind} <- check_mutation_allowed(query) do
      tracker = Config.settings!().tracker
      fun = Application.get_env(:symphony_elixir, :github_client, &Client.graphql/3)

      fun.(query, variables, endpoint: tracker.endpoint, token: tracker.api_token)
    end
  end

  # Spec §18.2.1: malformed mutations MUST return :mutation_unparseable.
  # Multi-mutation documents must gate ALL top-level fields, not just the first.
  defp check_mutation_allowed(query) do
    trimmed = query |> String.trim_leading() |> strip_leading_comments()

    cond do
      String.starts_with?(trimmed, "{") -> {:ok, :query}
      starts_with_keyword?(trimmed, "query") -> {:ok, :query}
      starts_with_keyword?(trimmed, "subscription") -> {:ok, :query}
      starts_with_keyword?(trimmed, "mutation") -> gate_mutation(query)
      true -> {:error, {:mutation_unparseable, trimmed |> String.slice(0, 80)}}
    end
  end

  defp starts_with_keyword?(text, kw) do
    case text do
      <<^kw::binary, rest::binary>> ->
        rest == "" or String.starts_with?(rest, [" ", "\t", "\n", "(", "{"])
      _ ->
        false
    end
  end

  defp strip_leading_comments(text) do
    case Regex.replace(~r/\A(\s*#[^\n]*\n)+/, text, "") do
      ^text -> text
      stripped -> String.trim_leading(stripped)
    end
  end

  defp gate_mutation(query) do
    # Extract every top-level field selection inside the outer `mutation { ... }`.
    case Regex.run(~r/mutation\b[^{]*\{(.+)\}\s*\z/s, query) do
      [_, body] ->
        names = extract_top_level_fields(body)

        cond do
          names == [] ->
            {:error, {:mutation_unparseable, "no fields in mutation body"}}

          Enum.all?(names, &(&1 in mutation_allowlist())) ->
            {:ok, :mutation}

          true ->
            bad = Enum.find(names, &(&1 not in mutation_allowlist()))
            {:error, {:mutation_not_allowed, bad}}
        end

      _ ->
        {:error, {:mutation_unparseable, "could not isolate mutation body"}}
    end
  end

  # Walk the mutation body, returning every top-level field name (depth 0).
  # Brace-depth tracking handles nested selection sets without a real parser.
  defp extract_top_level_fields(body) do
    body
    |> String.to_charlist()
    |> walk_fields(0, [], [])
    |> Enum.reverse()
  end

  defp walk_fields([], _depth, _buf, acc), do: acc
  defp walk_fields([?{ | rest], depth, buf, acc), do: walk_fields(rest, depth + 1, [], maybe_emit(buf, depth, acc))
  defp walk_fields([?} | rest], depth, _buf, acc), do: walk_fields(rest, depth - 1, [], acc)
  defp walk_fields([?( | rest], depth, buf, acc), do: walk_fields(skip_parens(rest, 1), depth, buf, acc)
  defp walk_fields([c | rest], 0, buf, acc) when c in [?\s, ?\t, ?\n, ?,], do: walk_fields(rest, 0, [], maybe_emit(buf, 0, acc))
  defp walk_fields([c | rest], depth, buf, acc) when depth > 0, do: walk_fields(rest, depth, buf, acc)
  defp walk_fields([c | rest], 0, buf, acc), do: walk_fields(rest, 0, [c | buf], acc)

  defp skip_parens([], _), do: []
  defp skip_parens(rest, 0), do: rest
  defp skip_parens([?( | rest], n), do: skip_parens(rest, n + 1)
  defp skip_parens([?) | rest], n), do: skip_parens(rest, n - 1)
  defp skip_parens([_ | rest], n), do: skip_parens(rest, n)

  defp maybe_emit([], _depth, acc), do: acc
  defp maybe_emit(buf, 0, acc) do
    name = buf |> Enum.reverse() |> List.to_string() |> String.trim()
    if name == "" or String.starts_with?(name, "#"), do: acc, else: [name | acc]
  end
  defp maybe_emit(_buf, _depth, acc), do: acc

  defp mutation_allowlist do
    Application.get_env(:symphony_elixir, :github_graphql_mutation_allowlist, @default_mutation_allowlist)
  end
end
```

- [ ] **Step 4: Register via `dynamic_tool.ex`**

In `lib/symphony_elixir/codex/dynamic_tool.ex`, add `SymphonyElixir.Codex.GithubGraphqlTool` to the registered tools list (the existing module already has a tool registry — just append).

- [ ] **Step 5: Run tool tests, expect pass**

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/codex/github_graphql_tool_test.exs
```

Expected: PASS (3 tests).

- [ ] **Step 6: Rewrite `elixir/WORKFLOW.md`**

Replace the front matter with the Phase 1 GitHub config and rewrite the prompt body to be `gh`-aware with PR/issue/draft branches:

```markdown
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
```

- [ ] **Step 7: Update `lib/symphony_elixir/prompt_builder.ex` — render the new domain + last_run_completed_at**

The existing builder uses Solid (Liquid) and renders the issue map. Add `last_run_completed_at` to the rendering context. Search for the location where `attempt` is added to the render context and add a sibling key `last_run_completed_at`. Source: orchestrator state's `completed` set should now record an end timestamp per issue (extend the existing struct).

- [ ] **Step 8: Add strict-mode prompt rendering test**

Spec §12.2 requires "strict variable checking" and "strict filter checking". Add to `test/symphony_elixir/prompt_builder_test.exs` (create if needed):

```elixir
defmodule SymphonyElixir.PromptBuilderTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Github.Issue, PromptBuilder}

  test "renders new domain shape including pr.* and last_run_completed_at" do
    issue =
      Issue.new(%{
        id: "PVTI_x",
        identifier: "archelab/symphony#7",
        kind: "pull_request",
        title: "Fix",
        state: "Rework",
        repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
        number: 7,
        branch_name: "fix-x",
        labels: ["bug"],
        blocked_by: [],
        url: "https://github.com/archelab/symphony/pull/7",
        issue_state: "OPEN",
        pr: %{state: "OPEN", merged: false, is_draft: false, base_ref_name: "main"}
      })

    template = ~s({{ issue.identifier }} on {{ issue.pr.base_ref_name }} (attempt={{ attempt }}, since={{ last_run_completed_at }}))

    assert {:ok, rendered} =
             PromptBuilder.render(template,
               issue: issue,
               attempt: 2,
               last_run_completed_at: "2026-05-09T20:00:00Z"
             )

    assert rendered ==
             "archelab/symphony#7 on main (attempt=2, since=2026-05-09T20:00:00Z)"
  end

  test "strict mode rejects unknown variable" do
    issue = sample_issue()
    template = "{{ issue.bogus_field }}"
    assert {:error, _} = PromptBuilder.render(template, issue: issue, attempt: nil)
  end

  defp sample_issue do
    Issue.new(%{
      id: "PVTI_y", identifier: "archelab/symphony#1", kind: "issue",
      title: "x", state: "Agent Ready",
      repository: %{owner: "archelab", name: "symphony", name_with_owner: "archelab/symphony"},
      number: 1, labels: [], blocked_by: [], issue_state: "OPEN"
    })
  end
end
```

Run:

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/prompt_builder_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/specs_check_test.exs
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add elixir/WORKFLOW.md \
        lib/symphony_elixir/codex/github_graphql_tool.ex \
        lib/symphony_elixir/codex/dynamic_tool.ex \
        lib/symphony_elixir/prompt_builder.ex \
        test/symphony_elixir/codex/github_graphql_tool_test.exs
git commit -m "$(cat <<'EOF'
feat(elixir): rewrite WORKFLOW.md + add github_graphql Codex tool

WORKFLOW.md front matter targets archelab/symphony Project #1; prompt
body branches on issue.kind (issue / pull_request / draft_issue) and on
{% if attempt %} for continuation/Rework runs (last_run_completed_at
threaded into the render context).

GithubGraphqlTool registers a `github_graphql` Codex dynamic tool with
a configurable mutation allowlist (default: addComment,
updateProjectV2ItemFieldValue, addLabelsToLabelable,
removeLabelsFromLabelable, requestReviews, addPullRequestReview,
resolveReviewThread). Spec §11.5 and §18.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Verify live integration after orchestrator cutover, then delete Linear

**Spec coverage:** §17.8 Real Integration Profile, §18.3.

**Files:**
- Modify: `test/symphony_elixir/github_live_test.exs` (already exists from PR1 Task 5a — add orchestrator-level assertion)
- Delete: `lib/symphony_elixir/linear/`
- Delete: `test/symphony_elixir/live_e2e_test.exs` (Linear-targeted) and any other Linear-specific test files identified during this task.
- Modify: `lib/symphony_elixir/config/schema.ex` — tighten `@valid_kinds` from `["github", "memory", "linear"]` to `["github", "memory"]`.
- Modify: `mix.exs` (drop `SymphonyElixir.Linear.Client` from `ignore_modules` coverage list)

- [ ] **Step 1: Extend `github_live_test.exs` with an orchestrator-level assertion**

PR1 already created the live test against `Adapter` directly. PR2 adds an end-to-end assertion that the orchestrator dispatches against the live project. Append to `test/symphony_elixir/github_live_test.exs`:

```elixir
  test "Tracker.fetch_candidate_issues/0 routes to Github.Adapter (post-cutover)" do
    assert {:ok, issues} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert is_list(issues)
    # If any issues exist, they must be normalized through Github.Issue, not the
    # Linear shape. A regression where Tracker.adapter/0 returns Linear.Adapter
    # would surface here as a struct-type mismatch.
    Enum.each(issues, fn issue ->
      assert %SymphonyElixir.Github.Issue{} = issue
    end)
  end
```

Append a second test exercising the `github_graphql` Codex tool (added by Task 7 in PR2):

```elixir
  test "github_graphql tool smoke-tests viewer{login} against real GitHub" do
    assert {:ok, %{"data" => %{"viewer" => %{"login" => login}}}} =
             SymphonyElixir.Codex.GithubGraphqlTool.handle(%{
               "query" => "query { viewer { login } }",
               "variables" => %{}
             })

    assert is_binary(login)
  end
```

- [ ] **Step 2: Run the live test (full file)**

```bash
cd elixir && mise exec -- mix test --only live_github
```

Expected: PASS (project may be empty — empty list is OK).

- [ ] **Step 3: Verify the project is reachable end-to-end**

```bash
cd elixir && mise exec -- mix run --no-start -e '
  Application.ensure_all_started(:symphony_elixir)
  System.put_env("GITHUB_TOKEN", System.get_env("GITHUB_TOKEN"))
  IO.inspect(SymphonyElixir.Github.Adapter.fetch_candidate_issues(), label: "live")
'
```

Expected: an `{:ok, [...]}` tuple.

- [ ] **Step 4: Delete Linear modules**

```bash
git rm -r elixir/lib/symphony_elixir/linear/
git rm elixir/lib/symphony_elixir/linear.ex 2>/dev/null || true
git rm elixir/test/symphony_elixir/live_e2e_test.exs
# Other Linear-specific tests identified by grep:
grep -lR "SymphonyElixir.Linear" elixir/test | xargs git rm
```

- [ ] **Step 5: Drop Linear from `mix.exs` coverage ignore list**

In `elixir/mix.exs`, remove `SymphonyElixir.Linear.Client` from `test_coverage.ignore_modules`.

- [ ] **Step 6: Drop Linear aliases from test support**

In `elixir/test/support/test_support.exs`, remove `alias SymphonyElixir.Linear.Client` and `alias SymphonyElixir.Linear.Issue`. Add `alias SymphonyElixir.Github.{Adapter, Issue, Client}`.

- [ ] **Step 7: Full suite, all green except live_github (which we already ran)**

```bash
cd elixir && mise exec -- mix test --exclude live_github
```

Expected: 100% pass.

- [ ] **Step 8: Lint**

```bash
cd elixir && mise exec -- mix lint
```

Expected: no `credo --strict` warnings; specs.check passes.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(elixir): delete Linear adapter; add real-integration test

archelab/symphony Project #1 is the real-integration target (spec §17.8).
Live test runs only when GITHUB_TOKEN is set so CI without secrets stays
green. After this commit the codebase has zero Linear references.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 10: Open PR2 (the cutover)**

PR1 should already have landed — if not, stop and ship PR1 first. PR2 contains commits 7–11 (Task 5b through Task 8b).

```bash
# Assumes PR1 is already merged to feat/github-tracker-spec or main
git push -u origin feat/github-tracker-spec-pr2
gh pr create --title "feat: cutover tracker to GitHub Projects v2 (Phase 1 PR2)" --body "$(cat <<'EOF'
## Summary
- Cutover: orchestrator now dispatches against GitHub Projects v2; Linear deleted.
- Workflow targets archelab/symphony Project #1.
- Tracker writes are agent-driven via the `github_graphql` Codex dynamic tool (spec §11.5 + §18.2.1).
- pr.* Tier 1 fields included; Tier 2 (review_decision, check_state, threads, opinionated reviews) deferred to Phase 2 alongside §11.7 PR signal predicates.

This PR is the second half of Phase 1. PR1 (`feat/github-tracker-spec`, already merged) added the GitHub adapter as dead code. This PR flips `tracker.ex` routing, rewrites orchestrator predicates, switches WORKFLOW.md to GitHub front matter, and deletes Linear.

## Spec coverage
- §4.1.1 domain model
- §5.3.1 tracker config
- §11.1–11.4 adapter operations + error categories
- §11.2.1 terminal-OR rule
- §11.2.4 Status field probe
- §11.3 normalization
- §11.5 no orchestrator writes (writes via agent tool)

## Test plan
- [x] Unit: client error mapping, project resolver, status field probe, normalization
- [x] Adapter: terminal-OR, archived/redacted/no-status filtering, include_kinds, repo filter
- [x] Orchestrator: dispatch eligibility honors terminal-OR + dependency gating
- [x] Workspace: identifier sanitization for `/` and `#`
- [x] Live: GITHUB_TOKEN-gated call against archelab/symphony Project #1

## Out of scope (later PRs)
- Phase 2: §11.7 PR dispatch/block signal predicates + Tier 2 pr.* fields
- Phase 3: Appendix B webhook listener
- Phase 4: Appendix C comment control plane

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Phase 2 — PR Review and CI Awareness extension (outline only)

**Goal:** Add §11.7 dispatch and block predicates so PRs can be dispatched on `changes_requested` / `ci_failure` / `review_requested` and blocked on `awaiting_human_review` / `mergeable_unknown` / `merge_state_blocked`.

**Phase 2 selection-set delta** (added to Phase 1's `@pr_fragment_tier1`, becomes `@pr_fragment_tier2`):

```graphql
... on PullRequest {
  reviewDecision
  mergeable
  mergeStateStatus
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
    nodes { commit { oid statusCheckRollup { state } } }
  }
}
```

This delta drops as a single concatenation into the existing query because Phase 1's Task 5 splits `@candidate_query` into composable `@issue_fragment` / `@pr_fragment_tier1` / `@draft_fragment` attributes (see Task 5 forward-compatibility note).

**Predicate mapping:**

| Field | Drives signal |
|---|---|
| `reviewDecision` | `awaiting_human_review`, `merge_state_blocked` (block) |
| `mergeable` | `mergeable_unknown` (block) |
| `mergeStateStatus` | `merge_state_blocked` (block) |
| `latestOpinionatedReviews` + `reviewThreads.isResolved` | `changes_requested` (dispatch) |
| `commits.last.commit.statusCheckRollup.state` | `ci_failure` (dispatch) |
| `reviewRequests` ∩ `pr_self_reviewer_logins` | `review_requested` (dispatch) |

**Files:**
- Extend `lib/symphony_elixir/github/normalize.ex` with Tier 2 fields (review_decision, mergeable, merge_state_status, check_state, unresolved_review_threads, latest_opinionated_reviews, requested_reviewers).
- Extend `lib/symphony_elixir/github/adapter.ex`'s candidate query via the `@pr_fragment_tier2` attribute above.
- Create `lib/symphony_elixir/orchestrator/pr_predicates.ex` — pure functions evaluating the §11.7.2 logical formula. Block-wins-over-dispatch ordering is enforced here, not in the orchestrator's main loop.
- Extend `tracker` config schema with `pr_dispatch_signals`, `pr_block_signals`, `pr_self_reviewer_logins` and emit `unsupported_pr_signal` (canonical error category, spec §11.4) for unknown values.
- Update orchestrator dispatch path to call `pr_predicates` after the core dispatch check.

**Estimated effort:** ~1–2 days. One PR.

---

## Phase 3 — Webhook-Driven Dispatch (Appendix B) (outline only)

**Goal:** Mount a Phoenix controller at `webhook.path` (default `/webhooks/github`) that verifies HMAC-SHA256, deduplicates `X-GitHub-Delivery`, and triggers a coalesced refresh-tick. Polling remains the safety net.

**Files:**
- Add `webhook` embedded schema to `lib/symphony_elixir/config/schema.ex` (enabled, bind, port, path, secret, events, allowlist_cidrs, delivery_dedup_ttl_ms).
- Create `lib/symphony_elixir/webhook/signature.ex` (constant-time HMAC compare).
- Create `lib/symphony_elixir/webhook/dedup.ex` (ETS-backed, TTL-based).
- Create `lib/symphony_elixir/webhook/dispatcher.ex` (event routing → `Orchestrator.refresh/1` with hinted IDs).
- Create `lib/symphony_elixir_web/webhook_controller.ex`.
- Modify `lib/symphony_elixir_web/endpoint.ex` to insert a raw-body plug at the webhook route BEFORE `Plug.Parsers` (so HMAC sees pristine bytes).
- Cover all of §B.3 (signature mismatch, missing sig, IP allowlist, dedup, ping, queue overflow).

**Estimated effort:** ~3 days. One PR.

---

## Phase 4 — Comment Control Plane (Appendix C) (outline only)

**Goal:** `@<bot_login> retry|pause|resume|stop|status` slash commands gated by repository permission via the REST `/repos/{owner}/{repo}/collaborators/{login}/permission` endpoint.

**Files:**
- Add `comment_commands` embedded schema to `lib/symphony_elixir/config/schema.ex`.
- Create `lib/symphony_elixir/comments/parser.ex` — line-level Markdown filter (skip blockquotes, fenced code blocks, indented code) + canonical command tokenizer.
- Create `lib/symphony_elixir/comments/authz.ex` — REST permission resolver, `allowed_authors` bypass, self-loop suppression.
- Create `lib/symphony_elixir/comments/dispatcher.ex` — wire to Phase 3 webhook router for `issue_comment.{created,edited}` and `pull_request_review_comment.{created,edited}`.
- Add startup probe `comment_commands_token_insufficient` (spec §C.6).

**Estimated effort:** ~1–2 days. One PR (depends on Phase 3 merging first).

---

## Carry-over from existing implementation (behavior unchanged in Phase 1)

These §18.1 REQUIRED items are covered by Linear-era code that survives the rewrite. **Some of the listed source files are edited in Phase 1 (notably `orchestrator.ex` is touched by Task 6 for predicates + `stop_worker/2` logging) but the LISTED BEHAVIOR is preserved.** A §18.1 conformance walk MUST verify these tests still pass unchanged on the post-rewrite tree.

**Reviewer note for Task 6:** retry-queue scheduling, exponential backoff, and workspace-cleanup paths inside `orchestrator.ex` are NOT modified by Task 6. The Task 6 reviewer MUST confirm the existing `core_test.exs` and `orchestrator_status_test.exs` retry-queue and cleanup tests pass unmodified. If they break, the Task 6 predicate work has accidentally touched scheduling — diagnose before merging.

| §18.1 item | Code location | Existing test |
|---|---|---|
| Workflow path selection (CLI override + cwd default) | `lib/symphony_elixir/cli.ex`, `lib/symphony_elixir/workflow.ex` | `test/symphony_elixir/cli_test.exs` |
| `WORKFLOW.md` loader (front matter + body split) | `lib/symphony_elixir/workflow.ex`, `lib/symphony_elixir/workflow_store.ex` | `test/symphony_elixir/workspace_and_config_test.exs` |
| Dynamic workflow watch/reload/re-apply | `lib/symphony_elixir/workflow_store.ex` | (Add Task 5 reload regression test asserting the resolver cache invalidates on `tracker:` edit — see Task 5 `invalidate_cache/0`.) |
| Coding-agent app-server JSON line protocol | `lib/symphony_elixir/codex/app_server.ex` | `test/symphony_elixir/app_server_test.exs` |
| Workspace lifecycle hooks | `lib/symphony_elixir/workspace.ex` | `test/symphony_elixir/workspace_and_config_test.exs` |
| Exponential retry queue + max_retry_backoff_ms | `lib/symphony_elixir/orchestrator.ex` | `test/symphony_elixir/core_test.exs` |
| Workspace cleanup (startup sweep + active transition) | `lib/symphony_elixir/orchestrator.ex`, `lib/symphony_elixir/workspace.ex` | `test/symphony_elixir/orchestrator_status_test.exs` |
| Operator-visible observability (snapshot/dashboard) | `lib/symphony_elixir_web/*`, `lib/symphony_elixir/status_dashboard.ex` | `test/symphony_elixir/orchestrator_status_test.exs`, `test/symphony_elixir/status_dashboard_snapshot_test.exs` |

If any of these tests break during Phase 1, the breakage is a regression introduced by the rewrite — diagnose at the call site, not by patching the test.

## Self-Review (run on completion)

After implementing all Phase 1 commits, walk this checklist BEFORE opening the PR. Replace each `<commit>` with the actual SHA so reviewers can audit the conformance claim line by line.

### §18.1 walk (literal, every bullet)

- [ ] Workflow path selection — carry-over (table above).
- [ ] `WORKFLOW.md` loader — carry-over.
- [ ] Typed config layer with defaults and `$` resolution — Task 1 commit `<commit>`.
- [ ] Dynamic `WORKFLOW.md` watch/reload/re-apply — carry-over + Task 5 cache invalidation `<commit>`.
- [ ] Polling orchestrator with single-authority mutable state — carry-over.
- [ ] GitHub tracker adapter speaks GraphQL against `tracker.endpoint` — Task 1 (config) + Task 3 (client) `<commits>`.
- [ ] Adapter resolves Project v2 by id or owner+number+owner_type — Task 4 `<commit>`.
- [ ] Status field probe with `tracker_status_field_missing` — Task 4 `<commit>`.
- [ ] Adapter paginates `items` (page size ≤ 100) — Task 5 `<commit>`.
- [ ] Adapter applies `active_states`, `include_kinds`, `tracker.repo` filters client-side — Task 5 `<commit>`.
- [ ] Adapter applies terminal-OR rule (§11.2.1) — Task 5 + Task 6 `<commits>`.
- [ ] Adapter honors primary + secondary GitHub rate-limit signals — Task 3 + Task 5b RateLimitGate `<commits>`.
- [ ] Issue tracker client with candidate fetch + state refresh + terminal fetch — Task 5 `<commit>`.
- [ ] Workspace manager with sanitized per-issue workspaces — Task 2 `<commit>`.
- [ ] Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`) — carry-over.
- [ ] Hook timeout config (`hooks.timeout_ms`, default 60000) — carry-over.
- [ ] Coding-agent app-server subprocess client — carry-over.
- [ ] Codex launch command config — carry-over.
- [ ] Strict prompt rendering with `issue` and `attempt` — Task 7 `<commit>` (and assert strict-mode test passes).
- [ ] Exponential retry queue — carry-over.
- [ ] Configurable retry backoff cap — carry-over.
- [ ] Reconciliation stops runs on terminal/non-active states — Task 6 `<commit>`.
- [ ] Workspace cleanup for terminal issues — carry-over.
- [ ] Structured logs with `issue_id`, `issue_identifier`, `session_id` — Task 6 Step 4b `<commit>`.
- [ ] Operator-visible observability — carry-over.

### Cross-cutting checks

- [ ] **Type consistency.** `Github.Issue.t()` shape used identically in orchestrator, prompt builder, and tests. `pr.state` strings match `OPEN`/`CLOSED`/`MERGED` everywhere.
- [ ] **No placeholders.** `grep -r "TODO\|TBD\|FIXME" lib/symphony_elixir/github/ test/symphony_elixir/github/` returns nothing except documented `# Phase 2:` priority markers.
- [ ] **Workspace containment.** Verify `Workspace.workspace_key/1` output for `archelab/symphony#42` and confirm `Path.join(root, key)` stays inside `root`.
- [ ] **Linear residue.** `grep -r "Linear" lib/ test/` returns zero matches.
- [ ] **Strict pipeline.** `mise exec -- mix lint && mise exec -- mix test_strict` (Task 0 toolchain).
- [ ] **`:dependencies_reopened` atom matches spec.** SPEC.md §8.5 Part C and §13.1 vocabulary both use this name; confirm no stale `:blockers_reopened` references in code or tests.

If any check fails, fix it before opening the PR. SPEC.md was patched in this rewrite cycle (§4.1.8 `completed` map, §12.3 `last_run_completed_at`, §13.1 worker-stop vocabulary, §18.2.1 `github_graphql` allowlist) — those amendments are part of the same PR.
