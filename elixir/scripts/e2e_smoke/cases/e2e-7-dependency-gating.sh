#!/usr/bin/env bash
# E2E-7: Dependency gating. A parent issue with an OPEN sub-issue child must
# not be dispatched while the child is open. Closing the child should unblock
# the parent.
#
# NOTE (2026-05-11): symphony/elixir/lib/symphony_elixir/github/adapter.ex queries
# `trackedIssues` for blockers, but GitHub's new "sub-issue" hierarchy populates
# `subIssues`. This case exposes that mismatch by showing the parent dispatches
# despite an open sub-issue child.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

read -r P_NUM P_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-7 parent" "Parent with sub-issue child.")
read -r C_NUM C_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-7 child" "Child sub-issue.")
C_DB_ID=$(e2e::issue_database_id "$C_NUM")

if ! e2e::link_sub_issue "$P_NUM" "$C_DB_ID"; then
  e2e::verdict_skip "could not link sub-issue (sub-issues feature unavailable in this repo)"
fi

P_ITEM=$(e2e::add_to_project "$P_NODE_ID")
C_ITEM=$(e2e::add_to_project "$C_NODE_ID")
e2e::set_status "$P_ITEM" "Agent Ready"
e2e::set_status "$C_ITEM" "Agent Ready"

P_IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$P_NUM"
C_IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$C_NUM"

sleep 30
log=$(e2e::current_log)
P_DISPATCHED=$(grep -aE "Dispatching issue to agent.*$P_IDENT" "$log" >/dev/null 2>&1 && echo yes || echo no)
C_DISPATCHED=$(grep -aE "Dispatching issue to agent.*$C_IDENT" "$log" >/dev/null 2>&1 && echo yes || echo no)
echo "after 30s: parent dispatched=$P_DISPATCHED child dispatched=$C_DISPATCHED"

# Expected: child dispatches, parent does NOT
if [[ "$C_DISPATCHED" == "yes" && "$P_DISPATCHED" == "no" ]]; then
  echo "OK: child dispatched, parent gated"
  # Close child, expect parent to dispatch within ~30s
  gh issue close "$C_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" >/dev/null
  if e2e::wait_for_log_line "Dispatching issue to agent.*$P_IDENT" 45; then
    e2e::verdict_pass
  else
    e2e::verdict_partial "parent did not dispatch within 45s after child close"
  fi
else
  e2e::verdict_fail "gating did NOT work — parent_dispatched=$P_DISPATCHED child_dispatched=$C_DISPATCHED. Likely cause: adapter queries trackedIssues, not subIssues (lib/symphony_elixir/github/adapter.ex)."
fi
