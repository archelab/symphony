#!/usr/bin/env bash
# E2E-9: Rework continuation prompt.
# After a turn completes, flip Status to Rework and verify the next dispatch
# renders the "## Continuation context" section with last_run_completed_at.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-9 rework" "Smoke test — exit the turn.")
ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")
e2e::set_status "$ITEM_ID" "Agent Ready"

IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM"
e2e::wait_for_log_line "Dispatching issue to agent.*$IDENT" 45 || \
  e2e::verdict_fail "never dispatched"

# Wait for at least one agent_exit_normal so completed_at is recorded
e2e::wait_for_log_line "worker stop reason=:agent_exit_normal issue_id=\"$ITEM_ID\"" 60 || \
  e2e::verdict_fail "first turn never completed"

# Flip to Rework
e2e::set_status "$ITEM_ID" "Rework"
echo "flipped to Rework"

# Wait for the next dispatch + verify the rollout has the Continuation context
sleep 15
ROLL=$(/bin/ls -t "$HOME/.codex/sessions/"*/*/*/rollout-*.jsonl 2>/dev/null | head -1)
if [[ -z "$ROLL" ]]; then
  e2e::verdict_fail "no rollout file"
fi
if grep -q "Continuation context" "$ROLL" && grep -qE "dispatch attempt #[0-9]+" "$ROLL"; then
  if grep -qE "Prior session ended at " "$ROLL"; then
    echo "OK: Continuation context + Prior session ended timestamp rendered"
    e2e::verdict_pass
  else
    e2e::verdict_partial "Continuation context rendered but no Prior session timestamp"
  fi
else
  e2e::verdict_fail "Continuation context section not in latest rollout ($ROLL)"
fi
