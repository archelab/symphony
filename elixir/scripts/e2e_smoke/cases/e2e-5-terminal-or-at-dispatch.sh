#!/usr/bin/env bash
# E2E-5: Negative test — closed issues must NOT be dispatched even at Agent Ready.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-5 closed before add" \
  "Smoke test — should NOT be dispatched.")
gh issue close "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" >/dev/null
ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")
e2e::set_status "$ITEM_ID" "Agent Ready"
echo "closed-then-added: issue=$ISSUE_NUM item=$ITEM_ID"

# Watch for 60s — there must be NO dispatch line for this item.
IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM"
sleep 60
log=$(e2e::current_log)
if grep -aE "Dispatching issue to agent.*$IDENT" "$log" >/dev/null 2>&1; then
  e2e::verdict_fail "closed issue was dispatched"
fi
echo "OK: no dispatch within 60s for closed issue $IDENT"

# Workspace must not exist
WS="$E2E_WORKSPACE_ROOT/${SYMPHONY_E2E_PROJECT_OWNER}_${SYMPHONY_E2E_REPO}_${ISSUE_NUM}"
if [[ -d "$WS" || -d "/private$WS" ]]; then
  e2e::verdict_fail "workspace created for closed issue"
fi

e2e::verdict_pass
