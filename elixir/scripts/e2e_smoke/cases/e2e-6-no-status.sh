#!/usr/bin/env bash
# E2E-6: Negative test — items without a Status must NOT be dispatched.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-6 no status" \
  "Smoke test — should NOT be dispatched.")
ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")
# Explicitly do NOT set Status; clear it just in case
e2e::clear_status "$ITEM_ID"

IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM"
echo "no-status: issue=$ISSUE_NUM item=$ITEM_ID"

sleep 45
log=$(e2e::current_log)
if grep -aE "Dispatching issue to agent.*$IDENT" "$log" >/dev/null 2>&1; then
  e2e::verdict_fail "item with no Status was dispatched"
fi
echo "OK: no dispatch for item with no Status"

e2e::verdict_pass
