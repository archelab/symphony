#!/usr/bin/env bash
# E2E-12: spawned agent gh auth + no zshrc stderr leak.
#
# The agent must use the prepared environment (GH_TOKEN/GITHUB_TOKEN) to run
# `gh auth status`, `gh issue view`, and `gh pr view`, then acknowledge success
# on the smoke issue. The test also checks the orchestrator stdout for the
# zshrc/oh-my-zsh sandbox-denial noise that caused the #77 token blow-up.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

MODEL="${SYMPHONY_E2E_E2E12_MODEL:-gpt-5.4-mini}"
REASON="${SYMPHONY_E2E_E2E12_REASON:-low}"
MAX_TURNS="${SYMPHONY_E2E_E2E12_MAX_TURNS:-2}"

WORKFLOW="$E2E_ELIXIR_DIR/WORKFLOW.md"
BACKUP="$WORKFLOW.e2e12_bak"
cp "$WORKFLOW" "$BACKUP"

cleanup_e2e12() {
  if [[ -f "$BACKUP" ]]; then
    mv "$BACKUP" "$WORKFLOW"
  fi
  rm -f "$WORKFLOW.tmp"
}
trap cleanup_e2e12 EXIT

sed -i.tmp -E \
  -e "s|model=\"[^\"]+\"|model=\"$MODEL\"|" \
  -e "s|model_reasoning_effort=[a-z]+|model_reasoning_effort=$REASON|" \
  -e "s|^( *max_turns:).*|\\1 $MAX_TURNS|" \
  "$WORKFLOW"
rm -f "$WORKFLOW.tmp"

ORCH_LOG="$E2E_LOG_DIR/run.log"
e2e::start_orchestrator "$ORCH_LOG"
RUN_START_EPOCH=$(date +%s)

read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-12 gh auth no zshrc" \
  "placeholder — will edit body below")
ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")

BODY="Smoke test. AGENT PRIORITY INSTRUCTION: Verify the prepared shell environment.

Do not edit files. Do not create a branch. Do not create a PR. Do not source ~/.zshrc.

Run these shell commands directly:

\`\`\`bash
gh auth status -h github.com
gh issue view $ISSUE_NUM -R $SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO --json number,title
gh pr view 95 -R $SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO --json number,state,title
\`\`\`

Only if all three commands exit 0, post this exact comment on this issue using gh:

\`\`\`bash
gh issue comment $ISSUE_NUM -R $SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO --body '## GH auth smoke passed

- gh auth status: ok
- gh issue view: ok
- gh pr view: ok'
\`\`\`

After posting the comment, end the turn."

gh issue edit "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" --body "$BODY" >/dev/null

e2e::set_status "$ITEM_ID" "Agent Ready"

IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM"
echo "issue=$ISSUE_NUM item=$ITEM_ID model=$MODEL max_turns=$MAX_TURNS"

e2e::wait_for_log_line "Dispatching issue to agent.*$IDENT" 60 || \
  e2e::verdict_fail "never dispatched"

elapsed=0
saw_comment=no

while (( elapsed < 180 )); do
  comments_json=$(gh issue view "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" --json comments 2>/dev/null || echo '{}')
  if jq -e '.comments[]?.body | select(contains("## GH auth smoke passed")) | select(contains("gh issue view: ok")) | select(contains("gh pr view: ok"))' <<<"$comments_json" >/dev/null; then
    saw_comment=yes
    break
  fi

  sleep 5
  (( elapsed+=5 ))
done

if [[ "$saw_comment" != "yes" ]]; then
  e2e::verdict_fail "agent did not prove gh auth commands within 180s"
fi

found_gh_success=no
found_invalid_token=no
matched_rollouts=0

while IFS= read -r -d '' candidate; do
  cand_mtime=$(stat -f '%m' "$candidate" 2>/dev/null || stat -c '%Y' "$candidate" 2>/dev/null || echo 0)
  if (( cand_mtime < RUN_START_EPOCH )); then
    continue
  fi

  if ! grep -aq "You are working on GitHub item \`$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM\`" "$candidate" ||
     ! grep -aq "AGENT PRIORITY INSTRUCTION: Verify the prepared shell environment" "$candidate"; then
    continue
  fi

  (( matched_rollouts+=1 ))

  if grep -aqE 'token in (GH_TOKEN|GITHUB_TOKEN) is invalid' "$candidate"; then
    found_invalid_token=yes
  fi

  if grep -aq 'gh auth status -h github.com' "$candidate" && grep -aq 'Process exited with code 0' "$candidate"; then
    found_gh_success=yes
  fi
done < <(find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)

if [[ "$matched_rollouts" -eq 0 ]]; then
  e2e::verdict_fail "could not find a matching Codex rollout for issue #$ISSUE_NUM"
fi

if [[ "$found_invalid_token" == "yes" ]]; then
  e2e::verdict_fail "matching rollout shows GH_TOKEN/GITHUB_TOKEN was invalid"
fi

if [[ "$found_gh_success" != "yes" ]]; then
  e2e::verdict_fail "matching rollout does not show gh auth status exiting 0"
fi

if grep -aE 'oh-my-zsh|zcompdump|Operation not permitted' "$ORCH_LOG" >/dev/null 2>&1; then
  e2e::verdict_fail "zshrc sandbox-denial noise appeared in orchestrator stdout"
fi

e2e::verdict_pass
