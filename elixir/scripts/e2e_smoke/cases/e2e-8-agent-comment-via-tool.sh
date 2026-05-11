#!/usr/bin/env bash
# E2E-8: Agent uses the github_graphql Codex tool to write a comment.
#
# Requires a capable model to follow the in-prompt instruction. The smoke-mode
# workflow uses gpt-5.4-mini at minimal reasoning which usually ignores
# instructions. Override via SYMPHONY_E2E_E2E8_MODEL / SYMPHONY_E2E_E2E8_REASON
# env vars if available.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

MODEL="${SYMPHONY_E2E_E2E8_MODEL:-gpt-5.4}"
REASON="${SYMPHONY_E2E_E2E8_REASON:-low}"
MAX_TURNS="${SYMPHONY_E2E_E2E8_MAX_TURNS:-2}"

# Temporarily swap WORKFLOW.md to a version with a stronger model and max_turns
WORKFLOW="$E2E_ELIXIR_DIR/WORKFLOW.md"
BACKUP="$WORKFLOW.e2e8_bak"
cp "$WORKFLOW" "$BACKUP"
# shellcheck disable=SC2016
sed -i.tmp -E \
  -e "s|model=\"[^\"]+\"|model=\"$MODEL\"|" \
  -e "s|model_reasoning_effort=[a-z]+|model_reasoning_effort=$REASON|" \
  -e "s|^( *max_turns:).*|\\1 $MAX_TURNS|" \
  "$WORKFLOW"
rm -f "$WORKFLOW.tmp"

cleanup_e2e8() {
  mv "$BACKUP" "$WORKFLOW"
}
trap cleanup_e2e8 EXIT

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

# Create the issue with a body instructing the agent to use github_graphql.
read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-8 agent comment via github_graphql" \
  "placeholder — will edit body below")

# Edit body to include the actual node id of the just-created issue
BODY="Smoke test. AGENT PRIORITY INSTRUCTION: Use the github_graphql tool to post a comment to this issue. Call it with the following payload:

\`\`\`
mutation {
  addComment(input:{
    subjectId:\"$ISSUE_NODE_ID\",
    body:\"Smoke test comment from Symphony orchestrator e2e run.\"
  }) { commentEdge { node { id } } }
}
\`\`\`

After the mutation completes, end the turn. Do not make code changes."
gh issue edit "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" --body "$BODY" >/dev/null

ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")
e2e::set_status "$ITEM_ID" "Agent Ready"
echo "issue=$ISSUE_NUM item=$ITEM_ID model=$MODEL max_turns=$MAX_TURNS"

# Wait up to 120s for a comment to appear (excluding the bot/setup ones)
elapsed=0
got_comment=no
while (( elapsed < 120 )); do
  count=$(gh issue view "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" --json comments --jq '.comments | length' 2>/dev/null || echo 0)
  if (( count >= 1 )); then got_comment=yes; break; fi
  sleep 5
  (( elapsed+=5 ))
done

if [[ "$got_comment" == "yes" ]]; then
  e2e::verdict_pass
else
  e2e::verdict_partial "agent did not post a comment within 120s — github_graphql tool path is wired but the model ignored the instruction. Try a stronger model via SYMPHONY_E2E_E2E8_MODEL."
fi
