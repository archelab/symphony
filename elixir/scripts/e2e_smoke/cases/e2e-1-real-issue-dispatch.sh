#!/usr/bin/env bash
# E2E-1: Real Issue dispatch — confirm a real Issue at Agent Ready is dispatched
# with identifier `<owner>/<repo>#N` and that the workspace is created.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

# Create issue + add to project + Agent Ready
read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-1 real issue dispatch" \
  "Smoke test — no action needed. Exit the turn.")
ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")
e2e::set_status "$ITEM_ID" "Agent Ready"

IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM"
echo "issue=$ISSUE_NUM item=$ITEM_ID identifier=$IDENT"

# Wait for Dispatching event with this identifier
if e2e::wait_for_log_line "Dispatching issue to agent.*$IDENT" 45; then
  echo "OK: Dispatching log seen"
else
  e2e::verdict_fail "no Dispatching log line within 45s for $IDENT"
fi

# Validate workspace exists (path sanitisation: / and # → _)
WS="$E2E_WORKSPACE_ROOT/${SYMPHONY_E2E_PROJECT_OWNER}_${SYMPHONY_E2E_REPO}_${ISSUE_NUM}"
# macOS resolves /tmp -> /private/tmp; check both
if [[ ! -d "$WS" && ! -d "/private$WS" ]]; then
  e2e::verdict_fail "workspace not created at $WS"
fi
echo "OK: workspace at $WS"

# Confirm prompt rendered the issue.kind == "issue" branch by inspecting the latest rollout
ROLL=$(/bin/ls -t "$HOME/.codex/sessions/"*/*/*/rollout-*.jsonl 2>/dev/null | head -1)
if [[ -z "$ROLL" ]]; then
  e2e::verdict_fail "no rollout file found"
fi
if grep -q "Kind: issue" "$ROLL" && grep -q "Identifier: $IDENT" "$ROLL"; then
  echo "OK: rollout shows Kind: issue and Identifier: $IDENT"
else
  e2e::verdict_fail "rollout did not show expected Kind/Identifier"
fi

e2e::verdict_pass
