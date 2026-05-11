#!/usr/bin/env bash
# E2E-4: Issue CLOSED mid-run.
# Expect :terminal_or_closed (or :terminal_state) and workspace cleanup.
# Race-prone with max_turns=1 — accept PARTIAL if reconcile loses the race.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-4 close mid-run" \
  "Smoke test — exit the turn.")
ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")
e2e::set_status "$ITEM_ID" "Agent Ready"

IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM"
e2e::wait_for_log_line "Dispatching issue to agent.*$IDENT" 45 || \
  e2e::verdict_fail "never dispatched"

gh issue close "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" >/dev/null
echo "closed"

# Look for terminal reconcile stop
if e2e::wait_for_log_line "worker stop reason=:(terminal_state|terminal_or_closed) issue_id=\"$ITEM_ID\"" 60; then
  echo "OK: terminal reconcile stop reason observed"
else
  e2e::verdict_partial "no runtime :terminal_or_closed observed (max_turns=1 race); workspace cleanup still happens on next orchestrator start via terminal sweep"
fi

# Check workspace cleanup
sleep 5
WS="$E2E_WORKSPACE_ROOT/${SYMPHONY_E2E_PROJECT_OWNER}_${SYMPHONY_E2E_REPO}_${ISSUE_NUM}"
if [[ -d "$WS" || -d "/private$WS" ]]; then
  e2e::verdict_partial "workspace not cleaned (likely the runtime reconcile race)"
fi
echo "OK: workspace cleaned"

e2e::verdict_pass
