#!/usr/bin/env bash
# E2E-11: Blocked status-transition ritual.
#
# The agent receives an explicit smoke-mode instruction to simulate a blocker:
# first post a `## Blocker report` comment, then flip Status -> Blocked via
# github_graphql. The test fails if the item reaches Blocked before the
# blocker report is visible.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

MODEL="${SYMPHONY_E2E_E2E11_MODEL:-gpt-5.4-mini}"
REASON="${SYMPHONY_E2E_E2E11_REASON:-low}"
MAX_TURNS="${SYMPHONY_E2E_E2E11_MAX_TURNS:-2}"

WORKFLOW="$E2E_ELIXIR_DIR/WORKFLOW.md"
BACKUP="$WORKFLOW.e2e11_bak"
cp "$WORKFLOW" "$BACKUP"

cleanup_e2e11() {
  if [[ -f "$BACKUP" ]]; then
    mv "$BACKUP" "$WORKFLOW"
  fi
  rm -f "$WORKFLOW.tmp"
}
trap cleanup_e2e11 EXIT

sed -i.tmp -E \
  -e "s|model=\"[^\"]+\"|model=\"$MODEL\"|" \
  -e "s|model_reasoning_effort=[a-z]+|model_reasoning_effort=$REASON|" \
  -e "s|^( *max_turns:).*|\\1 $MAX_TURNS|" \
  "$WORKFLOW"
rm -f "$WORKFLOW.tmp"

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-11 blocker report before Blocked" \
  "placeholder — will edit body below")
ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")
BLOCKED_OPTION_ID=$(e2e::status_option_id "Blocked")

BODY="Smoke test. AGENT PRIORITY INSTRUCTION: Simulate a publishing blocker.

Do exactly these two github_graphql mutations, in order, then end the turn.

1. Post a NEW issue comment headed exactly:

## Blocker report

The comment body must include non-empty sections named:
- What I tried
- What failed
- Suggested operator action

Use this mutation shape:

\`\`\`
mutation {
  addComment(input:{
    subjectId:\"$ISSUE_NODE_ID\",
    body:\"## Blocker report\\n\\n**What I tried**\\n- Simulated publishing from e2e-11.\\n\\n**What failed**\\n- Simulated blocker for status-transition verification.\\n\\n**Suggested operator action**\\n- Confirm the agent reports blockers before moving Status to Blocked.\"
  }) { commentEdge { node { id } } }
}
\`\`\`

2. Only after the comment succeeds, flip this Project item to Blocked:

\`\`\`
mutation {
  updateProjectV2ItemFieldValue(input:{
    projectId:\"$E2E_PROJECT_ID\",
    itemId:\"$ITEM_ID\",
    fieldId:\"$E2E_STATUS_FIELD_ID\",
    value:{ singleSelectOptionId:\"$BLOCKED_OPTION_ID\" }
  }) { projectV2Item { id } }
}
\`\`\`

Do not make code changes. Do not create a PR."
gh issue edit "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" --body "$BODY" >/dev/null

e2e::set_status "$ITEM_ID" "Agent Ready"

IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM"
echo "issue=$ISSUE_NUM item=$ITEM_ID model=$MODEL max_turns=$MAX_TURNS"

e2e::wait_for_log_line "Dispatching issue to agent.*$IDENT" 60 || \
  e2e::verdict_fail "never dispatched"

elapsed=0
saw_comment=no
saw_blocked=no

while (( elapsed < 180 )); do
  comments_json=$(gh issue view "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" --json comments 2>/dev/null || echo '{}')
  if jq -e '.comments[]?.body | select(contains("## Blocker report")) | select(contains("What I tried")) | select(contains("What failed")) | select(contains("Suggested operator action"))' <<<"$comments_json" >/dev/null; then
    saw_comment=yes
  fi

  status_json=$(gh api graphql -f query="
    query {
      node(id:\"$ITEM_ID\") {
        ... on ProjectV2Item {
          fieldValueByName(name:\"Status\") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
  " 2>/dev/null || echo '{}')
  status_name=$(jq -r '.data.node.fieldValueByName.name // ""' <<<"$status_json")

  if [[ "$status_name" == "Blocked" ]]; then
    saw_blocked=yes
    if [[ "$saw_comment" != "yes" ]]; then
      e2e::verdict_fail "Status reached Blocked before a ## Blocker report comment was visible"
    fi
    break
  fi

  sleep 5
  (( elapsed+=5 ))
done

if [[ "$saw_comment" != "yes" ]]; then
  e2e::verdict_fail "no ## Blocker report comment within 180s"
fi

if [[ "$saw_blocked" != "yes" ]]; then
  e2e::verdict_fail "Status did not reach Blocked within 180s"
fi

e2e::verdict_pass
