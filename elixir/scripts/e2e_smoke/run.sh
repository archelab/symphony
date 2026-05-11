#!/usr/bin/env bash
# Symphony orchestrator e2e smoke test driver.
#
# Configuration via environment variables:
#   SYMPHONY_E2E_PROJECT_OWNER   default: archelab
#   SYMPHONY_E2E_PROJECT_NUMBER  default: 1
#   SYMPHONY_E2E_REPO            default: symphony
#   SYMPHONY_E2E_TESTS           default: all
#                                comma-separated case names (e.g. e2e-1,e2e-3),
#                                or "all" to run every case.
#   SYMPHONY_E2E_REPORT          path to REPORT.md (default: $E2E_LOG_DIR/REPORT.md)
#
# Usage:
#   ./run.sh                       # run all cases
#   SYMPHONY_E2E_TESTS=e2e-5,e2e-6 ./run.sh   # only negative tests (fast, no Codex)
#
# Exit codes:
#   0  all tests PASS
#   1  one or more FAIL
#   2  setup error

set -euo pipefail

# Resolve script + project dirs early
export E2E_SCRIPT_DIR
E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export E2E_ELIXIR_DIR
E2E_ELIXIR_DIR="$(cd "$E2E_SCRIPT_DIR/../.." && pwd)"

export SYMPHONY_E2E_PROJECT_OWNER="${SYMPHONY_E2E_PROJECT_OWNER:-archelab}"
export SYMPHONY_E2E_PROJECT_NUMBER="${SYMPHONY_E2E_PROJECT_NUMBER:-1}"
export SYMPHONY_E2E_REPO="${SYMPHONY_E2E_REPO:-symphony}"

export E2E_LOG_DIR="${E2E_LOG_DIR:-/tmp/symphony-smoke-log}"
export E2E_WORKSPACE_ROOT="${E2E_WORKSPACE_ROOT:-/tmp/symphony-smoke-workspaces}"
export E2E_REPORT_PATH="${SYMPHONY_E2E_REPORT:-$E2E_LOG_DIR/REPORT.md}"

mkdir -p "$E2E_LOG_DIR"
rm -rf "$E2E_WORKSPACE_ROOT" 2>/dev/null || true
mkdir -p "$E2E_WORKSPACE_ROOT"

# shellcheck source=lib.sh
source "$E2E_SCRIPT_DIR/lib.sh"

# Pre-flight
command -v gh >/dev/null    || { e2e::log "gh not on PATH"; exit 2; }
command -v jq >/dev/null    || { e2e::log "jq not on PATH"; exit 2; }
command -v mise >/dev/null  || { e2e::log "mise not on PATH"; exit 2; }
command -v curl >/dev/null  || { e2e::log "curl not on PATH"; exit 2; }
gh auth status >/dev/null   || { e2e::log "gh not authenticated"; exit 2; }

e2e::resolve_project_ids

# Cleanup on exit (including SIGINT)
on_exit() {
  local rc=$?
  e2e::log "Cleanup..."
  e2e::stop_orchestrator || true
  e2e::cleanup_smoke_items || true
  e2e::swap_workflow_out
  exit "$rc"
}
trap on_exit EXIT INT TERM

# Initialise: swap WORKFLOW.md to the smoke version + cleanup any lingering smoke items
e2e::swap_workflow_in
e2e::cleanup_smoke_items

# Initialise REPORT.md
{
  echo "# Symphony orchestrator e2e smoke test — $(date -Iseconds)"
  echo ""
  echo "Repo: $SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO"
  echo "Project: $E2E_PROJECT_ID  (number $SYMPHONY_E2E_PROJECT_NUMBER)"
  echo ""
} >"$E2E_REPORT_PATH"

# Determine which cases to run
CASES="${SYMPHONY_E2E_TESTS:-all}"
ALL_CASES=$(/bin/ls "$E2E_SCRIPT_DIR/cases" | sort | sed -E 's/^([^.]+)\.sh$/\1/' | grep -E '^e2e-')

if [[ "$CASES" == "all" ]]; then
  RUN_CASES=$ALL_CASES
else
  RUN_CASES=$(tr ',' '\n' <<<"$CASES" | sort)
fi

declare -i PASS=0 FAIL=0 SKIP=0 PARTIAL=0
declare -a FAILED=()

for case_name in $RUN_CASES; do
  case_file="$E2E_SCRIPT_DIR/cases/$case_name.sh"
  if [[ ! -x "$case_file" ]]; then
    e2e::log "$case_name: case file not found / not executable ($case_file)"
    (( FAIL+=1 ))
    FAILED+=("$case_name")
    continue
  fi

  e2e::log "=== $case_name ==="
  set +e
  output=$("$case_file" 2>&1)
  rc=$?
  set -e

  verdict=$(printf '%s\n' "$output" | tail -1)

  {
    echo "## $case_name"
    echo ""
    echo "**Verdict:** $verdict"
    echo ""
    echo '<details><summary>Evidence</summary>'
    echo ''
    echo '```'
    printf '%s\n' "$output" | head -200
    echo '```'
    echo '</details>'
    echo ""
  } >>"$E2E_REPORT_PATH"

  case $rc in
    0) (( PASS+=1 )); e2e::log "$case_name: PASS" ;;
    1) (( FAIL+=1 )); FAILED+=("$case_name"); e2e::log "$case_name: FAIL — $verdict" ;;
    2) (( SKIP+=1 )); e2e::log "$case_name: SKIP — $verdict" ;;
    3) (( PARTIAL+=1 )); e2e::log "$case_name: PARTIAL — $verdict" ;;
    *) (( FAIL+=1 )); FAILED+=("$case_name"); e2e::log "$case_name: ERROR (rc=$rc) — $verdict" ;;
  esac
done

{
  echo "## Summary"
  echo ""
  echo "- PASS:    $PASS"
  echo "- PARTIAL: $PARTIAL"
  echo "- SKIP:    $SKIP"
  echo "- FAIL:    $FAIL"
  if (( FAIL > 0 )); then
    echo ""
    echo "Failed cases:"
    for c in "${FAILED[@]:-}"; do echo "- $c"; done
  fi
} >>"$E2E_REPORT_PATH"

e2e::log "Done. PASS=$PASS PARTIAL=$PARTIAL SKIP=$SKIP FAIL=$FAIL"
e2e::log "Report: $E2E_REPORT_PATH"

if (( FAIL > 0 )); then
  exit 1
fi
exit 0
