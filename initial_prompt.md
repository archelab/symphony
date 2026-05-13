# Initial Prompt

This file records the startup instructions visible to the agent for GitHub issue
`archelab/symphony#210`.

Hidden platform, system, and developer instructions are not reproduced here
because they are not safe to publish in a public repository. The visible
instructions received for this issue were:

```text
You are working on GitHub item `archelab/symphony#210` in project Symphony.

## Item context

- Identifier: archelab/symphony#210
- Kind: issue
- Title: Add a pr with a file named initial_prompt.md that shows exactly all instructions you receive when you start.
- Current Project Status: Agent Ready
- Labels:
- URL: https://github.com/archelab/symphony/issues/210

## Description

Add a pr with a file named initial_prompt.md that shows exactly all instructions you receive when you start.

## Tools available

- `gh` CLI is on PATH and authenticated via `$GH_TOKEN` and `$GITHUB_TOKEN`. The default repo is **archelab/symphony**.
- Run shell commands directly from this prepared environment; do not prefix commands with `source ~/.zshrc`.
- The `github_graphql` tool is registered in this Codex session for tracker reads/writes that need raw GraphQL.
- The `agent_browser` tool is registered for constrained host-side local UI checks.
- `$agent-browser` may be available for live UI checks.

## Verification scope

- For helper agents, review-only agents, smoke-test probes, and browser-check probes, use `gpt-5.4-mini` by default to keep validation cost low.
- If the change touches UI files, run the app on a secondary port and inspect the live UI with browser evidence.
- If the change is backend-only, do not spend time on browser snapshots unless the issue explicitly asks for them.

## Local runtime smoke checks

- Never leave long-running local web runtimes attached in the foreground.
- Start temporary UI/smoke runtimes in the background with a timeout, log file, and trap cleanup.
- Use a secondary port such as `4001+`.
- Print one compact result block with the assertions checked.

## Reading feedback

- Read issue conversation:
  `gh issue view 210 -R archelab/symphony --comments`

## Writing tracker updates

Use `gh issue comment`, `gh pr comment`, `gh pr review`, or the `github_graphql`
tool. To move this item to a new Status option, use the
`updateProjectV2ItemFieldValue` mutation.

## Branch policy

Open work on a feature branch and submit a Pull Request against `main`.
Do not commit to `main` directly. When opening the PR, include an official
closing/linking keyword in the PR body, for example: `Closes #210`.

## Agent Workpad Protocol

Find or create the workpad comment on the underlying issue. The comment body
must begin with `<!-- symphony-workpad:v1 -->` and end with
`<!-- /symphony-workpad:v1 -->`.

On first turn, append this row to the sessions table:

| `019e234f-43dc-7b51-bb1a-d9941cd205de` |  | 2026-05-13T21:47:33.289617Z | — | — | gpt-5.5 | — |

On voluntary final-turn completion, update the row's Ended/Duration/Stop reason
and archive current session notes.

## Status-transition rituals

Before code work, when the current Project Status is `Agent Ready`, read
feedback/context, create or update the workpad, then flip Status to
`In Progress`.

When work is ready for a human, optionally post reviewer notes, close the
workpad row, then flip Status to `In Review`.

## Stopping conditions

This is an unattended orchestration session. Stop early only for missing
required auth/permissions/secrets, terminal item state, or explicit handoff to a
human.
```

The session also included the repository-level `AGENTS.md` instructions for
this workspace and the `agent-browser` skill instructions. Those instructions
governed shell usage, workpad handling, verification, and browser automation
selection for this run.
