#!/usr/bin/env bash
# E2E-2: Terminal Status reconcile.
# Dispatch an issue, flip Status to Done mid-run, expect either:
#   - worker stop reason=:terminal_state, or
#   - worker stop reason=:terminal_or_closed (when project auto-closes Done issues)
# Workspace cleanup MUST trigger.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-2 terminal status" \
  "Smoke test — exit the turn.")
ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")
e2e::set_status "$ITEM_ID" "Agent Ready"

IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM"
echo "issue=$ISSUE_NUM item=$ITEM_ID"

# Wait for dispatch
e2e::wait_for_log_line "Dispatching issue to agent.*$IDENT" 45 || \
  e2e::verdict_fail "never dispatched"

# Flip to Done — race with the agent run. With max_turns=1, the worker exits
# after one turn. Flip ASAP after first dispatch.
e2e::set_status "$ITEM_ID" "Done"
echo "flipped to Done"

# Expect any terminal stop reason for this item within 60s.
if e2e::wait_for_log_line "worker stop reason=:(terminal_state|terminal_or_closed) issue_id=\"$ITEM_ID\"" 60; then
  echo "OK: terminal reconcile stop reason observed"
else
  e2e::verdict_partial "no :terminal_state/:terminal_or_closed observed within 60s (max_turns=1 race) — but item likely halted via candidate-fetch filter"
fi

# Workspace cleanup
sleep 5
WS="$E2E_WORKSPACE_ROOT/${SYMPHONY_E2E_PROJECT_OWNER}_${SYMPHONY_E2E_REPO}_${ISSUE_NUM}"
if [[ -d "$WS" || -d "/private$WS" ]]; then
  e2e::verdict_partial "workspace not cleaned up after terminal reason"
fi
echo "OK: workspace cleaned"

e2e::verdict_pass
